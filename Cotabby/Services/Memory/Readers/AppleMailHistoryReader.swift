import Foundation

/// File overview:
/// Reads the Mail app's local mail for conversation memory.
///
/// Mail keeps an index of every message in `~/Library/Mail/V10/MailData/Envelope Index` (SQLite:
/// subjects, senders, recipients, mailboxes, thread ids, and for messages Mail has rendered, a
/// plain-text summary of the body) and each message itself as an `.emlx` file. Both are protected
/// by Full Disk Access. The layout is undocumented, so columns are probed before reading.
///
/// Mapping to memory records:
/// - Conversation: Mail's own thread (`conversation_id`), titled with the thread's subject without
///   its "Re:"/"Fwd:" prefix; the compose window's title is that subject, which is how Cotabby finds
///   the thread for the message being written.
/// - From me: the sender is one of the user's own addresses, learned from what was sent from Sent
///   mailboxes (folder names vary by provider and language, so it is the addresses that matter).
/// - Participants: every other address on the message (sender and recipients), lowercased.
/// - Body: Mail's stored summary when present, else the `.emlx` file parsed by
///   `EmailBodyExtractor`. Quoted history is stripped by the service.
/// - Cursor: the message's ROWID, which only grows.
nonisolated struct AppleMailHistoryReader: MemoryHistoryReading {
    let sourceID = "apple_mail"
    let mailRoot: String
    /// The ROWID -> `.emlx` map, built once per reader (one sync run) instead of once per page:
    /// walking a large mail folder takes seconds.
    private let fileIndex = EmlxFileIndex()

    init(mailRoot: String = NSHomeDirectory() + "/Library/Mail/V10") {
        self.mailRoot = mailRoot
    }

    var envelopeIndexPath: String { mailRoot + "/MailData/Envelope Index" }

    func readiness() -> MemorySourceReadiness {
        do {
            let database = try ReadOnlySQLiteDatabase(path: envelopeIndexPath)
            return try schemaMatches(database) ? .ready
                : .failed("This version of Mail stores messages differently; memory cannot read it yet.")
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            return error.readiness
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["ROWID", "sender", "subject", "summary", "date_received", "mailbox", "deleted", "conversation_id"],
            in: "messages"
        ) && database.hasColumns(["ROWID", "subject"], in: "subjects")
            && database.hasColumns(["ROWID", "address", "comment"], in: "addresses")
            && database.hasColumns(["message", "address", "type"], in: "recipients")
            && database.hasColumns(["ROWID", "url"], in: "mailboxes")
            && database.hasColumns(["ROWID", "summary"], in: "summaries")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let database = try ReadOnlySQLiteDatabase(path: envelopeIndexPath)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized Mail database layout.")
        }
        let after = Int64(cursor ?? "") ?? 0
        let sinceSeconds = since?.timeIntervalSince1970 ?? 0
        let rows = try database.rows(
            """
            SELECT m.ROWID AS rowid, m.conversation_id AS thread, m.date_received AS received,
                   s.subject AS subject, a.address AS sender, a.comment AS sender_name, sm.summary AS summary
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN summaries sm ON sm.ROWID = m.summary
            WHERE m.ROWID > ? AND m.deleted = 0 AND m.date_received >= ?
            ORDER BY m.ROWID LIMIT ?
            """,
            [.integer(after), .real(sinceSeconds), .integer(Int64(limit))]
        )
        guard !rows.isEmpty else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }

        let ownAddresses = try Self.ownAddresses(database)
        let recipients = try Self.recipients(of: rows.compactMap { $0["rowid"]?.int }, database: database)
        let needFiles = rows.contains { ($0["summary"]?.string?.count ?? 0) < 40 }
        let files = needFiles ? fileIndex.files(under: mailRoot, build: emlxFiles) : [:]

        var records: [MemoryIngestRecord] = []
        for row in rows {
            guard let rowid = row["rowid"]?.int else { continue }
            let senderAddress = (row["sender"]?.string ?? "").lowercased()
            let summary = row["summary"]?.string ?? ""
            let body: String?
            if summary.count >= 40 {
                body = summary
            } else if let path = files[rowid], let data = FileManager.default.contents(atPath: path) {
                body = EmailBodyExtractor.bodyFromEmlx(data)
            } else {
                body = nil
            }
            guard let text = body, !text.isEmpty else { continue }
            let subject = Self.baseSubject(row["subject"]?.string ?? "")
            let others = Set(([senderAddress] + (recipients[rowid] ?? [])).filter { !$0.isEmpty && !ownAddresses.contains($0) })
            let thread = row["thread"]?.int.map(String.init) ?? "message-\(rowid)"
            records.append(MemoryIngestRecord(
                sourceMessageID: String(rowid),
                conversationID: thread,
                conversationTitle: subject,
                sender: Self.displayName(address: senderAddress, comment: row["sender_name"]?.string),
                isFromMe: ownAddresses.contains(senderAddress),
                timestamp: Date(timeIntervalSince1970: row["received"]?.double ?? 0),
                text: text,
                participants: others.sorted(),
                subject: subject
            ))
        }
        let last = rows.last?["rowid"]?.int
        return MemoryReadPage(records: records, nextCursor: last.map(String.init), hasMore: rows.count == limit)
    }

    // MARK: - Helpers

    /// The user's own addresses: senders of messages filed in Sent mailboxes. Folder names differ by
    /// provider and language ("Sent Messages", "Sent Items", "Gönderilmiş Postalar"), so several
    /// patterns are matched against the mailbox URL.
    static func ownAddresses(_ database: ReadOnlySQLiteDatabase) throws -> Set<String> {
        let rows = try database.rows(
            """
            SELECT DISTINCT lower(a.address) AS address FROM messages m
            JOIN mailboxes mb ON mb.ROWID = m.mailbox
            JOIN addresses a ON a.ROWID = m.sender
            WHERE mb.url LIKE '%Sent%' OR mb.url LIKE '%G%C3%B6nderil%' OR mb.url LIKE '%Gesendet%'
               OR mb.url LIKE '%Envoy%' OR mb.url LIKE '%Enviad%'
            """
        )
        return Set(rows.compactMap { $0["address"]?.string })
    }

    static func recipients(of messages: [Int64], database: ReadOnlySQLiteDatabase) throws -> [Int64: [String]] {
        guard let first = messages.min(), let last = messages.max() else { return [:] }
        let rows = try database.rows(
            """
            SELECT r.message AS message, lower(a.address) AS address FROM recipients r
            JOIN addresses a ON a.ROWID = r.address WHERE r.message BETWEEN ? AND ?
            """,
            [.integer(first), .integer(last)]
        )
        var result: [Int64: [String]] = [:]
        for row in rows {
            guard let message = row["message"]?.int, let address = row["address"]?.string else { continue }
            result[message, default: []].append(address)
        }
        return result
    }

    /// Maps message ROWIDs to their `.emlx` files. Mail names each file `<ROWID>.emlx` (or
    /// `<ROWID>.partial.emlx` when attachments are stored separately) somewhere under the account's
    /// mailbox folders.
    func emlxFiles() -> [Int64: String] {
        var files: [Int64: String] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: mailRoot) else { return files }
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".emlx") else { continue }
            let name = (relative as NSString).lastPathComponent
            guard let rowid = Int64(name.split(separator: ".").first ?? "") else { continue }
            // Prefer a full message over a partial one when both exist.
            if files[rowid] == nil || !name.contains("partial") {
                files[rowid] = mailRoot + "/" + relative
            }
        }
        return files
    }

    /// A subject without its reply and forward prefixes, so every message of a thread (and the
    /// compose window's title) agree on one title.
    static func baseSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        let prefix = try? NSRegularExpression(pattern: "^(re|fw|fwd|aw|wg|sv|ynt|ilt|tr)\\s*(\\[\\d+\\])?\\s*:\\s*", options: .caseInsensitive)
        while let prefix, let match = prefix.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func displayName(address: String, comment: String?) -> String {
        let name = comment?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
        return name.isEmpty ? address : name
    }
}

/// Caches the `.emlx` file map for one reader. A class (with a lock) so the reader struct can stay
/// a Sendable value while the map is built lazily on first need.
nonisolated private final class EmlxFileIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [Int64: String]?

    func files(under root: String, build: () -> [Int64: String]) -> [Int64: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let built = build()
        cached = built
        return built
    }
}
