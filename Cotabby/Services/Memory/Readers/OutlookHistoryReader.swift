import Foundation

/// File overview:
/// Reads the mail that Outlook for Mac keeps in its local profile database, for conversation memory.
///
/// Where the mail is: classic ("legacy") Outlook keeps every message it has synced in
/// `~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/<profile>/Data/Outlook.sqlite`
/// (table `Mail`: subject, sender, recipients, thread, times, and a plain-text preview of the body).
/// The message bodies live in a proprietary binary format next to it, so only the preview is used:
/// up to about 250 characters of what the message itself says, which is the part memory needs.
///
/// What it does not cover: New Outlook keeps its mail in `HxStore.hxd`, an undocumented format with
/// no readable message files, and stops updating `Outlook.sqlite`. After switching to New Outlook
/// this reader therefore sees the mail up to the switch. Adding the same account to Apple Mail
/// makes its current mail available through the Apple Mail source instead.
///
/// The group container belongs to another app and is protected by macOS (App Data protection, which
/// Full Disk Access covers). The layout is undocumented, so columns are probed before reading.
///
/// Mapping to memory records, as for Apple Mail: the thread (`Conversation_ConversationID`) titled
/// with the subject without reply prefixes; from me when Outlook marks the message outgoing; the
/// participants every other address on it; the cursor the message's record id, which only grows.
nonisolated struct OutlookHistoryReader: MemoryHistoryReading {
    let sourceID = "outlook"
    let profilesRoot: String

    init(profilesRoot: String = NSHomeDirectory()
        + "/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles") {
        self.profilesRoot = profilesRoot
    }

    /// The profile database to read: "Main Profile" when present (Outlook's default), else the
    /// first profile that has one.
    var databasePath: String? {
        let candidates = ["Main Profile"] + ((try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []).sorted()
        return candidates.lazy
            .map { "\(profilesRoot)/\($0)/Data/Outlook.sqlite" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    func readiness() -> MemorySourceReadiness {
        guard let path = databasePath else {
            // The container itself exists only when Outlook is installed; inside it, macOS hides
            // nothing from a listing, so a missing database really means no local mail.
            return FileManager.default.fileExists(atPath: profilesRoot) && !FileManager.default.isReadableFile(atPath: profilesRoot)
                ? .needsFullDiskAccess
                : .notFound("No local Outlook mail on this Mac.")
        }
        do {
            let database = try ReadOnlySQLiteDatabase(path: path)
            return try schemaMatches(database) ? .ready
                : .failed("This version of Outlook stores mail differently; memory cannot read it yet.")
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            return error.readiness
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["Record_RecordID", "Message_NormalizedSubject", "Message_SenderList", "Message_SenderAddressList",
             "Message_ToRecipientAddressList", "Message_CCRecipientAddressList", "Message_Preview",
             "Message_TimeReceived", "Message_TimeSent", "Message_IsOutgoingMessage", "Conversation_ConversationID"],
            in: "Mail"
        )
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        guard let path = databasePath else { throw ReadOnlySQLiteDatabase.DatabaseError.missing(profilesRoot) }
        let database = try ReadOnlySQLiteDatabase(path: path)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized Outlook database layout.")
        }
        let after = Int64(cursor ?? "") ?? 0
        let rows = try database.rows(
            """
            SELECT Record_RecordID AS id, Conversation_ConversationID AS thread,
                   COALESCE(Message_TimeReceived, Message_TimeSent) AS received,
                   Message_NormalizedSubject AS subject, Message_SenderList AS sender_name,
                   Message_SenderAddressList AS sender, Message_ToRecipientAddressList AS recipients_to,
                   Message_CCRecipientAddressList AS recipients_cc, Message_Preview AS preview,
                   Message_IsOutgoingMessage AS outgoing
            FROM Mail
            WHERE Record_RecordID > ? AND COALESCE(Message_TimeReceived, Message_TimeSent, 0) >= ?
            ORDER BY Record_RecordID LIMIT ?
            """,
            [.integer(after), .real(since?.timeIntervalSince1970 ?? 0), .integer(Int64(limit))]
        )
        guard !rows.isEmpty else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }

        let ownAddresses = try Self.ownAddresses(database)
        var records: [MemoryIngestRecord] = []
        for row in rows {
            guard let id = row["id"]?.int else { continue }
            let text = (row["preview"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let senderAddress = Self.addresses(row["sender"]?.string).first ?? ""
            let isFromMe = (row["outgoing"]?.int ?? 0) != 0 || ownAddresses.contains(senderAddress)
            let everyone = [senderAddress] + Self.addresses(row["recipients_to"]?.string) + Self.addresses(row["recipients_cc"]?.string)
            let subject = AppleMailHistoryReader.baseSubject(row["subject"]?.string ?? "")
            let senderName = (row["sender_name"]?.string ?? "").split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            records.append(MemoryIngestRecord(
                sourceMessageID: String(id),
                conversationID: row["thread"]?.int.map { "thread-\($0)" } ?? "message-\(id)",
                conversationTitle: subject,
                sender: senderName.isEmpty ? senderAddress : senderName,
                isFromMe: isFromMe,
                timestamp: Date(timeIntervalSince1970: row["received"]?.double ?? 0),
                text: text,
                participants: Set(everyone.filter { !$0.isEmpty && !ownAddresses.contains($0) }).sorted(),
                subject: subject
            ))
        }
        let last = rows.last?["id"]?.int
        return MemoryReadPage(records: records, nextCursor: last.map(String.init), hasMore: rows.count == limit)
    }

    /// The user's own addresses: senders of the messages Outlook marks as outgoing.
    static func ownAddresses(_ database: ReadOnlySQLiteDatabase) throws -> Set<String> {
        let rows = try database.rows(
            "SELECT DISTINCT Message_SenderAddressList AS sender FROM Mail WHERE Message_IsOutgoingMessage = 1"
        )
        return Set(rows.flatMap { addresses($0["sender"]?.string) })
    }

    /// Outlook stores address lists as "a@x.com; b@y.com".
    static func addresses(_ list: String?) -> [String] {
        (list ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
    }
}
