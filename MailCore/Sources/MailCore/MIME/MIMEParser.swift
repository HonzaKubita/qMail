import Foundation

public struct MIMEPart: Sendable {
    public var headers: MIMEHeaders
    public var mimeType: String
    public var parameters: [String: String]
    /// Transfer-encoded body of a leaf part.
    public var body: Data
    public var children: [MIMEPart]

    public var transferEncoding: String {
        headers["Content-Transfer-Encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? "7bit"
    }

    public var charset: String? { parameters["charset"] }

    public var disposition: (type: String, parameters: [String: String])? {
        guard let raw = headers["Content-Disposition"] else { return nil }
        let parsed = MIMEHeaders.parseParameterized(raw)
        return (parsed.value, parsed.parameters)
    }

    public var filename: String? {
        let raw = disposition?.parameters["filename"] ?? parameters["name"]
        guard let raw, !raw.isEmpty else { return nil }
        return EncodedWords.decode(raw)
    }

    public var contentID: String? {
        headers["Content-ID"].map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
    }

    public var isMultipart: Bool { mimeType.hasPrefix("multipart/") }

    public var isAttachment: Bool {
        let dispositionType = disposition?.type
        if dispositionType == "attachment" { return true }
        let isText = mimeType == "text/plain" || mimeType == "text/html"
        if isText { return filename != nil && dispositionType != "inline" }
        return !isMultipart
    }

    public func decodedData() -> Data {
        TransferEncoding.decode(body, encoding: transferEncoding)
    }

    public func decodedText() -> String {
        Charset.decode(decodedData(), charset: charset)
    }
}

public struct MailAttachment: Sendable, Identifiable, Hashable {
    public let id: Int
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let contentID: String?
    public let isInline: Bool

    public var size: Int { data.count }
}

public enum MIMEParser {
    public static func parse(_ data: Data) -> MIMEPart {
        parse(data, depth: 0)
    }

    /// Parses a body when the headers were fetched separately (e.g. `BODY[TEXT]` previews).
    public static func parseBody(_ body: Data, headers: MIMEHeaders) -> MIMEPart {
        makePart(headers: headers, body: body, depth: 0)
    }

    private static func parse(_ data: Data, depth: Int) -> MIMEPart {
        let (headerData, body) = MIMEHeaders.split(data)
        return makePart(headers: MIMEHeaders.parse(headerData), body: body, depth: depth)
    }

    private static func makePart(headers: MIMEHeaders, body: Data, depth: Int) -> MIMEPart {
        let contentType = MIMEHeaders.parseParameterized(headers["Content-Type"] ?? "text/plain")
        var mimeType = contentType.value.isEmpty ? "text/plain" : contentType.value
        if !mimeType.contains("/") { mimeType = "text/plain" }
        var part = MIMEPart(headers: headers, mimeType: mimeType, parameters: contentType.parameters, body: body, children: [])
        if mimeType.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"], !boundary.isEmpty, depth < 24 {
            part.children = splitMultipart(body, boundary: boundary).map { parse($0, depth: depth + 1) }
            part.body = Data()
        }
        return part
    }

    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = data.startIndex
        var partStart: Data.Index?

        while searchStart < data.endIndex, let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            let atLineStart = range.lowerBound == data.startIndex || data[range.lowerBound - 1] == 0x0A
            guard atLineStart else {
                searchStart = range.upperBound
                continue
            }
            if let start = partStart {
                var end = range.lowerBound
                if end > start, data[end - 1] == 0x0A { end -= 1 }
                if end > start, data[end - 1] == 0x0D { end -= 1 }
                parts.append(data.subdata(in: start..<end))
            }
            let after = range.upperBound
            if after + 1 < data.endIndex, data[after] == UInt8(ascii: "-"), data[after + 1] == UInt8(ascii: "-") {
                return parts
            }
            guard let lineEnd = data[after..<data.endIndex].firstIndex(of: 0x0A) else {
                partStart = nil
                break
            }
            partStart = lineEnd + 1
            searchStart = lineEnd + 1
        }
        // Truncated input (partial fetches): keep what we have of the last part.
        if let start = partStart, start < data.endIndex {
            parts.append(data.subdata(in: start..<data.endIndex))
        }
        return parts
    }
}

/// A fully parsed message with the displayable bodies and attachments pulled out.
public struct ParsedMessage: Sendable {
    public let headers: MIMEHeaders
    public let root: MIMEPart
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [MailAttachment]

    public init(data: Data) {
        self.init(root: MIMEParser.parse(data))
    }

    public init(root: MIMEPart) {
        var collector = BodyCollector()
        collector.walk(root)
        self.headers = root.headers
        self.root = root
        self.textBody = collector.texts.isEmpty ? nil : collector.texts.joined(separator: "\n\n")
        self.htmlBody = collector.htmls.isEmpty ? nil : collector.htmls.joined(separator: "<br>")
        self.attachments = collector.attachments
    }

    public var subject: String { headers.decoded("Subject")?.trimmingCharacters(in: .whitespaces) ?? "" }
    public var from: [MailAddress] { MailAddress.parseList(headers["From"] ?? "") }
    public var to: [MailAddress] { MailAddress.parseList(headers["To"] ?? "") }
    public var cc: [MailAddress] { MailAddress.parseList(headers["Cc"] ?? "") }
    public var replyTo: [MailAddress] { MailAddress.parseList(headers["Reply-To"] ?? "") }
    public var date: Date? { headers["Date"].flatMap(MailDate.parseRFC5322) }
    public var messageID: String? { MailAddress.messageIDs(in: headers["Message-ID"]).first }
    public var references: [String] { MailAddress.messageIDs(in: headers["References"]) }

    /// Plain text for display: the text part, or the HTML part flattened.
    public var plainText: String {
        if let textBody, !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return textBody }
        if let htmlBody { return HTMLText.plainText(htmlBody) }
        return ""
    }

    public var visibleAttachments: [MailAttachment] {
        attachments.filter { !$0.isInline || $0.contentID == nil || !(htmlBody?.contains("cid:\($0.contentID!)") ?? false) }
    }
}

private struct BodyCollector {
    var texts: [String] = []
    var htmls: [String] = []
    var attachments: [MailAttachment] = []

    mutating func walk(_ part: MIMEPart) {
        if part.isMultipart {
            if part.mimeType == "multipart/alternative" {
                walkAlternative(part)
            } else {
                part.children.forEach { walk($0) }
            }
            return
        }
        if part.isAttachment {
            addAttachment(part)
            return
        }
        switch part.mimeType {
        case "text/html": htmls.append(part.decodedText())
        default: texts.append(part.decodedText())
        }
    }

    private mutating func walkAlternative(_ part: MIMEPart) {
        var text: MIMEPart?
        var html: MIMEPart?
        var richer: MIMEPart?
        for child in part.children {
            if child.isMultipart {
                richer = child
            } else if child.mimeType == "text/plain", !child.isAttachment {
                text = child
            } else if child.mimeType == "text/html", !child.isAttachment {
                html = child
            }
        }
        if let text { texts.append(text.decodedText()) }
        if let richer {
            // Typically multipart/related wrapping the HTML and its inline images.
            let before = texts.count
            walk(richer)
            if text != nil, texts.count > before { texts.removeLast(texts.count - before) }
        } else if let html {
            htmls.append(html.decodedText())
        }
    }

    private mutating func addAttachment(_ part: MIMEPart) {
        let isInline = part.disposition?.type == "inline" || (part.disposition == nil && part.contentID != nil)
        let fallbackName: String
        switch part.mimeType {
        case "message/rfc822": fallbackName = "Message.eml"
        case let type where type.hasPrefix("image/"): fallbackName = "Image.\(type.split(separator: "/").last ?? "img")"
        case "text/calendar": fallbackName = "Invite.ics"
        default: fallbackName = "Attachment"
        }
        attachments.append(MailAttachment(
            id: attachments.count,
            filename: part.filename ?? fallbackName,
            mimeType: part.mimeType,
            data: part.decodedData(),
            contentID: part.contentID,
            isInline: isInline
        ))
    }
}
