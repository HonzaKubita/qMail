import Foundation

/// Reduces an email body to just what the sender wrote, so a thread reads like a chat:
/// drops quoted replies, reply headers ("On … wrote:"), signatures and mobile footers.
public enum QuoteStripper {
    /// Markers where the quoted part of an HTML reply begins (Gmail, Outlook, Apple Mail, Thunderbird, Yahoo).
    private static let htmlQuoteMarkers = [
        "<div class=\"gmail_quote", "<div class=\"gmail_extra", "<blockquote", "<div id=\"appendonsend",
        "<div id=\"divRplyFwdMsg", "<hr id=\"stopSpelling", "<div class=\"moz-cite-prefix",
        "<div name=\"messageReplySection", "<div class=\"yahoo_quoted", "<div id=\"mail-editor-reference-message-container",
        "<div class=\"OutlookMessageHeader", "<div style=\"border:none;border-top:solid #E1E1E1",
        "<div style=\"border:none; border-top:solid #E1E1E1",
    ]

    private static let replyHeaderPatterns: [String] = [
        #"^on\b.{0,200}\bwrote:?$"#,                          // English
        #"^dne\b.{0,200}\bnapsal(a|\(a\))?:?$"#,              // Czech
        #"^.{0,250}\bodesílatel\b.{0,250}\bnapsal(a|\(a\))?:?$"#, // Czech Gmail: "st 21. 10. 2026 v 3:53 odesílatel … napsal:"
        #"^(am|on)\b.{0,200}\bschrieb.{0,60}:$"#,             // German
        #"^le\b.{0,200}\ba écrit ?:$"#,                       // French
        #"^el\b.{0,200}\bescribió:$"#,                        // Spanish
        #"^il\b.{0,200}\bha scritto:$"#,                      // Italian
        #"^op\b.{0,200}\bschreef.{0,60}:$"#,                  // Dutch
        #"^w dniu\b.{0,200}\bnapisał.{0,10}:$"#,              // Polish
        #"^(den|d\.)\b.{0,200}\bskrev.{0,60}:$"#,             // Scandinavian
        #"^em\b.{0,200}\bescreveu:$"#,                        // Portuguese
        #"^.{0,200}\bwrote:$"#,
        #"^-{2,}\s*(original message|původní zpráva|původní e-mail|ursprüngliche nachricht|message d'origine|mensaje original)\s*-{2,}$"#,
        #"^_{20,}$"#,
    ]

    private static let footerPatterns: [String] = [
        #"^sent from my (iphone|ipad|android|mobile|galaxy|phone).*$"#,
        #"^odesláno z (iphonu|ipadu|mobilu|mého iphonu).*$"#,
        #"^get outlook for (ios|android).*$"#,
        #"^stáhněte si outlook pro .*$"#,
        #"^sent from (outlook|mail) for .*$"#,
        #"^gesendet von meinem .*$"#,
        #"^envoyé de mon .*$"#,
    ]

    /// Text stand-ins mail apps write for images: "[image: logo.png]", "[cid:image001.png@01D…]",
    /// Outlook's generated descriptions ("[Obsah obrázku …]", "[A picture containing …]").
    private static let imagePlaceholder = try! NSRegularExpression(
        pattern: #"^\[(image|obrázek|cid|obsah obrázku|a picture containing|picture|logo|description automatically generated|popis byl vygenerován)\b[^\]]*\]$"#,
        options: [.caseInsensitive]
    )

    /// A short line of underscores, as in "______________\nJan Novák" signatures.
    private static let underscoreSignature = try! NSRegularExpression(pattern: #"^_{8,}\s*$"#)

    private static let replyRegexes = replyHeaderPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }
    private static let footerRegexes = footerPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// Best chat text for a parsed message: plain text if present, otherwise HTML with quotes cut.
    public static func chatText(for message: ParsedMessage) -> String {
        let raw: String
        if let text = message.textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = text
        } else if let html = message.htmlBody {
            raw = HTMLText.plainText(cutHTMLQuote(html))
        } else {
            raw = ""
        }
        return collapseRepeatedLinks(strip(raw))
    }

    private static let labelledLink = try! NSRegularExpression(pattern: #"(\S+?) ?<((?:https?|mailto):[^>\s]+)>"#, options: [.caseInsensitive])

    /// Outlook and Gmail plain text write links as `www.ssps.cz<http://www.ssps.cz/>` or
    /// `a@b.cz <mailto:a@b.cz>`. When the visible text already is the address, drop the repeat.
    public static func collapseRepeatedLinks(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for match in labelledLink.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let labelRange = Range(match.range(at: 1), in: text), let urlRange = Range(match.range(at: 2), in: text) else { continue }
            let label = text[labelRange].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = text[urlRange].lowercased()
            guard label.count >= 4, label.contains("."), url.contains(label) else { continue }
            result.replaceCharacters(in: match.range, with: String(text[labelRange]))
        }
        return result as String
    }

    private static let inlineReplyRegexes: [NSRegularExpression] = [
        #"\bOn [^\n]{5,160}? wrote:"#,
        #"\bDne [^\n]{5,160}? napsal(a|\(a\))?:"#,
        #"(\b(po|út|st|čt|pá|so|ne)\.?\s+)?\d{1,2}\.\s*\d{1,2}\.\s*\d{2,4}\s+v\s+\d{1,2}:\d{2}[^\n]{0,20}?\s+odesílatel\b"#,
        #"\bodesílatel [^\n]{3,200}? napsal(a|\(a\))?:"#,
        #"\bAm [^\n]{5,160}? schrieb[^:]{0,40}:"#,
        #"\bLe [^\n]{5,160}? a écrit ?:"#,
        #"\bEl [^\n]{5,160}? escribió:"#,
        #"-{2,} ?(Original Message|Původní zpráva) ?-{2,}"#,
        #"_{10,}"#,
        #"\bFrom: [^\n]{3,160}? (Sent|Date): "#,
        #"\bOd: [^\n]{3,160}? (Odesláno|Datum): "#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Cuts a one-line preview where the quoted reply begins.
    public static func cleanSnippet(_ snippet: String) -> String {
        let range = NSRange(snippet.startIndex..., in: snippet)
        var cut = snippet.endIndex
        for regex in inlineReplyRegexes {
            if let match = regex.firstMatch(in: snippet, range: range), let found = Range(match.range, in: snippet),
               found.lowerBound < cut {
                cut = found.lowerBound
            }
        }
        // Empty when the reply has no text of its own (just a photo, say): better than showing the quote header.
        return snippet[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cutHTMLQuote(_ html: String) -> String {
        var cut = html.endIndex
        for marker in htmlQuoteMarkers {
            if let range = html.range(of: marker, options: .caseInsensitive), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        return String(html[..<cut])
    }

    public static func strip(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "") // placeholders where attachments were
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var cutAtReplyHeader = false
        var index = 0

        lineLoop: while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Signature delimiters: "-- " and short underscore rules.
            if line == "-- " || trimmed == "--" { break }
            if index > 0, matchesAny(trimmed, [underscoreSignature]) { break }

            if isReplyHeader(at: index, in: lines) {
                cutAtReplyHeader = true
                break
            }

            // Outlook style header block: "From: …" followed closely by "Sent:"/"Date:"/"To:"/"Subject:".
            if isHeaderLine(trimmed, keys: ["from:", "od:", "von:", "de:"]) {
                let window = lines[(index + 1)..<min(lines.count, index + 5)]
                if window.contains(where: { isHeaderLine($0.trimmingCharacters(in: .whitespaces), keys: ["sent:", "date:", "to:", "subject:", "odesláno:", "komu:", "předmět:", "datum:", "gesendet:", "an:", "betreff:", "envoyé:", "objet:"]) }) {
                    cutAtReplyHeader = true
                    break lineLoop
                }
            }

            if trimmed.hasPrefix(">") || matchesAny(trimmed, [imagePlaceholder]) {
                index += 1
                continue
            }
            kept.append(line)
            index += 1
        }

        // Drop trailing mobile footers and blank lines.
        while let last = kept.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || matchesAny(trimmed, footerRegexes) {
                kept.removeLast()
            } else {
                break
            }
        }

        let result = HTMLText.tidy(kept.joined(separator: "\n"))
        if result.isEmpty && !cutAtReplyHeader {
            // Everything was quoted (e.g. a forward from Apple Mail): show it without the ">" markers.
            return HTMLText.tidy(String(lines.map(unquote).joined(separator: "\n").prefix(4000)))
        }
        // A reply with nothing above the quote (say, just an attachment) has no text of its own.
        return result
    }

    /// A reply header such as "On … wrote:", possibly wrapped over up to three lines by the sender's mail app.
    private static func isReplyHeader(at index: Int, in lines: [String]) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(">") else { return false }
        if matchesAny(trimmed, replyRegexes) { return true }
        var joined = trimmed
        for next in lines.dropFirst(index + 1).prefix(2) {
            let piece = next.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty, !piece.hasPrefix(">") else { break }
            joined += (joined.hasSuffix("<") ? "" : " ") + piece
            // Wrapped headers always carry the sender's address, which keeps ordinary sentences from matching.
            if joined.contains("@"), matchesAny(joined, replyRegexes) { return true }
        }
        return false
    }

    private static func unquote(_ line: String) -> String {
        var value = Substring(line)
        while value.first == ">" || value.first == " " && value.dropFirst().first == ">" {
            value = value.drop { $0 == " " }.dropFirst()
            if value.first == " " { value = value.dropFirst() }
        }
        return String(value)
    }

    private static func isHeaderLine(_ line: String, keys: [String]) -> Bool {
        let lower = line.lowercased().replacingOccurrences(of: "*", with: "")
        return keys.contains { lower.hasPrefix($0) }
    }

    private static func matchesAny(_ line: String, _ regexes: [NSRegularExpression]) -> Bool {
        guard !line.isEmpty, line.count < 400 else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regexes.contains { $0.firstMatch(in: line, range: range) != nil }
    }
}
