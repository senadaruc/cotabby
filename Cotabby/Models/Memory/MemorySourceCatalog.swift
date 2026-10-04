import Foundation

/// File overview:
/// The sources conversation memory can read, described once: what each is, which apps it serves,
/// what it needs, and whether answers may use it by default.
///
/// Why a catalog: the pane lists sources, suggestions map the focused app to sources, and the answer
/// feature needs each source's default. One table keeps those three agreeing. Reading a source is a
/// separate concern (the readers in `Services/Memory/Readers`).

nonisolated struct MemorySourceDescriptor: Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let appBundleIds: [String]
    let requirements: [MemorySource.Requirement]
    let optionsSchema: [String: String]
    /// Whether facts from this source may answer questions unless the user decides otherwise. Work
    /// sources yes; personal chats no, since an answer can put them in front of other people.
    let answerSourceByDefault: Bool
}

nonisolated enum MemorySourceCatalog {
    private static let calendarAccess = MemorySource.Requirement(
        kind: "calendar", title: "Calendar access",
        detail: "Cotabby needs access to your calendars to remember events and check your availability."
    )

    private static let fullDiskAccess = MemorySource.Requirement(
        kind: "full_disk_access", title: "Full Disk Access",
        detail: "Cotabby needs Full Disk Access to read this app's local history."
    )

    static let all: [MemorySourceDescriptor] = [
        MemorySourceDescriptor(
            id: "whatsapp", title: "WhatsApp",
            description: "Chats from WhatsApp for Mac, read from its local database.",
            appBundleIds: ["net.whatsapp.WhatsApp"], requirements: [fullDiskAccess], optionsSchema: [:],
            answerSourceByDefault: false
        ),
        MemorySourceDescriptor(
            id: "apple_mail", title: "Apple Mail",
            description: "Mail from all accounts in the Mail app, read from its local store.",
            appBundleIds: ["com.apple.mail"], requirements: [fullDiskAccess], optionsSchema: [:],
            answerSourceByDefault: true
        ),
        MemorySourceDescriptor(
            id: "outlook", title: "Outlook",
            description: "Mail from Outlook for Mac, read from its local files: New Outlook's store and the classic " +
                "database. Mail Outlook keeps only online is not included.",
            appBundleIds: ["com.microsoft.Outlook"], requirements: [fullDiskAccess], optionsSchema: [:],
            answerSourceByDefault: true
        ),
        MemorySourceDescriptor(
            id: "teams", title: "Microsoft Teams",
            description: "Chats, meeting chats and channels the Teams app has cached on this Mac (usually the recent " +
                "months; older history stays in Microsoft 365).",
            appBundleIds: ["com.microsoft.teams2", "com.microsoft.teams"], requirements: [fullDiskAccess], optionsSchema: [:],
            answerSourceByDefault: true
        ),
        MemorySourceDescriptor(
            id: "calendar", title: "Calendar",
            description: "Events from every calendar in the Calendar app, including work accounts added there: what, " +
                "when, where and with whom, from the past year to three months ahead. When someone asks when you " +
                "are free, answers check these calendars for busy and free times only.",
            appBundleIds: ["com.apple.iCal"], requirements: [calendarAccess], optionsSchema: [:],
            // Off: "all calendars" includes personal ones. Free/busy answers do not depend on this.
            answerSourceByDefault: false
        ),
        MemorySourceDescriptor(
            id: "documents", title: "Documents Folder",
            description: "Plain-text and Markdown files in a folder you choose: reference notes answers can draw on.",
            appBundleIds: [], requirements: [MemorySource.Requirement(kind: "folder", title: "Folder",
                                                                       detail: "The folder whose .txt and .md files are remembered.")],
            optionsSchema: ["folder": "Folder"],
            answerSourceByDefault: true
        ),
    ]

    static func descriptor(_ id: String) -> MemorySourceDescriptor? {
        all.first { $0.id == id }
    }

    /// Whether `id` may answer questions under `settings` (the user's choice, else the default).
    static func isAnswerSource(_ id: String, settings: MemorySourceSettings?) -> Bool {
        settings?.answerSource ?? descriptor(id)?.answerSourceByDefault ?? false
    }
}
