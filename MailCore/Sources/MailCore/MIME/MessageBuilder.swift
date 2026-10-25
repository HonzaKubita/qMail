import Foundation

public struct OutgoingAttachment: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMessage: Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]

    public init(
        from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [], subject: String,
        body: String, inReplyTo: String? = nil, references: [String] = [], attachments: [OutgoingAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }

    public var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.email).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Renders the message as RFC 5322 bytes. Bcc is intentionally left out of the headers.
    public func render(date: Date = Date()) -> (data: Data, messageID: String) {
        let domain = from.domain.isEmpty ? "qmail.local" : from.domain
        let messageID = "\(UUID().uuidString.lowercased())@\(domain)"

        var headers: [(String, String)] = [
            ("Date", MailDate.formatRFC5322(date)),
            ("From", from.headerValue),
        ]
        if !to.isEmpty { headers.append(("To", to.headerValue)) }
        if !cc.isEmpty { headers.append(("Cc", cc.headerValue)) }
        headers.append(("Subject", EncodedWords.encodeIfNeeded(subject)))
        headers.append(("Message-ID", "<\(messageID)>"))
        if let inReplyTo { headers.append(("In-Reply-To", "<\(inReplyTo)>")) }
        if !references.isEmpty {
            headers.append(("References", references.map { "<\($0)>" }.joined(separator: "\r\n ")))
        }
        headers.append(("MIME-Version", "1.0"))
        headers.append(("X-Mailer", "qMail"))

        var output = ""
        let textPart = TransferEncoding.encodeQuotedPrintable(body)
        if attachments.isEmpty {
            headers.append(("Content-Type", "text/plain; charset=utf-8"))
            headers.append(("Content-Transfer-Encoding", "quoted-printable"))
            output = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n" + textPart + "\r\n"
        } else {
            let boundary = "qMail-\(UUID().uuidString)"
            headers.append(("Content-Type", "multipart/mixed; boundary=\"\(boundary)\""))
            output = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n"
            output += "This is a multi-part message in MIME format.\r\n"
            output += "--\(boundary)\r\n"
            output += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            output += textPart + "\r\n"
            for attachment in attachments {
                output += "--\(boundary)\r\n"
                output += "Content-Type: \(attachment.mimeType); name=\(Self.encodedParameterValue(attachment.filename))\r\n"
                output += "Content-Disposition: attachment; \(Self.filenameParameter(attachment.filename))\r\n"
                output += "Content-Transfer-Encoding: base64\r\n\r\n"
                output += TransferEncoding.encodeBase64Lines(attachment.data) + "\r\n"
            }
            output += "--\(boundary)--\r\n"
        }
        return (Data(output.utf8), messageID)
    }

    private static func isPlainASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
    }

    private static func encodedParameterValue(_ value: String) -> String {
        isPlainASCII(value) ? "\"\(value)\"" : "\"\(EncodedWords.encodeIfNeeded(value).replacingOccurrences(of: "\r\n ", with: ""))\""
    }

    /// `filename="…"` for ASCII names, RFC 2231 `filename*=UTF-8''…` otherwise.
    private static func filenameParameter(_ value: String) -> String {
        if isPlainASCII(value) { return "filename=\"\(value)\"" }
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "filename*=UTF-8''\(encoded)"
    }
}

/// Helpers for building replies and forwards.
public enum ReplyBuilder {
    public static func replySubject(_ subject: String) -> String {
        let normalized = MessageSummary.normalizeSubject(subject)
        return "Re: " + (normalized.isEmpty ? subject : normalized)
    }

    public static func forwardSubject(_ subject: String) -> String {
        let normalized = MessageSummary.normalizeSubject(subject)
        return "Fwd: " + (normalized.isEmpty ? subject : normalized)
    }

    public static func references(for message: ParsedMessage) -> [String] {
        var refs = message.references
        if refs.isEmpty, let inReplyTo = MailAddress.messageIDs(in: message.headers["In-Reply-To"]).first {
            refs.append(inReplyTo)
        }
        if let id = message.messageID { refs.append(id) }
        return Array(refs.suffix(20))
    }

    public static func quoted(_ message: ParsedMessage, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let date = message.date.map { formatter.string(from: $0) } ?? ""
        let sender = message.from.first?.displayName ?? "Unknown"
        let body = message.plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        return "\n\nOn \(date), \(sender) wrote:\n\(body)"
    }

    public static func forwarded(_ message: ParsedMessage) -> String {
        var lines = ["", "", "---------- Forwarded message ----------"]
        if let from = message.from.first { lines.append("From: \(from.displayName) <\(from.email)>") }
        if let date = message.date { lines.append("Date: \(MailDate.formatRFC5322(date))") }
        lines.append("Subject: \(message.subject)")
        if !message.to.isEmpty { lines.append("To: \(message.to.map(\.displayName).joined(separator: ", "))") }
        lines.append("")
        lines.append(message.plainText)
        return lines.joined(separator: "\n")
    }
}
