# Cotabby Source Layout

This document is the canonical placement map for production and test source files. It complements
`ARCHITECTURE.md`, which explains runtime ownership and data flow.

Swift folders do not create namespaces. Every Swift file discovered under `Cotabby/` still compiles
into the application module, and every file under `CotabbyTests/` compiles into the test module.
Folders exist so a maintainer can predict where a responsibility lives before searching.

## Placement Rules

1. Choose the top-level architectural boundary first: `App`, `UI`, `Services`, `Models`, or
   `Support`.
2. Choose the product subsystem next, such as `Suggestion`, `Focus`, `Runtime`, or `Settings`.
3. Keep a small cohesive subsystem flat.
4. Add a child folder only when at least two files form a stable responsibility with a predictable
   name. Do not create one-file folders merely to shorten a file list.
5. Put a direct unit test under the corresponding `CotabbyTests/` responsibility. Cross-cutting
   coordinator tests may remain grouped by the coordinator they exercise.
6. Folder moves must not change Swift access control, runtime ownership, or target membership.
   XcodeGen discovers the new paths; regenerate `Cotabby.xcodeproj` after moving files.

## Production Tree

~~~text
Cotabby/
├── App/
│   ├── Core/                         process entry, composition root, lifecycle
│   └── Coordinators/
│       ├── InlineFeatures/           emoji/macro capture arbitration
│       ├── Rewrite/                  selection rewrite popup coordination
│       │   └── SelectionRewriteCoordinator.swift
│       ├── Suggestion/               autocomplete interaction state machine
│       ├── Translation/              select-to-translate and reply translation
│       │   ├── SelectionTranslationCoordinator.swift
│       │   └── TranslationCoordinator.swift
│       ├── SettingsCoordinator.swift
│       └── WelcomeCoordinator.swift
├── Models/
│   ├── Context/                      bounded context and visual-context values
│   ├── Emoji/                        picker and usage values
│   ├── Focus/                        focus snapshots and tracking state
│   ├── History/                      typing-history records, archive, and preferences
│   ├── Input/                        keyboard event values
│   ├── Onboarding/                   onboarding templates
│   ├── Permissions/                  TCC permission values
│   ├── Rewrite/                      rewrite actions, requests, and results
│   │   └── RewriteModels.swift
│   ├── Runtime/
│   │   └── Metrics/                  performance and system metric stores
│   ├── Settings/                     durable and UI-facing settings values
│   ├── Spelling/                     spelling catalog values
│   ├── Suggestion/
│   │   ├── Request/                  immutable request inputs and configuration
│   │   ├── Result/                   engine result and client error values
│   │   └── Session/                  active, paused, and presented session values
│   └── Translation/                  translation strip and selection values
│       ├── SelectionTranslationModels.swift
│       └── TranslationModels.swift
├── Services/
│   ├── Context/                      live clipboard acquisition
│   ├── Focus/
│   │   ├── Caching/                  field-scoped focus caches
│   │   ├── Chromium/                 Chromium AX enablement and diagnostics
│   │   ├── Resolution/               focus snapshots, geometry, bounded AX walks
│   │   └── ReadOnlySelectionReader.swift
│   ├── History/                      typing-history store, recording, and encrypted vault
│   ├── Input/                        event taps and input-source monitoring
│   │   └── SelectionEventMonitor.swift
│   ├── ModelManagement/              model discovery, download, and validation
│   ├── Permission/
│   │   └── Guidance/                 permission overlay and System Settings guidance
│   ├── Power/                        power-source observation
│   ├── Presentation/                 process-level AppKit panels and indicators
│   │   ├── SelectionRewritePanelController.swift
│   │   ├── SelectionTranslationPanelController.swift
│   │   └── TranslationOverlayController.swift
│   ├── Rewrite/                      rewrite engine, providers, preferences store, and clients
│   ├── Runtime/
│   │   ├── AppleIntelligence/        Foundation Models availability and engine
│   │   ├── Llama/                    llama engine, manager, and native core
│   │   ├── MLX/                      mlx-lm install, mlx_lm.server lifecycle, MLX model files
│   │   └── OpenAICompatible/         endpoint transport, credentials, and engine
│   ├── Spelling/                     live spell-checking services
│   ├── Suggestion/
│   │   └── State/                    work identity and mutable interaction state
│   ├── Translation/                  engines, hotkey tap, preferences, and anchor reader
│   │   ├── TranslationAnchorReader.swift
│   │   ├── TranslationEngines.swift
│   │   ├── TranslationHotkeyTap.swift
│   │   └── TranslationPreferencesStore.swift
│   ├── Updates/                      manual release checks
│   └── Visual/                       capture, OCR, and visual-context sessions
├── Support/
│   ├── Accessibility/                pure AX and secure-surface policies
│   ├── Context/                      sanitization, relevance, and OCR hygiene
│   ├── Emoji/
│   │   ├── Catalog/                  searchable catalog and synonyms
│   │   ├── Interaction/              query, trigger, picker, and variant rules
│   │   └── Ranking/                  recency and popularity rules
│   ├── Focus/
│   │   ├── Applications/             app, browser, domain, and terminal classification
│   │   └── Capability/               supported-field capability resolution
│   ├── History/                      history retrieval, phrase prediction, scrubbing, import
│   ├── Input/                        composition, key-label, and selection helpers
│   ├── Logging/                      debug options, request IDs, and JSONL handlers
│   ├── Macros/
│   │   └── Evaluators/               deterministic arithmetic/date/unit evaluators
│   ├── Onboarding/                   pure onboarding recommendation rules
│   ├── Presentation/
│   │   ├── Geometry/                 caret, anchor, direction, and overlay layout
│   │   ├── Policy/                   render-mode, fade, and stability decisions
│   │   └── Style/                    ghost text font and color rules
│   ├── Prompting/                    Apple and base-model prompt rendering
│   ├── Rewrite/                      rewrite prompts, cleanup, language checks, replace checks
│   ├── Runtime/
│   │   ├── Hardware/                 device capability and resource sampling
│   │   ├── MLX/                      MLX cache scan, toolchain rules, server decision
│   │   ├── BundledRuntimeLocator.swift
│   │   ├── DecodeStopPolicy.swift
│   │   ├── DownloadOutcomeClassifier.swift
│   │   ├── TokenHealingPlan.swift    bounded word-fragment retokenization at the caret
│   │   └── TokenHealingBuffer.swift  exact byte replay and lossless streamed UTF-8
│   ├── Settings/                     persistence and settings policies
│   ├── Spelling/                     extraction, language, SymSpell, and typo rules
│   ├── Suggestion/
│   │   ├── Acceptance/               insertion safety and strategy
│   │   ├── Output/                   normalization, confidence, and seam cleanup
│   │   ├── Request/                  availability, debounce, and request construction
│   │   ├── Session/                  tail reconciliation and exhausted-tail state
│   │   └── Streaming/                partial coalescing, monotonic text, presentation timing
│   ├── Translation/                  few-shot prompts, cache, policy, and strip placement
│   │   ├── ConversationLanguageTracker.swift
│   │   ├── FewShotTranslationPrompt.swift
│   │   ├── MessageBlockGrouper.swift
│   │   ├── SelectionTranslationPolicy.swift
│   │   ├── TranslationCache.swift
│   │   ├── TranslationCoverStyle.swift
│   │   ├── TranslationLanguagePolicy.swift
│   │   ├── TranslationScrollFollow.swift
│   │   └── TranslationStripPlacement.swift
│   └── Utilities/                    small cross-subsystem value helpers
└── UI/
    ├── Components/                   application-wide reusable views
    ├── InlineFeatures/               emoji picker, macro reference, Rewrite and translation views
    │   ├── SelectionRewritePopupView.swift
    │   └── SelectionTranslationStripView.swift
    ├── MenuBar/                      menu-bar status and popover content
    ├── Onboarding/
    │   └── Welcome/                  composed welcome flow and step views
    ├── Overlays/                     SwiftUI overlay content
    └── Settings/
        ├── Components/
        │   ├── Controls/              settings editors, pickers, and previews
        │   └── Structure/             pane scaffolds, rows, cards, and search results
        ├── ModelManagement/           model catalog and browser views
        └── Panes/
            ├── About/                 product and acknowledgement panes
            ├── Engine/                engine pane and backend-specific extensions
            ├── RewritePaneView.swift
            └── TranslationPaneView.swift
~~~

Files left directly inside a subsystem are intentionally its root owners or a small cohesive set.
For example, `SuggestionEngineRouter.swift` remains at `Services/Runtime/` because it coordinates all
three backend folders, while `FocusTracker.swift` remains at `Services/Focus/` because it owns the
whole focus lifecycle rather than one resolution or caching technique.

## Test Tree

`CotabbyTests/` mirrors the production responsibility after removing the leading `Cotabby/`. For
example:

~~~text
Cotabby/Support/Suggestion/Output/SuggestionTextNormalizer.swift
CotabbyTests/Support/Suggestion/Output/SuggestionTextNormalizerTests.swift

Cotabby/Services/Runtime/Llama/LlamaSuggestionEngine.swift
CotabbyTests/Services/Runtime/Llama/LlamaSuggestionEngineStreamingTests.swift

Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator.swift
CotabbyTests/App/Coordinators/Suggestion/SuggestionCoordinatorPredictionTests.swift
~~~

The Rewrite and Translation tests follow the same mirror:

~~~text
CotabbyTests/
├── App/Coordinators/
│   ├── Rewrite/
│   │   └── SelectionRewriteCoordinatorTests.swift
│   └── Translation/
│       ├── SelectionTranslationCoordinatorTests.swift
│       └── TranslationCaptureRowsTests.swift
├── Services/Rewrite/
│   ├── APIRewriteProviderTests.swift
│   ├── LocalEndpointRewriteProviderTests.swift
│   ├── MLXRewriteProviderTests.swift
│   ├── MLXRewriteServerControllerTests.swift
│   ├── RewriteEngineTests.swift
│   ├── RewriteMemoryGathererTests.swift
│   └── RewritePreferencesStoreTests.swift
├── Support/Rewrite/
│   ├── RewriteButtonPlacementTests.swift
│   ├── RewriteChangeWarningTests.swift
│   ├── RewriteLanguageDetectorTests.swift
│   ├── RewriteOutputCleanerTests.swift
│   ├── RewritePromptBuilderTests.swift
│   ├── RewriteProviderResolverTests.swift
│   ├── SelectionReplaceValidatorTests.swift
│   └── SelectionRewriteEligibilityTests.swift
└── Support/Translation/
    ├── SelectionTranslationPolicyTests.swift
    ├── TranslationCoreTests.swift
    ├── TranslationCoverStyleTests.swift
    ├── TranslationScrollFollowTests.swift
    └── TranslationStripPlacementTests.swift
~~~

Tests that exercise several production values may stay at the nearest shared subsystem root. Evals
remain under `CotabbyTests/Evals`, and shared fixtures remain under `CotabbyTests/TestSupport`.

## Unfinished-Word Interaction

- `Support/Suggestion/Request/CaretWordContext.swift` distinguishes a still-typed token from a
  delimiter-committed word. `TypoGate` and the correction replacement planner consume this value;
  pausing alone never makes correction eligible.
- `Support/Suggestion/Output/CompletionSeamGuard.swift` returns the same presentation decision for
  streamed and final output: wait for the first word, reject a malformed join, show a word ending,
  or show a phrase. A recognized completed word keeps its following phrase even from a one-letter
  prefix; unknown names and jargon can still show a conservative word ending.
- `Support/Suggestion/Request/SuggestionRequestFactory.swift` applies the optional
  `suggestWithinWords` preference to new ordinary and speculative requests. The completion settings
  domain persists the choice, while active sessions remain free to follow matching typing.
- `Services/Suggestion/State/SuggestionInteractionState.swift` holds a narrow range of typed
  characters awaiting Accessibility publication. `SuggestionSessionReconciler` tolerates only an
  older matching prefix during this handoff, so a typed space preserves the following words without
  treating unrelated edits as acceptance. Correction sessions never participate in type-through.
- `Models/Suggestion/Session/ActiveSuggestionSession.swift` separates the full prediction from
  the visible acceptance boundary. An uncertain word ending can retain following words without
  offering them early. The `showFollowingWords` completion preference uses the same boundary to
  show one word at a time; even full acceptance inserts only the current visible offer. Matching
  typing consumes the buffered prediction, while streaming may extend it without revising it.
- `Support/Suggestion/Session/SuggestionContinuationPlan.swift` constructs hypothetical completed
  or corrected text and its exact publication target. A virtual separating space asks for the
  next words rather than another ending; it never edits the host field. The coordinator's
  `+Continuation.swift` owns one cancellable lookahead and attaches it to a terminal word ending,
  or holds it behind a correction until the editor publishes that correction. The live context
  buffer remains anchored to observed text throughout this work.
  Additional preaccept lookahead is limited to on-device engines; configured endpoints retain
  already-generated phrases but do not receive the new hypothetical-edit requests.
- `Support/Spelling/WordPrefixIndex.swift` supplies immutable exact-prefix candidates and bounded
  document/glossary vocabulary. `SymSpellCorrector` builds its index on the existing background
  dictionary queue; fallback never uses spelling edit distance or changes typed letters.
- `Support/Suggestion/Streaming/TypingCadence.swift` measures recent inter-letter intervals and
  controls presentation timing independently of generation debounce. `SuggestionStreamingState`
  memoizes exact-word checks and closes the stream when a final result arrives.
- `Support/Suggestion/Streaming/TypingPredictionCandidate.swift` tracks matching typed characters
  against one on-device request and validates their exact Accessibility publication before rebasing
  the remaining text. `SuggestionCoordinator+TypingPrediction.swift` owns that candidate and its
  expiry timer. The default-on `predictAheadWhileTyping` setting controls retention independently
  of streaming display; disabling it cancels retained work through the settings snapshot lifecycle.
- `Support/Suggestion/Session/SuggestionDismissalMemory.swift` remembers explicit dismissal for at
  most 15 seconds in the same field and text context. It is bounded and never persisted.
- `App/Coordinators/Suggestion/SuggestionCoordinator+WordCompletion.swift` adapts these pure values
  to the existing spell checker, dictionaries, settings, and cancellable presentation work.

Direct tests mirror those folders. `SuggestionCoordinatorWordCompletionTests` replays pauses after
individual letters, malformed streams, fallback acceptance, dismissal/cache behavior, and cancellation
against the actual coordinator with synthetic OS and engine boundaries. The phrase accuracy replay
uses the committed typo gate and final display policy, but deliberately excludes local fallback so
its score remains attributable to the model. Timing replay and coordinator interaction tests cover
presentation and acceptance separately; model-only scores do not represent the complete experience.
`SuggestionCoordinatorContinuityTests` covers buffered acceptance, hidden streaming growth, cached
word restoration, correction publication, and late cancellation. `TypingExperienceEvalTests` drives
the production coordinator with the real local engine and a synthetic editor, recording visible
and buffered text plus actual requests in `build/eval/typing-experience.json`. It does not measure
third-party editor AX behavior or visual placement.

## Translate on Select

- `Services/Input/SelectionEventMonitor.swift` installs global `NSEvent` monitors that only listen
  and never consume events. They report the end of a selection gesture: a drag, a double or triple
  click, Shift with the arrow, Home or End keys, or Command-A.
- `App/Coordinators/Translation/SelectionTranslationCoordinator.swift` waits 500 ms after the
  gesture so the selection settles. A newer gesture during that wait cancels the older one.
- The selected text comes from the focus snapshot when the selection is in an editable field. In any
  other field, `Services/Focus/ReadOnlySelectionReader.swift` reads it through three Accessibility
  paths: the selected-text attribute, the selected range with string-for-range, and WebKit or
  Chromium text markers. If those yield nothing, it reads the element under the pointer and up to
  three parents.
- `Support/Translation/SelectionTranslationPolicy.swift` gates the request. It needs an allowed app
  with no secure or credential field, no terminal, and never Cotabby itself. The text must be
  between three letters and 2,000 characters. Text already in the target language is skipped, judged
  first by strict language detection and then by a looser guess for single words.
- The translation runs through the Rewrite provider as `RewriteAction.translate(into:)` and keeps no
  conversation memory.
- `Support/Translation/TranslationStripPlacement.swift` centres the strip above the selection. When
  the Rewrite wand is showing, the strip sits above the wand instead. It goes below the selection
  only when the screen has no room above.
- `Services/Presentation/SelectionTranslationPanelController.swift` owns the panel. The panel never
  becomes key, so Return and Command-C keep going to the host app.
- A window can turn the feature off from its field icon. That per-window veto uses
  `ScopedFeature.translation`.
- The shortcut, Control-Option-L by default, shows the strip for the current selection, or shows it
  again after it was dismissed.
- Settings live in the Translation pane under "Translate on Select", in
  `UI/Settings/Panes/TranslationPaneView.swift`.

## Adding Or Moving A File

1. Identify its single dominant responsibility using the map above.
2. Place or move its direct tests with it conceptually.
3. Update tracked Markdown links and any scripts containing physical paths.
4. Run `xcodegen generate` and commit the regenerated project.
5. Run SwiftLint, a build, and `build-for-testing` before opening a pull request.

When a file seems to fit several folders, that usually signals either a cross-subsystem contract
that belongs in `Models`, a root orchestrator that should remain above its collaborators, or a type
that owns too many responsibilities and should be split by behavior rather than hidden by nesting.

## Conversation Context Freshness

- `Support/Focus/FocusedInputPollingSignature.swift` distinguishes navigation using live URL, title,
  placeholder and field geometry, while ignoring typing and volatile AX wrapper tokens. The focus
  resolver reads these facts before comparing sessions; surface metadata is not frozen in a cache.
- `FocusedInputSessionIdentity` in `Models/Focus/FocusModels.swift` carries that boundary through
  generation, acceptance and speculative work. Prediction memory has a session key separate from
  the geometry/style key so another conversation cannot restore an old suggestion.
- `VisualContextCoordinator` refreshes both backend profiles using their existing capture limits.
  Excerpts expire six seconds after capture starts, even while OCR is pending. Navigation clears
  the published excerpt immediately, and invalidation retires predictions conditioned on it.
