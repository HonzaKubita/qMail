import Foundation

public enum MailProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case gmail, outlook, icloud, yahoo, fastmail, aol, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .icloud: "iCloud"
        case .yahoo: "Yahoo"
        case .fastmail: "Fastmail"
        case .aol: "AOL"
        case .other: "Other"
        }
    }

    public var subtitle: String {
        switch self {
        case .gmail: "Google Workspace & Gmail"
        case .outlook: "Outlook.com, Hotmail, Microsoft 365"
        case .icloud: "iCloud, me.com, mac.com"
        case .yahoo: "Yahoo Mail"
        case .fastmail: "Fastmail"
        case .aol: "AOL Mail"
        case .other: "Any IMAP & SMTP account"
        }
    }

    public var imap: ServerEndpoint? {
        switch self {
        case .gmail: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls)
        case .outlook: ServerEndpoint(host: "outlook.office365.com", port: 993, security: .tls)
        case .icloud: ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .tls)
        case .yahoo: ServerEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls)
        case .fastmail: ServerEndpoint(host: "imap.fastmail.com", port: 993, security: .tls)
        case .aol: ServerEndpoint(host: "imap.aol.com", port: 993, security: .tls)
        case .other: nil
        }
    }

    public var smtp: ServerEndpoint? {
        switch self {
        case .gmail: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls)
        case .outlook: ServerEndpoint(host: "smtp.office365.com", port: 587, security: .startTLS)
        case .icloud: ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .yahoo: ServerEndpoint(host: "smtp.mail.yahoo.com", port: 465, security: .tls)
        case .fastmail: ServerEndpoint(host: "smtp.fastmail.com", port: 465, security: .tls)
        case .aol: ServerEndpoint(host: "smtp.aol.com", port: 465, security: .tls)
        case .other: nil
        }
    }

    public var oauthProvider: OAuthProvider? {
        switch self {
        case .gmail: .google
        case .outlook: .microsoft
        default: nil
        }
    }

    /// Whether the provider files messages sent over SMTP into Sent by itself.
    public var savesSentMessages: Bool {
        switch self {
        case .gmail, .outlook: true
        default: false
        }
    }

    public var appPasswordURL: URL? {
        switch self {
        case .gmail: URL(string: "https://myaccount.google.com/apppasswords")
        case .outlook: URL(string: "https://account.live.com/proofs/AppPassword")
        case .icloud: URL(string: "https://account.apple.com/account/manage/section/security")
        case .yahoo: URL(string: "https://login.yahoo.com/myaccount/security/app-password")
        case .fastmail: URL(string: "https://app.fastmail.com/settings/security/apps")
        case .aol: URL(string: "https://login.aol.com/myaccount/security/app-password")
        case .other: nil
        }
    }

    public var passwordHelp: String {
        switch self {
        case .gmail: "Use an app password (requires 2-Step Verification), or sign in with Google."
        case .outlook: "Signing in with Microsoft is recommended. App passwords only work if your account still allows them."
        case .icloud: "iCloud requires an app-specific password. Create one under Sign-In and Security at account.apple.com."
        case .yahoo, .aol: "Generate an app password in your account security settings."
        case .fastmail: "Create an app password with IMAP and SMTP access in Fastmail settings."
        case .other: "Use your mail password or an app password if your provider requires one."
        }
    }

    public static func guess(for email: String) -> MailProvider {
        let domain = email.split(separator: "@").last?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return .gmail
        case "icloud.com", "me.com", "mac.com": return .icloud
        case "fastmail.com", "fastmail.fm": return .fastmail
        case "aol.com": return .aol
        default: break
        }
        if ["outlook.", "hotmail.", "live.", "msn."].contains(where: { domain.hasPrefix($0) }) { return .outlook }
        if domain.hasPrefix("yahoo.") || domain.hasPrefix("ymail.") { return .yahoo }
        return .other
    }
}

public enum AuthKind: String, Codable, Sendable {
    case password
    case oauth
}

public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var email: String
    public var provider: MailProvider
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    public var username: String
    public var authKind: AuthKind
    /// Additional addresses that belong to this account (aliases).
    public var aliases: [String]
    public var saveSentCopy: Bool
    public var colorIndex: Int

    public init(
        id: UUID = UUID(), displayName: String, email: String, provider: MailProvider, imap: ServerEndpoint,
        smtp: ServerEndpoint, username: String, authKind: AuthKind, aliases: [String] = [], saveSentCopy: Bool,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.provider = provider
        self.imap = imap
        self.smtp = smtp
        self.username = username
        self.authKind = authKind
        self.aliases = aliases
        self.saveSentCopy = saveSentCopy
        self.colorIndex = colorIndex
    }

    public var address: MailAddress { MailAddress(name: displayName, email: email) }

    public var ownAddresses: Set<String> {
        Set(([email] + aliases).map { $0.lowercased() })
    }
}

public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, archive, all, flagged, junk, trash, custom

    /// Sidebar ordering.
    public var sortOrder: Int {
        switch self {
        case .inbox: 0
        case .flagged: 1
        case .drafts: 2
        case .sent: 3
        case .archive: 4
        case .all: 5
        case .junk: 6
        case .trash: 7
        case .custom: 8
        }
    }

    public static func detect(attributes: Set<String>, path: String, displayName: String) -> MailboxRole {
        if path.uppercased() == "INBOX" { return .inbox }
        let map: [String: MailboxRole] = [
            "\\sent": .sent, "\\drafts": .drafts, "\\archive": .archive, "\\all": .all,
            "\\flagged": .flagged, "\\junk": .junk, "\\trash": .trash,
        ]
        for (attribute, role) in map where attributes.contains(attribute) { return role }
        switch displayName.lowercased() {
        case "sent", "sent items", "sent messages", "sent mail", "odeslaná pošta", "odeslané", "gesendet", "envoyés": return .sent
        case "drafts", "draft", "koncepty", "entwürfe", "brouillons": return .drafts
        case "archive", "archives", "archiv", "all mail": return .archive
        case "junk", "spam", "junk e-mail", "junk email", "bulk mail", "nevyžádaná pošta": return .junk
        case "trash", "deleted items", "deleted messages", "bin", "koš", "papierkorb", "corbeille": return .trash
        default: return .custom
        }
    }
}

public struct Mailbox: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: UUID
    public var path: String
    public var name: String
    public var delimiter: String?
    public var role: MailboxRole
    public var depth: Int

    public init(accountID: UUID, path: String, name: String, delimiter: String?, role: MailboxRole, depth: Int) {
        self.id = Self.makeID(accountID: accountID, path: path)
        self.accountID = accountID
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.role = role
        self.depth = depth
    }

    public static func makeID(accountID: UUID, path: String) -> String {
        "\(accountID.uuidString)|\(path)"
    }

    public var systemImage: String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive, .all: "archivebox"
        case .flagged: "flag"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .custom: "folder"
        }
    }

    public var displayName: String {
        switch role {
        case .inbox: "Inbox"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .junk: "Junk"
        case .trash: "Trash"
        case .archive: name.lowercased() == "archive" ? "Archive" : name
        case .all: "All Mail"
        default: name
        }
    }

    /// Builds the sidebar list from a server LIST response.
    public static func makeList(from mailboxes: [IMAPMailbox], accountID: UUID, provider: MailProvider) -> [Mailbox] {
        struct Entry {
            var mailbox: Mailbox
            var flaggedByServer: Bool
            var nestedName: String
            var nestedDepth: Int
        }
        var result: [Entry] = []
        let selectablePaths = Set(mailboxes.filter(\.isSelectable).map(\.path))
        for mailbox in mailboxes where mailbox.isSelectable {
            var decoded = mailbox.decodedPath
            // Gmail nests system folders under "[Gmail]" (or "[Google Mail]"); flatten that level.
            if provider == .gmail, let delimiter = mailbox.delimiter, decoded.hasPrefix("["),
               let range = decoded.range(of: "]\(delimiter)") {
                decoded = String(decoded[range.upperBound...])
            }
            let components = mailbox.delimiter.map { decoded.components(separatedBy: $0) } ?? [decoded]
            let leaf = components.last ?? decoded
            let role = MailboxRole.detect(attributes: mailbox.attributes, path: mailbox.path, displayName: leaf)

            // Indent under parents that are listed; fold unlisted parents into the name ("Projects / Koš").
            var depth = 0
            var nameStart = 0
            if let delimiter = mailbox.delimiter, components.count > 1 {
                let rawComponents = mailbox.path.components(separatedBy: delimiter)
                let skipped = rawComponents.count - components.count
                for level in (skipped + 1)..<rawComponents.count {
                    if selectablePaths.contains(rawComponents[0..<level].joined(separator: delimiter)) {
                        depth += 1
                        nameStart = level - skipped
                    }
                }
            }
            let nestedName = components[min(nameStart, components.count - 1)...].joined(separator: " / ")
            let flagged = mailbox.path.uppercased() == "INBOX" || mailbox.attributes.contains {
                !["\\haschildren", "\\hasnochildren", "\\marked", "\\unmarked"].contains($0)
            }
            let entry = Mailbox(accountID: accountID, path: mailbox.path, name: leaf, delimiter: mailbox.delimiter, role: role, depth: 0)
            result.append(Entry(mailbox: entry, flaggedByServer: flagged, nestedName: nestedName, nestedDepth: depth))
        }
        // One mailbox per special role, preferring the one the server flagged; demote the rest to plain folders.
        var claimed = Set<MailboxRole>()
        for pass in [true, false] {
            for index in result.indices where result[index].flaggedByServer == pass && result[index].mailbox.role != .custom {
                if !claimed.insert(result[index].mailbox.role).inserted { result[index].mailbox.role = .custom }
            }
        }
        for index in result.indices where result[index].mailbox.role == .custom {
            result[index].mailbox.name = result[index].nestedName
            result[index].mailbox.depth = result[index].nestedDepth
        }
        return result.map(\.mailbox).sorted {
            if $0.role.sortOrder != $1.role.sortOrder { return $0.role.sortOrder < $1.role.sortOrder }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
