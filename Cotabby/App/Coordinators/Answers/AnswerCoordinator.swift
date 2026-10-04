import AppKit
import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Offers a drafted answer when the user opens an empty reply to a message that asks them something.
///
/// The flow, each step owned elsewhere so this file only orchestrates:
/// 1. A focused, non-secure, still-empty reply field (`ReplyFieldEmptiness`) in an app and window
///    where answers are on, with memory running, a local model able to draft, and the performance
///    tuner allowing memory work.
/// 2. The latest incoming message there (`IncomingMessageResolver`) and the question in it
///    (`QuestionDetector`).
/// 3. Facts from memory: the user's answer sources, any conversation, plus the conversation being
///    replied in, never the question itself (`MemoryEngine.answerSearch`), and only when the best
///    one is relevant enough (`AnswerGroundingPolicy.shouldDraft`).
/// 4. A draft (`AnswerDraftEngine`), kept only if every number and name in it is in the facts or
///    the question (`AnswerGroundingPolicy.unsupportedSpecifics`).
/// 5. A card under the field with the draft and its sources (`AnswerCardController`). While it is
///    up, Tab pastes the draft at the caret and Esc dismisses it (`TemporaryKeyTap`); any other key
///    dismisses it and reaches the app as usual. Nothing is ever inserted without that Tab.
///
/// Each question is drafted once (cached by message), a dismissed one is not offered again, and
/// every async step re-checks that the same field is still focused and still empty before acting.
/// Built by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`.
@MainActor
final class AnswerCoordinator {
    private let focusModel: FocusTrackingModel
    private let memory: MemoryEngineController
    private let resolver: IncomingMessageResolver
    private let draftEngine: AnswerDraftEngine
    private let card: AnswerCardController
    private let keyTap: TemporaryKeyTap
    private let inserter: SuggestionInserter
    private let windowOverrides: WindowFeatureOverrideStore
    /// Whether the performance tuner allows memory work right now.
    var isAllowedByTuning: @MainActor () -> Bool = { true }
    /// Whether answers are on for an app (the field icon's app switch); default on for apps with memory.
    var isEnabledForApplication: @MainActor (String) -> Bool = { _ in true }

    private var cancellables: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var pendingIdentity: FocusedInputIdentity?
    /// The offer on screen, for which field.
    private var shown: (identity: FocusedInputIdentity, offer: AnswerOffer, messageKey: String)?
    /// Drafts per message key (nil: memory had no answer), and the messages the user dismissed.
    private var drafts: [String: AnswerOffer?] = [:]
    private var dismissed: Set<String> = []

    static let debounceNanoseconds: UInt64 = 400_000_000
    static let tabKeyCode: CGKeyCode = 48
    static let escapeKeyCode: CGKeyCode = 53

    init(
        focusModel: FocusTrackingModel, memory: MemoryEngineController, resolver: IncomingMessageResolver,
        draftEngine: AnswerDraftEngine, card: AnswerCardController, keyTap: TemporaryKeyTap,
        inserter: SuggestionInserter, windowOverrides: WindowFeatureOverrideStore
    ) {
        self.focusModel = focusModel
        self.memory = memory
        self.resolver = resolver
        self.draftEngine = draftEngine
        self.card = card
        self.keyTap = keyTap
        self.inserter = inserter
        self.windowOverrides = windowOverrides
    }

    func start() {
        focusModel.$snapshot
            .sink { [weak self] snapshot in self?.observe(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        withdraw()
    }

    /// A field-icon choice changed: re-evaluate the focused field now.
    func handleScopeChange() {
        withdraw()
        observe(focusModel.snapshot)
    }

    // MARK: - Observing

    private func observe(_ snapshot: FocusSnapshot) {
        guard let input = eligibleInput(snapshot) else {
            withdraw()
            return
        }
        // Same field, already offered or being prepared: nothing to do.
        if shown?.identity == input.identity || pendingIdentity == input.identity { return }
        withdraw()
        pendingIdentity = input.identity
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            await self.prepare(for: input)
            if self.pendingIdentity == input.identity { self.pendingIdentity = nil }
        }
    }

    private func eligibleInput(_ snapshot: FocusSnapshot) -> FocusedInputSnapshot? {
        guard let answers = memory.engine?.configuration.answers, answers.enabled,
              memory.state == .running, draftEngine.canDraft, isAllowedByTuning(),
              case .supported = snapshot.capability,
              let input = snapshot.context, !input.isSecure,
              ReplyFieldEmptiness.isEmpty(precedingText: input.precedingText, trailingText: input.trailingText)
        else { return nil }
        let windowKey = WindowFeatureScope.windowKey(bundleIdentifier: input.bundleIdentifier, windowTitle: input.featureScopeWindowTitle)
        guard WindowFeatureScope.resolve(
            appEnabled: isEnabledForApplication(input.bundleIdentifier),
            windowOverride: windowOverrides.override(for: .answers, windowKey: windowKey)
        ) else { return nil }
        return input
    }

    // MARK: - Preparing an answer

    private func prepare(for input: FocusedInputSnapshot) async {
        let started = Date()
        guard let incoming = await resolver.latestIncoming(for: input) else {
            // No quoted mail, an unknown or ambiguous conversation, or the user already replied.
            log("skipped", ["reason": "no_incoming_message", "app": input.bundleIdentifier ?? ""])
            return
        }
        guard isStillCurrent(input) else { return }
        guard let question = QuestionDetector.question(in: incoming.text) else {
            log("skipped", ["reason": "no_question"])
            return
        }
        let key = incoming.key
        guard !dismissed.contains(key) else { return }
        if let cached = drafts[key] {
            if let cached, isStillCurrent(input) { offer(cached, for: input, messageKey: key) }
            return
        }
        guard let engine = memory.engine, let configuration = memory.engine?.configuration else { return }

        let answerSources = MemorySourceCatalog.all.map(\.id).filter {
            configuration.sources[$0]?.enabled == true && MemorySourceCatalog.isAnswerSource($0, settings: configuration.sources[$0])
        }
        let current = incoming.conversation.map { ($0.source, $0.conversationId) }
        let excluded = incoming.recordIDs
        let result = await Task.detached(priority: .userInitiated) {
            engine.answerSearch(question: question, sources: answerSources, currentConversation: current, excludingRecordIDs: excluded)
        }.value
        // The quoted mail itself is not in `excluded` (no record id); never treat it as a fact.
        let questionText = incoming.text.lowercased()
        let hits = result.hits.filter { !questionText.contains($0.text.lowercased()) }
        let best = hits.map(\.similarity).max() ?? 0
        let factTexts = hits.map { "\($0.sender) \($0.conversationTitle) \($0.text)" }
        guard AnswerGroundingPolicy.shouldDraft(
            bestSimilarity: best, minimumSimilarity: configuration.answers.minimumConfidence,
            hasKeywordMatch: hits.contains { $0.via != "vector" }
        ), AnswerGroundingPolicy.factsMentionWhatTheQuestionNames(question: question, facts: factTexts) else {
            drafts[key] = .some(nil)
            log("skipped", ["reason": "no_relevant_memory", "best_similarity": String(format: "%.2f", best), "hits": "\(hits.count)"])
            return
        }

        let facts = hits.map {
            AnswerPromptRenderer.Fact(sender: $0.sender, isFromMe: $0.isFromMe, conversationTitle: $0.conversationTitle,
                                      timestamp: Date(timeIntervalSince1970: $0.timestamp), text: $0.text)
        }
        let draft: AnswerDraftEngine.Draft?
        do {
            draft = try await draftEngine.draft(question: question, asker: incoming.sender, facts: facts)
        } catch {
            log("skipped", ["reason": "draft_failed", "error": error.localizedDescription])
            return
        }
        guard let draft else {
            drafts[key] = .some(nil)
            log("skipped", ["reason": "model_abstained"])
            return
        }
        // Grounded in what the model was shown: each fact's sender, chat and text.
        let shownFacts = AnswerPromptRenderer.factLines(facts)
        let unsupported = AnswerGroundingPolicy.unsupportedSpecifics(in: draft.text, facts: shownFacts, question: incoming.text)
        guard unsupported.isEmpty, AnswerGroundingPolicy.usesFacts(draft.text, facts: shownFacts, question: incoming.text),
              !AnswerGroundingPolicy.containsSecrets(draft.text) else {
            drafts[key] = .some(nil)
            log("skipped", ["reason": "ungrounded", "unsupported": "\(unsupported.count)", "engine": draft.engine])
            return
        }
        let isOtherConversation = { (hit: MemorySearchResult.Hit) in
            hit.source != incoming.conversation?.source || hit.conversationId != incoming.conversation?.conversationId
        }
        // The question comes from someone else; it must not be able to make the draft reproduce
        // another conversation's message wholesale.
        if hits.contains(where: { isOtherConversation($0) && AnswerGroundingPolicy.copiesPassage(draft.text, from: $0.text) }) {
            drafts[key] = .some(nil)
            log("skipped", ["reason": "copies_other_conversation", "engine": draft.engine])
            return
        }
        let prepared = AnswerOffer(draft: draft.text, sources: Array(hits.prefix(3)).map { Self.source($0, otherConversation: isOtherConversation($0)) })
        drafts[key] = prepared
        log("shown", [
            "engine": draft.engine, "hits": "\(hits.count)", "best_similarity": String(format: "%.2f", best),
            "latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
        ])
        if isStillCurrent(input) { offer(prepared, for: input, messageKey: key) }
    }

    private static func source(_ hit: MemorySearchResult.Hit, otherConversation: Bool) -> AnswerOffer.Source {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let app = MemorySourceCatalog.descriptor(hit.source)?.title ?? hit.source
        let who = hit.isFromMe ? "You" : hit.sender
        let byline = [who, hit.conversationTitle, formatter.string(from: Date(timeIntervalSince1970: hit.timestamp)), app]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let excerpt = hit.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return AnswerOffer.Source(id: hit.recordId, byline: byline, excerpt: String(excerpt.prefix(160)),
                                  isFromAnotherConversation: otherConversation)
    }

    /// The same field is still focused and still empty.
    private func isStillCurrent(_ input: FocusedInputSnapshot) -> Bool {
        guard let now = focusModel.snapshot.context else { return false }
        return now.identity == input.identity
            && ReplyFieldEmptiness.isEmpty(precedingText: now.precedingText, trailingText: now.trailingText)
    }

    // MARK: - The card

    private func offer(_ offer: AnswerOffer, for input: FocusedInputSnapshot, messageKey: String) {
        shown = (input.identity, offer, messageKey)
        card.show(offer, near: input.elementFrameRect ?? input.inputFrameRect ?? input.caretRect)
        keyTap.install { [weak self] keyCode, flags in
            guard let self else { return .pass }
            let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            switch (keyCode, plain) {
            case (Self.tabKeyCode, true):
                // Insert after the tap returns: the paste presses a menu item through Accessibility,
                // which must never run inside the tap callback.
                DispatchQueue.main.async { self.insert() }
                return .consume
            case (Self.escapeKeyCode, _):
                DispatchQueue.main.async { self.dismiss() }
                return .consume
            default:
                // Typing means the user writes their own reply.
                DispatchQueue.main.async { self.withdraw() }
                return .pass
            }
        }
    }

    private func insert() {
        guard let shown, let input = focusModel.snapshot.context, input.identity == shown.identity,
              ReplyFieldEmptiness.isEmpty(precedingText: input.precedingText, trailingText: input.trailingText) else {
            withdraw()
            return
        }
        let text = shown.offer.draft
        let key = shown.messageKey
        withdraw()
        dismissed.insert(key)  // Answered: never offered again.
        if inserter.pasteAtCaret(text) {
            log("inserted", ["characters": "\(text.count)"])
        } else {
            CotabbyLogger.app.error("Answer could not be inserted")
        }
    }

    private func dismiss() {
        if let key = shown?.messageKey { dismissed.insert(key) }
        log("dismissed", [:])
        withdraw()
    }

    private func withdraw() {
        task?.cancel()
        task = nil
        pendingIdentity = nil
        shown = nil
        keyTap.remove()
        card.hide()
    }

    private func log(_ event: String, _ fields: [String: String]) {
        var metadata: Logger.Metadata = ["category": .string("answers"), "event": .string(event)]
        for (key, value) in fields { metadata[key] = .string(value) }
        CotabbyLogger.app.info("Answer \(event)", metadata: metadata)
    }
}
