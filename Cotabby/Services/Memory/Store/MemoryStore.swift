import CryptoKit
import Foundation

/// File overview:
/// Conversation memory's encrypted message store: every remembered message, the conversations and
/// people they belong to, each source's sync cursor, and each passage's embedding vector.
///
/// Why one SQLite file: messages, scope keys and vectors change together (an edited message must
/// lose its old vector, a forgotten source its conversations), and transactions keep them consistent.
/// The schema is the one the earlier Python service created (`store.py`), so the existing store opens
/// as-is, plus `vectors` and the keyword `terms` tables.
///
/// What is readable on disk: nothing personal. Text, senders, subjects, titles, conversation ids,
/// participants, cursors and vectors are sealed with `MemoryVault` (AES-GCM); lookups use HMAC tags
/// (`conv_key`, `title_tag`, `participant_tag`, keyword `tag`). Sources and timestamps stay plain,
/// so ordering and per-source counts need no decryption.
///
/// Thread safety: one connection behind one lock. Callers keep work under the lock short; bulk
/// writes arrive in batches, so a search never waits behind a whole sync.
nonisolated final class MemoryStore: @unchecked Sendable {
    struct StoredMessage: Equatable, Sendable {
        let recordID: String
        let source: String
        let conversationID: String
        let conversationKey: String
        let sender: String
        let isFromMe: Bool
        let timestamp: Double
        let subject: String?
        let text: String
    }

    /// One passage's vector as stored: decrypted, with the keys a search filters on.
    struct StoredVector: Sendable {
        let passageID: String
        let recordID: String
        let source: String
        let conversationKey: String
        let timestamp: Double
        let vector: [Float16]
    }

    /// Keyword search decrypts at most this many of a scope's most recent messages per query.
    static let keywordCandidates = 5000

    let vault: MemoryVault
    private let database: MemoryDatabase
    private let lock = NSRecursiveLock()
    /// Decrypted (conversation id, title) per (source, conv_key): small, and read on every search.
    private var conversationNames: [String: (id: String, title: String)] = [:]

    init(path: URL, vault: MemoryVault) throws {
        self.vault = vault
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        database = try MemoryDatabase(path: path.path)
        try migratePlaintextSchema()
        try database.execute(Self.schema)
        try checkKey()
        try switchToNativeEngineOnce()
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS messages (
        record_id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        conv_key TEXT NOT NULL,
        sender BLOB NOT NULL,
        is_from_me INTEGER NOT NULL,
        timestamp REAL NOT NULL,
        subject BLOB,
        text BLOB NOT NULL,
        text_tag TEXT NOT NULL,
        indexed INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS messages_conversation ON messages(source, conv_key, timestamp);
    CREATE INDEX IF NOT EXISTS messages_unindexed ON messages(source, indexed);
    CREATE TABLE IF NOT EXISTS conversations (
        source TEXT NOT NULL,
        conv_key TEXT NOT NULL,
        conversation_id BLOB NOT NULL,
        title BLOB NOT NULL,
        title_tag TEXT NOT NULL,
        last_timestamp REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (source, conv_key)
    );
    CREATE INDEX IF NOT EXISTS conversations_title ON conversations(title_tag);
    CREATE TABLE IF NOT EXISTS participants (
        source TEXT NOT NULL,
        conv_key TEXT NOT NULL,
        participant_tag TEXT NOT NULL,
        participant BLOB NOT NULL,
        PRIMARY KEY (source, conv_key, participant_tag)
    );
    CREATE INDEX IF NOT EXISTS participants_tag ON participants(participant_tag);
    CREATE TABLE IF NOT EXISTS cursors (
        source TEXT PRIMARY KEY,
        cursor BLOB NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS vectors (
        passage_id TEXT PRIMARY KEY,
        record_id TEXT NOT NULL,
        source TEXT NOT NULL,
        conv_key TEXT NOT NULL,
        timestamp REAL NOT NULL,
        model TEXT NOT NULL,
        vector BLOB NOT NULL
    );
    CREATE INDEX IF NOT EXISTS vectors_record ON vectors(record_id);
    CREATE TABLE IF NOT EXISTS terms (
        tag TEXT NOT NULL,
        record_id TEXT NOT NULL,
        tf INTEGER NOT NULL,
        PRIMARY KEY (tag, record_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS terms_record ON terms(record_id);
    CREATE TABLE IF NOT EXISTS term_documents (
        record_id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        length INTEGER NOT NULL
    );
    """

    /// A store written before encryption (plaintext columns, no `conv_key`) cannot be upgraded in
    /// place; it is dropped and the next sync rebuilds it from the sources. VACUUM rewrites the file
    /// so the dropped plaintext pages do not linger.
    private func migratePlaintextSchema() throws {
        let tables = Set(try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.string })
        guard tables.contains("messages") else { return }
        let columns = Set(try database.rows("PRAGMA table_info(messages)").compactMap { $0["name"]?.string })
        guard !columns.contains("conv_key") else { return }
        for table in ["messages_fts", "messages", "conversations", "participants", "cursors"] {
            try database.execute("DROP TABLE IF EXISTS \(table)")
        }
        try database.execute("VACUUM")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func checkKey() throws {
        if let row = try database.rows("SELECT value FROM meta WHERE key = 'key_check'").first, let value = row["value"]?.data {
            try vault.verify(value)
            return
        }
        try database.run("INSERT INTO meta(key, value) VALUES ('key_check', ?)", [.blob(try vault.checkValue())])
        try database.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', ?)", [.blob(Data("2".utf8))])
    }

    /// The Python service marked messages `indexed` when LEANN had them; the native engine indexes
    /// into `vectors` and `terms`, so the first open by it resets the marks once.
    private func switchToNativeEngineOnce() throws {
        guard try database.rows("SELECT value FROM meta WHERE key = 'engine'").isEmpty else { return }
        try database.transaction {
            try database.run("UPDATE messages SET indexed = 0")
            try database.run("INSERT INTO meta(key, value) VALUES ('engine', ?)", [.blob(Data("native-1".utf8))])
        }
    }

    // MARK: - Keys

    func conversationKey(source: String, conversationID: String) -> String {
        vault.tag("conv\u{1f}\(source)\u{1f}\(conversationID)")
    }

    func titleTag(_ title: String) -> String {
        vault.tag("title\u{1f}\(ConversationTitleKey.key(title))")
    }

    func participantTag(_ participant: String) -> String {
        vault.tag("person\u{1f}\(ParticipantNormalizer.normalize(participant))")
    }

    func termTag(_ term: String) -> String {
        vault.tag("term\u{1f}\(term)")
    }

    /// A record's stable id across syncs, derived from the source's own message id, so re-reading a
    /// source replaces rows instead of duplicating them (same derivation as the Python service).
    static func recordID(source: String, sourceMessageID: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(source)\u{1f}\(sourceMessageID)".utf8))
        return "\(source):" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    // MARK: - Writing

    /// Inserts or replaces records (already scrubbed) and their conversations. Returns how many
    /// messages changed; a changed message loses its vectors and terms until it is indexed again.
    @discardableResult
    func upsert(source: String, records: [MemoryIngestRecord]) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try database.transaction {
            var changed = 0
            for record in records {
                let recordID = Self.recordID(source: source, sourceMessageID: record.sourceMessageID)
                let convKey = conversationKey(source: source, conversationID: record.conversationID)
                // Unchanged messages are recognized by a tag of their content, since sealed bytes
                // differ on every write (random nonce).
                let textTag = vault.tag("msg\u{1f}\(record.sender)\u{1f}\(record.subject ?? "")\u{1f}\(record.text)")
                let existing = try database.rows("SELECT text_tag FROM messages WHERE record_id = ?", [.text(recordID)]).first
                if existing?["text_tag"]?.string != textTag {
                    try database.run(
                        """
                        INSERT INTO messages(record_id, source, conv_key, sender, is_from_me, timestamp, subject, text, text_tag, indexed)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                        ON CONFLICT(record_id) DO UPDATE SET
                          sender = excluded.sender, subject = excluded.subject, text = excluded.text,
                          text_tag = excluded.text_tag, timestamp = excluded.timestamp, indexed = 0
                        """,
                        [
                            .text(recordID), .text(source), .text(convKey), .blob(try vault.seal(record.sender)),
                            .integer(record.isFromMe ? 1 : 0), .real(record.timestamp.timeIntervalSince1970),
                            try record.subject.map { .blob(try vault.seal($0)) } ?? .null,
                            .blob(try vault.seal(record.text)), .text(textTag),
                        ]
                    )
                    if existing != nil { try removeIndexEntries(recordIDs: [recordID]) }
                    changed += 1
                }
                try upsertConversation(source: source, record: record, conversationKey: convKey)
            }
            return changed
        }
    }

    private func upsertConversation(source: String, record: MemoryIngestRecord, conversationKey convKey: String) throws {
        let timestamp = record.timestamp.timeIntervalSince1970
        let title = record.conversationTitle
        if let current = try database.rows(
            "SELECT title, last_timestamp FROM conversations WHERE source = ? AND conv_key = ?", [.text(source), .text(convKey)]
        ).first {
            if !title.isEmpty, let sealed = current["title"]?.data, (try? vault.open(sealed)) != title {
                try database.run(
                    "UPDATE conversations SET title = ?, title_tag = ? WHERE source = ? AND conv_key = ?",
                    [.blob(try vault.seal(title)), .text(titleTag(title)), .text(source), .text(convKey)]
                )
                conversationNames[source + "\u{1f}" + convKey] = nil
            }
            if timestamp > (current["last_timestamp"]?.double ?? 0) {
                try database.run(
                    "UPDATE conversations SET last_timestamp = ? WHERE source = ? AND conv_key = ?",
                    [.real(timestamp), .text(source), .text(convKey)]
                )
            }
        } else {
            try database.run(
                "INSERT INTO conversations(source, conv_key, conversation_id, title, title_tag, last_timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(source), .text(convKey), .blob(try vault.seal(record.conversationID)), .blob(try vault.seal(title)),
                 .text(titleTag(title)), .real(timestamp)]
            )
        }
        // The other people in the conversation: its listed participants plus whoever sent a message
        // that is not the user's own. The user is never a participant of their own conversations,
        // or the audience rule would match every chat.
        var people = Set(record.participants)
        if !record.isFromMe, !record.sender.isEmpty { people.insert(record.sender) }
        for person in people {
            let normalized = ParticipantNormalizer.normalize(person)
            guard !normalized.isEmpty else { continue }
            try database.run(
                "INSERT OR IGNORE INTO participants(source, conv_key, participant_tag, participant) VALUES (?, ?, ?, ?)",
                [.text(source), .text(convKey), .text(participantTag(normalized)), .blob(try vault.seal(normalized))]
            )
        }
    }

    private func removeIndexEntries(recordIDs: [String]) throws {
        for recordID in recordIDs {
            try database.run("DELETE FROM vectors WHERE record_id = ?", [.text(recordID)])
            try database.run("DELETE FROM terms WHERE record_id = ?", [.text(recordID)])
            try database.run("DELETE FROM term_documents WHERE record_id = ?", [.text(recordID)])
        }
    }

    /// Stores one message's passage vectors and keyword terms and marks it indexed, in one
    /// transaction: a message is either fully searchable or not at all.
    func saveIndexEntries(_ entries: [(message: StoredMessage, passages: [(passageID: String, vector: [Float16])])], model: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            for entry in entries {
                let message = entry.message
                try removeIndexEntries(recordIDs: [message.recordID])
                for passage in entry.passages {
                    let bytes = passage.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try database.run(
                        "INSERT OR REPLACE INTO vectors(passage_id, record_id, source, conv_key, timestamp, model, vector) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(passage.passageID), .text(message.recordID), .text(message.source), .text(message.conversationKey),
                         .real(message.timestamp), .text(model), .blob(try vault.sealData(bytes))]
                    )
                }
                let terms = MemoryTerms.terms(message.text + " " + (message.subject ?? ""))
                var frequency: [String: Int] = [:]
                for term in terms { frequency[term, default: 0] += 1 }
                for (term, count) in frequency {
                    try database.run(
                        "INSERT OR REPLACE INTO terms(tag, record_id, tf) VALUES (?, ?, ?)",
                        [.text(termTag(term)), .text(message.recordID), .integer(Int64(count))]
                    )
                }
                try database.run(
                    "INSERT OR REPLACE INTO term_documents(record_id, source, length) VALUES (?, ?, ?)",
                    [.text(message.recordID), .text(message.source), .integer(Int64(terms.count))]
                )
                try database.run("UPDATE messages SET indexed = 1 WHERE record_id = ?", [.text(message.recordID)])
            }
        }
    }

    /// Drops every vector not made by `model` (the embedding model changed) and marks their
    /// messages for indexing again. Returns how many messages need it.
    @discardableResult
    func invalidateVectors(notMadeBy model: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try database.transaction {
            try database.run(
                "UPDATE messages SET indexed = 0 WHERE record_id IN (SELECT DISTINCT record_id FROM vectors WHERE model != ?)",
                [.text(model)]
            )
            try database.run("DELETE FROM vectors WHERE model != ?", [.text(model)])
            return Int(try database.rows("SELECT COUNT(*) AS n FROM messages WHERE indexed = 0").first?["n"]?.int ?? 0)
        }
    }

    func deleteSource(_ source: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            for table in ["messages", "conversations", "participants", "cursors", "vectors", "term_documents"] {
                try database.run("DELETE FROM \(table) WHERE source = ?", [.text(source)])
            }
            try database.run("DELETE FROM terms WHERE record_id NOT IN (SELECT record_id FROM term_documents)")
        }
        conversationNames.removeAll()
    }

    /// Deletes excluded and expired messages with their vectors and terms. Returns how many went.
    @discardableResult
    func purge(excludedConversations: [String], excludedParticipants: [String], olderThan: Double?) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try database.transaction {
            var doomed: [[String: MemoryDatabase.Value]] = []
            let wanted = Set(excludedConversations)
            if !wanted.isEmpty {
                for row in try database.rows("SELECT source, conv_key, conversation_id FROM conversations") {
                    if let sealed = row["conversation_id"]?.data, let id = try? vault.open(sealed), wanted.contains(id) {
                        doomed += try database.rows("SELECT record_id FROM messages WHERE source = ? AND conv_key = ?",
                                                    [row["source"] ?? .null, row["conv_key"] ?? .null])
                    }
                }
            }
            for person in excludedParticipants {
                for row in try database.rows("SELECT source, conv_key FROM participants WHERE participant_tag = ?", [.text(participantTag(person))]) {
                    doomed += try database.rows("SELECT record_id FROM messages WHERE source = ? AND conv_key = ?",
                                                [row["source"] ?? .null, row["conv_key"] ?? .null])
                }
            }
            if let olderThan {
                doomed += try database.rows("SELECT record_id FROM messages WHERE timestamp < ?", [.real(olderThan)])
            }
            let ids = Set(doomed.compactMap { $0["record_id"]?.string })
            for id in ids {
                try database.run("DELETE FROM messages WHERE record_id = ?", [.text(id)])
            }
            try removeIndexEntries(recordIDs: Array(ids))
            return ids.count
        }
    }

    func deleteEverything() throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            for table in ["messages", "conversations", "participants", "cursors", "vectors", "terms", "term_documents"] {
                try database.run("DELETE FROM \(table)")
            }
        }
        try database.execute("VACUUM")
        conversationNames.removeAll()
    }

    func setCursor(_ cursor: String, source: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.run(
            "INSERT INTO cursors(source, cursor, updated_at) VALUES (?, ?, ?) ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at",
            [.text(source), .blob(try vault.seal(cursor)), .real(Date().timeIntervalSince1970)]
        )
    }

    // MARK: - Reading

    func cursor(source: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let sealed = try database.rows("SELECT cursor FROM cursors WHERE source = ?", [.text(source)]).first?["cursor"]?.data else {
            return nil
        }
        return try vault.open(sealed)
    }

    struct SourceStats: Equatable, Sendable {
        let messages: Int
        let pending: Int
        let conversations: Int
        let newestTimestamp: Double?
        let lastSync: Double?
    }

    func sourceStats(_ source: String) throws -> SourceStats {
        lock.lock()
        defer { lock.unlock() }
        let row = try database.rows(
            "SELECT COUNT(*) AS n, SUM(indexed = 0) AS pending, COUNT(DISTINCT conv_key) AS conversations, MAX(timestamp) AS newest FROM messages WHERE source = ?",
            [.text(source)]
        ).first ?? [:]
        let lastSync = try database.rows("SELECT updated_at FROM cursors WHERE source = ?", [.text(source)]).first?["updated_at"]?.double
        return SourceStats(
            messages: Int(row["n"]?.int ?? 0), pending: Int(row["pending"]?.int ?? 0),
            conversations: Int(row["conversations"]?.int ?? 0), newestTimestamp: row["newest"]?.double, lastSync: lastSync
        )
    }

    /// Messages not yet indexed, newest first (recent history matters most, so it becomes
    /// searchable first), from `sources`.
    func unindexedMessages(sources: [String], limit: Int) throws -> [StoredMessage] {
        guard !sources.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        let rows = try database.rows(
            "SELECT * FROM messages WHERE indexed = 0 AND source IN (\(placeholders)) ORDER BY timestamp DESC LIMIT ?",
            sources.map { .text($0) } + [.integer(Int64(limit))]
        )
        return rows.compactMap(stored)
    }

    func unindexedCount(sources: [String]) throws -> Int {
        guard !sources.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        return Int(try database.rows(
            "SELECT COUNT(*) AS n FROM messages WHERE indexed = 0 AND source IN (\(placeholders))", sources.map { .text($0) }
        ).first?["n"]?.int ?? 0)
    }

    /// Every vector made by `model`, decrypted, for loading the in-memory index.
    func vectors(model: String) throws -> [StoredVector] {
        lock.lock()
        defer { lock.unlock() }
        return try database.rows(
            "SELECT passage_id, record_id, source, conv_key, timestamp, vector FROM vectors WHERE model = ?", [.text(model)]
        ).compactMap { row in
            guard let passageID = row["passage_id"]?.string, let recordID = row["record_id"]?.string,
                  let source = row["source"]?.string, let convKey = row["conv_key"]?.string,
                  let sealed = row["vector"]?.data, let bytes = try? vault.openData(sealed) else { return nil }
            let vector = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return StoredVector(passageID: passageID, recordID: recordID, source: source, conversationKey: convKey,
                                timestamp: row["timestamp"]?.double ?? 0, vector: vector)
        }
    }

    func conversationName(source: String, conversationKey convKey: String) -> (id: String, title: String) {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = source + "\u{1f}" + convKey
        if let cached = conversationNames[cacheKey] { return cached }
        let row = (try? database.rows(
            "SELECT conversation_id, title FROM conversations WHERE source = ? AND conv_key = ?", [.text(source), .text(convKey)]
        ))?.first
        let names = (
            id: row?["conversation_id"]?.data.flatMap { try? vault.open($0) } ?? "",
            title: row?["title"]?.data.flatMap { try? vault.open($0) } ?? ""
        )
        conversationNames[cacheKey] = names
        return names
    }

    private func conversation(source: String, conversationKey convKey: String) throws -> MemoryConversation? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = try database.rows(
            "SELECT last_timestamp FROM conversations WHERE source = ? AND conv_key = ?", [.text(source), .text(convKey)]
        ).first else { return nil }
        let people = try database.rows(
            "SELECT participant FROM participants WHERE source = ? AND conv_key = ?", [.text(source), .text(convKey)]
        ).compactMap { $0["participant"]?.data.flatMap { try? vault.open($0) } }
        let names = conversationName(source: source, conversationKey: convKey)
        return MemoryConversation(source: source, conversationId: names.id, title: names.title,
                                  participants: people.sorted(), lastTimestamp: row["last_timestamp"]?.double ?? 0)
    }

    func conversation(source: String, conversationID: String) throws -> MemoryConversation? {
        try conversation(source: source, conversationKey: conversationKey(source: source, conversationID: conversationID))
    }

    /// Conversations whose title matches `title` (normalized), most recent first.
    func findConversations(title: String, sources: [String]) throws -> [MemoryConversation] {
        guard !ConversationTitleKey.key(title).isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let rows = try database.rows(
            "SELECT source, conv_key FROM conversations WHERE title_tag = ? ORDER BY last_timestamp DESC", [.text(titleTag(title))]
        )
        return try rows.compactMap { row -> MemoryConversation? in
            guard let source = row["source"]?.string, sources.isEmpty || sources.contains(source),
                  let convKey = row["conv_key"]?.string else { return nil }
            return try conversation(source: source, conversationKey: convKey)
        }
    }

    /// The most recently active conversations of `sources`.
    func recentConversations(sources: [String], limit: Int) throws -> [MemoryConversation] {
        guard !sources.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        let rows = try database.rows(
            "SELECT source, conv_key FROM conversations WHERE source IN (\(placeholders)) ORDER BY last_timestamp DESC LIMIT ?",
            sources.map { .text($0) } + [.integer(Int64(limit))]
        )
        return try rows.compactMap { row in
            guard let source = row["source"]?.string, let convKey = row["conv_key"]?.string else { return nil }
            return try conversation(source: source, conversationKey: convKey)
        }
    }

    /// (source, conversation key) pairs with EXACTLY the same people as `audience`, most recent
    /// first: the "same person" scope.
    ///
    /// The rule is about who will read the suggestion: text from another conversation may only
    /// surface if the people being written to now are exactly the people who were in that one. A
    /// superset rule is not safe, because member lists do not say when someone joined or left, so a
    /// group cannot vouch for what any one member saw. A 1:1 with Ayşe can draw on another 1:1 with
    /// Ayşe (her mail thread), groups only on groups with the same members, never one into the other.
    func conversationsSeenBy(audience: [String], excluding: (source: String, conversationKey: String)?, limit: Int = 50) throws
        -> [(source: String, conversationKey: String)] {
        let tags = Array(Set(audience.filter { !ParticipantNormalizer.normalize($0).isEmpty }.map(participantTag))).sorted()
        guard !tags.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = tags.map { _ in "?" }.joined(separator: ",")
        let rows = try database.rows(
            """
            SELECT p.source, p.conv_key FROM participants p
            JOIN conversations c ON c.source = p.source AND c.conv_key = p.conv_key
            GROUP BY p.source, p.conv_key
            HAVING COUNT(DISTINCT p.participant_tag) = ? AND SUM(p.participant_tag IN (\(placeholders))) = ?
            ORDER BY MAX(c.last_timestamp) DESC LIMIT ?
            """,
            [.integer(Int64(tags.count))] + tags.map { .text($0) } + [.integer(Int64(tags.count)), .integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let source = row["source"]?.string, let convKey = row["conv_key"]?.string else { return nil }
            if let excluding, excluding.source == source, excluding.conversationKey == convKey { return nil }
            return (source, convKey)
        }
    }

    /// The latest messages of the given conversations, newest first.
    func recentMessages(conversations: [(source: String, conversationKey: String)], limit: Int) throws -> [StoredMessage] {
        guard !conversations.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let clauses = conversations.map { _ in "(source = ? AND conv_key = ?)" }.joined(separator: " OR ")
        let parameters = conversations.flatMap { [MemoryDatabase.Value.text($0.source), .text($0.conversationKey)] }
        return try database.rows(
            "SELECT * FROM messages WHERE \(clauses) ORDER BY timestamp DESC LIMIT ?", parameters + [.integer(Int64(limit))]
        ).compactMap(stored)
    }

    /// Keyword search restricted to the given conversations: decrypts their most recent messages
    /// and ranks them with `KeywordScorer`. Filter-first, so it never returns a message from outside
    /// the scope however relevant.
    func keywordSearch(query: String, conversations: [(source: String, conversationKey: String)], limit: Int) throws -> [StoredMessage] {
        let candidates = try recentMessages(conversations: conversations, limit: Self.keywordCandidates)
        let ranked = KeywordScorer.rank(
            query: query, documents: candidates.map { $0.text + " " + ($0.subject ?? "") }, limit: limit
        )
        return ranked.map { candidates[$0] }
    }

    /// Keyword search across whole sources without decrypting them: BM25 over the HMAC-tagged
    /// terms of indexed messages (exact words; no prefix matching). Returns record ids, best first.
    func taggedKeywordSearch(query: String, sources: [String], limit: Int) throws -> [String] {
        let terms = Array(Set(MemoryTerms.terms(query)))
        guard !terms.isEmpty, !sources.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let sourcePlaceholders = sources.map { _ in "?" }.joined(separator: ",")
        let sourceValues = sources.map { MemoryDatabase.Value.text($0) }
        let totals = try database.rows(
            "SELECT COUNT(*) AS n, AVG(length) AS average FROM term_documents WHERE source IN (\(sourcePlaceholders))", sourceValues
        ).first
        let documents = Double(totals?["n"]?.int ?? 0)
        let averageLength = max(totals?["average"]?.double ?? 1, 1)
        guard documents > 0 else { return [] }
        var scores: [String: Double] = [:]
        for term in terms {
            let rows = try database.rows(
                """
                SELECT t.record_id, t.tf, d.length FROM terms t JOIN term_documents d ON d.record_id = t.record_id
                WHERE t.tag = ? AND d.source IN (\(sourcePlaceholders))
                """,
                [.text(termTag(term))] + sourceValues
            )
            guard !rows.isEmpty else { continue }
            let df = Double(rows.count)
            let idf = log(1 + (documents - df + 0.5) / (df + 0.5))
            for row in rows {
                guard let recordID = row["record_id"]?.string else { continue }
                let tf = row["tf"]?.double ?? 0
                let length = row["length"]?.double ?? averageLength
                scores[recordID, default: 0] += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
        }
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    func message(recordID: String) throws -> StoredMessage? {
        lock.lock()
        defer { lock.unlock() }
        return try database.rows("SELECT * FROM messages WHERE record_id = ?", [.text(recordID)]).first.flatMap(stored)
    }

    private func stored(_ row: [String: MemoryDatabase.Value]) -> StoredMessage? {
        guard let recordID = row["record_id"]?.string, let source = row["source"]?.string,
              let convKey = row["conv_key"]?.string, let text = row["text"]?.data.flatMap({ try? vault.open($0) }) else { return nil }
        return StoredMessage(
            recordID: recordID, source: source,
            conversationID: conversationName(source: source, conversationKey: convKey).id, conversationKey: convKey,
            sender: row["sender"]?.data.flatMap { try? vault.open($0) } ?? "",
            isFromMe: (row["is_from_me"]?.int ?? 0) != 0, timestamp: row["timestamp"]?.double ?? 0,
            subject: row["subject"]?.data.flatMap { try? vault.open($0) }, text: text
        )
    }
}
