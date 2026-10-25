import Foundation

/// Lightweight, cacheable description of a message used by lists and chats.
public struct MessageSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: UUID
    public var mailboxPath: String
    public var uid: UInt32
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var subject: String
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var date: Date
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var snippet: String
    public var hasAttachments: Bool
    /// Newsletters, notifications, mailing lists and auto-replies.
    public var isAutomated: Bool
    public var gmailThreadID: String?
    public var size: Int

    public static func makeID(accountID: UUID, mailboxPath: String, uid: UInt32) -> String {
        "\(accountID.uuidString)|\(mailboxPath)|\(uid)"
    }

    public var sender: MailAddress? { from.first }

    public var displaySubject: String {
        subject.isEmpty ? "(No Subject)" : subject
    }

    /// Subject with any number of "Re:"/"Fwd:"/"AW:"/"Odp:" prefixes removed, for grouping and display.
    public var normalizedSubject: String { Self.normalizeSubject(subject) }

    public static func normalizeSubject(_ subject: String) -> String {
        var value = subject.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re", "fw", "fwd", "aw", "wg", "sv", "vs", "odp", "tr", "rif", "antw", "r", "res", "enc", "fwd", "pd"]
        var changed = true
        while changed {
            changed = false
            if value.hasPrefix("["), let close = value.firstIndex(of: "]"), value.distance(from: value.startIndex, to: close) < 30,
               value[value.index(after: close)...].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("re") {
                value = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
                changed = true
            }
            guard let colon = value.firstIndex(where: { $0 == ":" || $0 == "：" }) else { break }
            var prefix = value[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            // "Re[2]" / "Re(2)"
            if let bracket = prefix.firstIndex(where: { $0 == "[" || $0 == "(" }) { prefix = String(prefix[..<bracket]) }
            if prefixes.contains(prefix) {
                value = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return value
    }

    public init(
        id: String, accountID: UUID, mailboxPath: String, uid: UInt32, messageID: String?, inReplyTo: String?,
        references: [String], subject: String, from: [MailAddress], to: [MailAddress], cc: [MailAddress],
        replyTo: [MailAddress] = [], date: Date, isSeen: Bool, isFlagged: Bool, isAnswered: Bool = false, snippet: String,
        hasAttachments: Bool, isAutomated: Bool, gmailThreadID: String? = nil, size: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uid = uid
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.date = date
        self.isSeen = isSeen
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.snippet = snippet
        self.hasAttachments = hasAttachments
        self.isAutomated = isAutomated
        self.gmailThreadID = gmailThreadID
        self.size = size
    }

    public init(fetched: FetchedMessage, accountID: UUID, mailboxPath: String) {
        let headers = MIMEHeaders.parse(fetched.headerData ?? Data())
        let flags = Set(fetched.flags.map { $0.lowercased() })
        let from = MailAddress.parseList(headers["From"] ?? "")

        var snippet = ""
        if let preview = fetched.previewData, !preview.isEmpty {
            let part = MIMEParser.parseBody(preview, headers: headers)
            snippet = Self.makeSnippet(ParsedMessage(root: part))
        }

        let contentType = MIMEHeaders.parseParameterized(headers["Content-Type"] ?? "text/plain").value
        self.init(
            id: Self.makeID(accountID: accountID, mailboxPath: mailboxPath, uid: fetched.uid),
            accountID: accountID,
            mailboxPath: mailboxPath,
            uid: fetched.uid,
            messageID: MailAddress.messageIDs(in: headers["Message-ID"]).first,
            inReplyTo: MailAddress.messageIDs(in: headers["In-Reply-To"]).first,
            references: MailAddress.messageIDs(in: headers["References"]),
            subject: headers.decoded("Subject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            from: from,
            to: MailAddress.parseList(headers["To"] ?? ""),
            cc: MailAddress.parseList(headers["Cc"] ?? ""),
            replyTo: MailAddress.parseList(headers["Reply-To"] ?? ""),
            date: headers["Date"].flatMap(MailDate.parseRFC5322) ?? fetched.internalDate ?? Date(),
            isSeen: flags.contains("\\seen"),
            isFlagged: flags.contains("\\flagged"),
            isAnswered: flags.contains("\\answered"),
            snippet: snippet,
            hasAttachments: contentType == "multipart/mixed",
            isAutomated: Self.looksAutomated(headers: headers, from: from.first),
            gmailThreadID: fetched.gmailThreadID,
            size: fetched.size ?? 0
        )
    }

    public mutating func apply(flags: [String]) {
        let lowered = Set(flags.map { $0.lowercased() })
        isSeen = lowered.contains("\\seen")
        isFlagged = lowered.contains("\\flagged")
        isAnswered = lowered.contains("\\answered")
    }

    static func makeSnippet(_ message: ParsedMessage) -> String {
        let text: String
        if let plain = message.textBody, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = plain
        } else if let html = message.htmlBody {
            text = HTMLText.plainText(html)
        } else {
            text = ""
        }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
        let collapsed = lines.joined(separator: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{034F}", with: "")
        return String(collapsed.prefix(240))
    }

    private static let automatedLocalParts = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "notifications", "notification",
        "mailer-daemon", "postmaster", "newsletter", "news", "bounce", "alerts", "alert", "info", "updates", "marketing",
        "support", "hello", "team", "billing", "receipts", "account", "accounts", "security", "digest",
    ]

    static func looksAutomated(headers: MIMEHeaders, from: MailAddress?) -> Bool {
        if headers["List-Id"] != nil || headers["List-Unsubscribe"] != nil { return true }
        if let precedence = headers["Precedence"]?.lowercased(), ["bulk", "list", "junk", "auto_reply"].contains(precedence) {
            return true
        }
        if let autoSubmitted = headers["Auto-Submitted"]?.lowercased(), autoSubmitted != "no" { return true }
        if headers["X-Autoreply"] != nil { return true }
        if let local = from?.email.split(separator: "@").first?.lowercased() {
            if automatedLocalParts.contains(local) { return true }
            if local.contains("noreply") || local.contains("no-reply") || local.contains("donotreply") { return true }
        }
        return false
    }
}

/// Raw data for one message returned by an IMAP FETCH.
public struct FetchedMessage: Sendable {
    public var uid: UInt32
    public var sequence: Int
    public var flags: [String] = []
    public var internalDate: Date?
    public var size: Int?
    public var headerData: Data?
    public var previewData: Data?
    public var rawData: Data?
    public var gmailThreadID: String?

    public init(uid: UInt32, sequence: Int) {
        self.uid = uid
        self.sequence = sequence
    }
}
