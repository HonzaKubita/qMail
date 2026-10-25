import Foundation

/// Fast HTML-to-text flattening for previews and chat bubbles. A single pass over UTF-8 bytes
/// (tags and entities are ASCII), so it stays quick even on large marketing emails.
public enum HTMLText {
    private static let skippedElements: Set<String> = ["style", "script", "head", "title", "xml"]
    private static let blockElements: Set<String> = [
        "p", "div", "br", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "hr", "ul", "ol", "section", "article", "header", "footer", "pre",
    ]

    public static func plainText(_ html: String) -> String {
        let bytes = Array(html.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / 2)
        var index = 0
        var lastWasSpace = true

        func emitNewline() {
            while output.last == 0x20 { output.removeLast() }
            output.append(0x0A)
            lastWasSpace = true
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") {
                // Comments
                if index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "!"), bytes[index + 2] == UInt8(ascii: "-"),
                   bytes[index + 3] == UInt8(ascii: "-") {
                    index = find(bytes, Array("-->".utf8), from: index + 4).map { $0 + 3 } ?? bytes.count
                    continue
                }
                let tagEnd = endOfTag(bytes, from: index + 1)
                let (name, isClosing) = tagName(bytes, from: index + 1, to: tagEnd)
                index = min(tagEnd + 1, bytes.count)
                if !isClosing, skippedElements.contains(name) {
                    let closing = Array("</\(name)".utf8)
                    if let close = findCaseInsensitive(bytes, closing, from: index) {
                        index = min(endOfTag(bytes, from: close + 1) + 1, bytes.count)
                    } else {
                        index = bytes.count
                    }
                    continue
                }
                if name == "li", !isClosing {
                    emitNewline()
                    output.append(contentsOf: Array("• ".utf8))
                } else if blockElements.contains(name) {
                    emitNewline()
                } else if name == "td" || name == "th" {
                    if !lastWasSpace {
                        output.append(0x20)
                        lastWasSpace = true
                    }
                }
                continue
            }
            if byte == UInt8(ascii: "&"), let (decoded, length) = decodeEntity(bytes, at: index) {
                output.append(contentsOf: decoded)
                lastWasSpace = decoded == [0x20]
                index += length
                continue
            }
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                if !lastWasSpace {
                    output.append(0x20)
                    lastWasSpace = true
                }
                index += 1
                continue
            }
            output.append(byte)
            lastWasSpace = false
            index += 1
        }

        return tidy(String(decoding: output, as: UTF8.self))
    }

    /// Trims each line, removes invisible characters and collapses runs of blank lines.
    static func tidy(_ text: String) -> String {
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{034F}"]
        var lines: [String] = []
        var blankRun = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine.filter { !invisible.contains($0) })
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endOfTag(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    private static func tagName(_ bytes: [UInt8], from start: Int, to end: Int) -> (String, Bool) {
        var index = start
        var closing = false
        if index < end, bytes[index] == UInt8(ascii: "/") {
            closing = true
            index += 1
        }
        let nameStart = index
        while index < end, index < bytes.count {
            let byte = bytes[index]
            let isNameChar = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
            if !isNameChar { break }
            index += 1
        }
        return (String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased(), closing)
    }

    private static func find(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start < bytes.count else { return nil }
        var index = start
        while index + needle.count <= bytes.count {
            if bytes[index] == needle[0], Array(bytes[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        let lowerNeedle = needle.map(lower)
        guard start < bytes.count else { return nil }
        var index = start
        outer: while index + lowerNeedle.count <= bytes.count {
            for offset in 0..<lowerNeedle.count where lower(bytes[index + offset]) != lowerNeedle[offset] {
                index += 1
                continue outer
            }
            return index
        }
        return nil
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 32 : byte
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "thinsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
        "times": "×", "divide": "÷", "plusmn": "±", "para": "¶", "sect": "§", "zwnj": "", "zwj": "", "shy": "",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "yacute": "ý",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Yacute": "Ý",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "agrave": "à", "egrave": "è", "ograve": "ò", "ccedil": "ç", "ntilde": "ñ", "ecirc": "ê", "acirc": "â",
        "ccaron": "č", "Ccaron": "Č", "scaron": "š", "Scaron": "Š", "zcaron": "ž", "Zcaron": "Ž",
        "ecaron": "ě", "Ecaron": "Ě", "rcaron": "ř", "Rcaron": "Ř", "ncaron": "ň", "dcaron": "ď", "tcaron": "ť",
        "uring": "ů", "Uring": "Ů", "rarr": "→", "larr": "←", "hearts": "♥",
    ]

    private static func decodeEntity(_ bytes: [UInt8], at start: Int) -> ([UInt8], Int)? {
        var index = start + 1
        let limit = min(bytes.count, start + 12)
        while index < limit, bytes[index] != UInt8(ascii: ";") {
            let byte = bytes[index]
            let valid = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
                || byte == UInt8(ascii: "#")
            if !valid { return nil }
            index += 1
        }
        guard index < limit, bytes[index] == UInt8(ascii: ";") else { return nil }
        let name = String(decoding: bytes[(start + 1)..<index], as: UTF8.self)
        let length = index - start + 1
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            if value == 160 { return ([0x20], length) }
            return (Array(String(Character(scalar)).utf8), length)
        }
        guard let replacement = entities[name] ?? entities[name.lowercased()] else { return nil }
        return (Array(replacement.utf8), length)
    }
}
