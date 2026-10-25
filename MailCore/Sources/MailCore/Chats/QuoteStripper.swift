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
        return strip(raw)
    }

    private static let inlineReplyRegexes: [NSRegularExpression] = [
        #"\bOn [^\n]{5,160}? wrote:"#,
        #"\bDne [^\n]{5,160}? napsal(a|\(a\))?:"#,
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
        let result = snippet[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? snippet : result
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
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var index = 0

        lineLoop: while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Signature delimiter.
            if line == "-- " || trimmed == "--" { break }

            // Reply header, possibly wrapped over two lines.
            let joinedWithNext = index + 1 < lines.count ? trimmed + " " + lines[index + 1].trimmingCharacters(in: .whitespaces) : trimmed
            if matchesAny(trimmed, replyRegexes) || (trimmed.lowercased().hasPrefix("on ") && matchesAny(joinedWithNext, replyRegexes))
                || (trimmed.lowercased().hasPrefix("dne ") && matchesAny(joinedWithNext, replyRegexes)) {
                break
            }

            // Outlook style header block: "From: …" followed closely by "Sent:"/"Date:"/"To:"/"Subject:".
            if isHeaderLine(trimmed, keys: ["from:", "od:", "von:", "de:"]) {
                let window = lines[(index + 1)..<min(lines.count, index + 5)]
                if window.contains(where: { isHeaderLine($0.trimmingCharacters(in: .whitespaces), keys: ["sent:", "date:", "to:", "subject:", "odesláno:", "komu:", "předmět:", "datum:", "gesendet:", "an:", "betreff:", "envoyé:", "objet:"]) }) {
                    break lineLoop
                }
            }

            if trimmed.hasPrefix(">") {
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
        if result.isEmpty {
            // The whole message was quoted (e.g. a bare forward) — show it rather than nothing.
            return HTMLText.tidy(String(normalized.prefix(2000)))
        }
        return result
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
