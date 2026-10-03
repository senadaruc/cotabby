import Foundation

/// File overview:
/// The values Cotabby exchanges with the conversation memory service (`MemoryService/`, Python).
///
/// Each type mirrors one JSON shape the service returns (see `MemoryService/src/cotabby_memory/
/// service.py`). They are decoded with `convertFromSnakeCase`, so Swift names follow Swift style and
/// the service keeps Python style. Keeping every wire shape in this one file makes a protocol change
/// a single, reviewable diff on the Swift side.

/// `status`: what the running service reports about itself.
struct MemoryServiceStatus: Decodable, Equatable, Sendable {
    let serviceVersion: String
    let protocolVersion: Int
    let leannVersion: String?
    let python: String
    let dataDir: String
    let uptimeSeconds: Double
    let busy: Bool
    let index: MemoryIndexStatus
    let enabledSources: [String]
}

/// `index.status`.
struct MemoryIndexStatus: Decodable, Equatable, Sendable {
    let built: Bool
    let builtAt: Double?
    let passages: Int
    let sizeBytes: Int
    /// Why the index must be rebuilt before it reflects the settings and the store, if it must.
    let needsRebuild: String?
}

/// The index settings the Memory pane edits (`config.index`). Every LEANN build and search knob the
/// service exposes; ranges are enforced by the service, which reports rejected keys.
struct MemoryIndexSettings: Codable, Equatable, Sendable {
    var backend: String
    var embeddingMode: String
    var embeddingModel: String
    var chunkSize: Int
    var chunkOverlap: Int
    var graphDegree: Int
    var buildComplexity: Int
    var recompute: Bool
    var compact: Bool
    var searchComplexity: Int
    var topK: Int
    var vectorWeight: Double

    static let backends = ["hnsw", "diskann"]
    static let embeddingModes = ["sentence-transformers", "ollama", "openai", "mlx"]
}

/// One source's saved settings (`config.sources[id]`).
struct MemorySourceSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var options: [String: String]

    init(enabled: Bool, options: [String: String]) {
        self.enabled = enabled
        self.options = options
    }

    /// Options are free-form JSON on the service side; the pane only edits strings, so any other
    /// value type is shown as its JSON text rather than failing the whole config decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let raw = try container.decodeIfPresent([String: MemoryJSONValue].self, forKey: .options) ?? [:]
        options = raw.mapValues(\.text)
    }
}

/// `config.privacy`.
struct MemoryPrivacySettings: Codable, Equatable, Sendable {
    var excludedConversations: [String]
    var excludedParticipants: [String]
    var retentionDays: Int
}

/// `config.get` / `config.set`.
struct MemoryConfiguration: Codable, Equatable, Sendable {
    var index: MemoryIndexSettings
    var sources: [String: MemorySourceSettings]
    var privacy: MemoryPrivacySettings
}

/// `sources.list`: one connector, its settings and its state.
struct MemorySource: Decodable, Equatable, Identifiable, Sendable {
    struct Requirement: Decodable, Equatable, Sendable {
        let kind: String
        let title: String
        let detail: String
    }

    struct Check: Decodable, Equatable, Sendable {
        let ok: Bool
        let message: String
    }

    struct Stats: Decodable, Equatable, Sendable {
        let messages: Int
        let pending: Int
        let conversations: Int
        let newestTimestamp: Double?
        let lastSync: Double?
    }

    let id: String
    let title: String
    let description: String
    /// "local" (files on this Mac) or "cloud" (a service the user signed into).
    let kind: String
    /// The apps whose fields this source's memory serves.
    let appBundleIds: [String]
    let requirements: [Requirement]
    let optionsSchema: [String: String]
    let enabled: Bool
    let options: [String: String]
    let check: Check
    let stats: Stats

    private enum CodingKeys: String, CodingKey {
        case id, title, description, kind, appBundleIds, requirements, optionsSchema, enabled, options, check, stats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        kind = try container.decode(String.self, forKey: .kind)
        appBundleIds = try container.decode([String].self, forKey: .appBundleIds)
        requirements = try container.decode([Requirement].self, forKey: .requirements)
        optionsSchema = try container.decode([String: String].self, forKey: .optionsSchema)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        options = try container.decode([String: MemoryJSONValue].self, forKey: .options).mapValues(\.text)
        check = try container.decode(Check.self, forKey: .check)
        stats = try container.decode(Stats.self, forKey: .stats)
    }
}

/// `jobs.list`: one queued, running or finished piece of background work.
struct MemoryJob: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let kind: String
    let title: String
    let status: String
    let progress: Double
    let message: String
    let createdAt: Double
    let startedAt: Double?
    let finishedAt: Double?
    let error: String?

    var isActive: Bool { status == "queued" || status == "running" }
}

/// A conversation the service knows (`conversations.find`, `search`).
struct MemoryConversation: Decodable, Equatable, Hashable, Sendable {
    let source: String
    let conversationId: String
    let title: String
    let participants: [String]
    let lastTimestamp: Double
}

/// `search`: what memory returned for one query, and how widely it had to look.
struct MemorySearchResult: Decodable, Equatable, Sendable {
    struct Hit: Decodable, Equatable, Identifiable, Sendable {
        let recordId: String
        let source: String
        let conversationId: String
        let conversationTitle: String
        let sender: String
        let isFromMe: Bool
        let timestamp: Double
        let subject: String?
        let text: String
        let score: Double
        /// "vector", "keyword" or "both": which retrieval path found it.
        let via: String

        var id: String { recordId }
    }

    /// "conversation", "person", "global", or "none" when the conversation was not recognized.
    let scope: String
    let conversation: MemoryConversation?
    let elapsedMs: Double
    let hits: [Hit]

    static let empty = MemorySearchResult(scope: "none", conversation: nil, elapsedMs: 0, hits: [])
}

/// A JSON value of any type, for the few free-form fields (source options). `text` renders it for
/// the pane's string fields.
enum MemoryJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case other(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .other("")
        }
    }

    var text: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .other(let value): return value
        }
    }
}
