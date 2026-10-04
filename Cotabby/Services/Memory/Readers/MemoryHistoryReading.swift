import Foundation

/// File overview:
/// The contract between Cotabby's readers of protected message stores and the memory sync that
/// pushes their messages to the service (`records.ingest`).
///
/// Readers run on a background task, open their store read-only, and return messages in a stable
/// order after a cursor they define (a row id), a page at a time, so a sync can stop and resume
/// anywhere. Everything after reading (scrubbing, exclusions, encryption, indexing) happens in the
/// service, the same for every source.

/// One message as the service's `records.ingest` expects it.
nonisolated struct MemoryIngestRecord: Equatable, Sendable {
    let sourceMessageID: String
    let conversationID: String
    let conversationTitle: String
    let sender: String
    let isFromMe: Bool
    let timestamp: Date
    let text: String
    /// The other people in the conversation, as stable identities (WhatsApp JIDs, mail addresses).
    let participants: [String]
    /// Mail only; its presence also tells the service to strip quoted history.
    let subject: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "source_message_id": sourceMessageID,
            "conversation_id": conversationID,
            "conversation_title": conversationTitle,
            "sender": sender,
            "is_from_me": isFromMe,
            "timestamp": timestamp.timeIntervalSince1970,
            "text": text,
            "participants": participants
        ]
        if let subject { object["subject"] = subject }
        return object
    }

    /// Rough wire size, for batching under the service's request limit.
    var approximateBytes: Int {
        text.utf8.count + conversationTitle.utf8.count + sender.utf8.count + (subject?.utf8.count ?? 0)
            + participants.reduce(0) { $0 + $1.utf8.count } + 200
    }
}

nonisolated struct MemoryReadPage: Sendable {
    let records: [MemoryIngestRecord]
    /// Where the next page starts; nil when the store had nothing after the cursor.
    let nextCursor: String?
    /// True when there may be more after this page.
    let hasMore: Bool
}

nonisolated protocol MemoryHistoryReading: Sendable {
    /// The service's source id (`whatsapp`, `apple_mail`).
    var sourceID: String { get }
    /// Whether the store can be read right now: present, and permitted by macOS.
    func readiness() -> MemorySourceReadiness
    /// Up to `limit` messages after `cursor` (or from `since` when there is no cursor).
    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage
}

nonisolated enum MemorySourceReadiness: Equatable, Sendable {
    case ready
    /// The app is not installed or has no local history yet.
    case notFound(String)
    /// macOS denied access; Cotabby needs Full Disk Access.
    case needsFullDiskAccess
    case failed(String)

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .ready: return "Ready"
        case .notFound(let detail): return detail
        case .needsFullDiskAccess: return "Cotabby needs Full Disk Access to read this history."
        case .failed(let detail): return detail
        }
    }
}

extension ReadOnlySQLiteDatabase.DatabaseError {
    nonisolated var readiness: MemorySourceReadiness {
        switch self {
        case .notPermitted: return .needsFullDiskAccess
        case .missing(let path): return .notFound("No local history at \(path).")
        case .sqlite(let message): return .failed(message)
        }
    }
}
