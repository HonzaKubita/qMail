import Foundation

public struct MIMEHeaders: Sendable, Hashable, Codable {
    public struct Field: Sendable, Hashable, Codable {
        public let name: String
        /// Unfolded raw value (encoded words are not decoded).
        public let value: String
    }

    public private(set) var fields: [Field]

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Value with RFC 2047 encoded words decoded.
    public func decoded(_ name: String) -> String? {
        self[name].map(EncodedWords.decode)
    }

    public static func parse(_ data: Data) -> MIMEHeaders {
        let text = Charset.decodeHeaderBytes(data)
        var fields: [Field] = []
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName {
                fields.append(Field(name: name, value: currentValue.trimmingCharacters(in: .whitespaces)))
            }
            currentName = nil
            currentValue = ""
        }

        // "\r\n" is a single Character in Swift, so split on any line terminator.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            if line.isEmpty {
                // End of the header block.
                if currentName != nil || !fields.isEmpty { break }
                continue
            }
            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            if let colon = line.firstIndex(of: ":") {
                currentName = line[..<colon].trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colon)...])
            }
        }
        flush()
        return MIMEHeaders(fields: fields)
    }

    /// Splits a raw message (or part) into header bytes and body bytes.
    static func split(_ data: Data) -> (header: Data, body: Data) {
        let crlf = data.range(of: Data([13, 10, 13, 10]))
        let lf = data.range(of: Data([10, 10]))
        let separator: Range<Data.Index>?
        switch (crlf, lf) {
        case let (a?, b?): separator = a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil): separator = a
        case let (nil, b?): separator = b
        default: separator = nil
        }
        // A part that starts with a blank line has no headers.
        if data.first == 10 || (data.count > 1 && data[data.startIndex] == 13 && data[data.startIndex + 1] == 10) {
            let skip = data.first == 10 ? 1 : 2
            return (Data(), data.subdata(in: (data.startIndex + skip)..<data.endIndex))
        }
        guard let separator else { return (data, Data()) }
        return (data.subdata(in: data.startIndex..<separator.lowerBound),
                data.subdata(in: separator.upperBound..<data.endIndex))
    }

    /// Parses `type/subtype; key=value; key*=charset''encoded` into a lowercased value and parameters.
    public static func parseParameterized(_ raw: String) -> (value: String, parameters: [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && inQuotes {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == ";" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)

        let value = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]

        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var paramValue = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if paramValue.hasPrefix("\""), paramValue.hasSuffix("\""), paramValue.count >= 2 {
                paramValue = String(paramValue.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            // RFC 2231: key*=charset'lang'value, key*0=..., key*1*=...
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((index, paramValue, extended))
                continue
            }
            parameters[key] = extended ? decodeRFC2231(paramValue, hasCharset: true) : paramValue
        }

        for (base, pieces) in continuations {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            let firstExtended = sorted.first?.2 ?? false
            if firstExtended {
                // Only the first segment carries charset'lang'; the rest are percent-encoded.
                var joined = ""
                for (offset, piece) in sorted.enumerated() {
                    joined += (offset == 0 || piece.2) ? piece.1 : piece.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? piece.1
                }
                parameters[base] = decodeRFC2231(joined, hasCharset: true)
            } else {
                parameters[base] = sorted.map(\.1).joined()
            }
        }
        return (value, parameters)
    }

    private static func decodeRFC2231(_ value: String, hasCharset: Bool) -> String {
        var charset = "utf-8"
        var encoded = value
        if hasCharset {
            let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                charset = parts[0].isEmpty ? "utf-8" : String(parts[0])
                encoded = String(parts[2])
            }
        }
        var bytes: [UInt8] = []
        var iterator = Array(encoded.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return Charset.decode(Data(bytes), charset: charset)
    }
}

/// RFC 2047 encoded words: `=?charset?B|Q?text?=`.
public enum EncodedWords {
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var output = ""
        var pendingBytes = Data()
        var pendingCharset: String?
        var pendingWhitespace = ""
        var index = input.startIndex

        func flushPending() {
            if let charset = pendingCharset {
                output += Charset.decode(pendingBytes, charset: charset)
            }
            pendingBytes = Data()
            pendingCharset = nil
        }

        while index < input.endIndex {
            if input[index...].hasPrefix("=?"), let word = parseWord(input, at: index) {
                // Whitespace between adjacent encoded words is dropped.
                if pendingCharset != nil, word.charset.lowercased() == pendingCharset?.lowercased() {
                    pendingBytes.append(word.bytes)
                } else {
                    flushPending()
                    pendingCharset = word.charset
                    pendingBytes = word.bytes
                }
                pendingWhitespace = ""
                index = word.end
                continue
            }
            let character = input[index]
            if pendingCharset != nil {
                if character == " " || character == "\t" {
                    pendingWhitespace.append(character)
                    index = input.index(after: index)
                    continue
                }
                flushPending()
                output += pendingWhitespace
                pendingWhitespace = ""
            }
            output.append(character)
            index = input.index(after: index)
        }
        flushPending()
        output += pendingWhitespace
        return output
    }

    private static func parseWord(_ input: String, at start: String.Index) -> (charset: String, bytes: Data, end: String.Index)? {
        let afterPrefix = input.index(start, offsetBy: 2)
        guard let q1 = input[afterPrefix...].firstIndex(of: "?") else { return nil }
        let encodingIndex = input.index(after: q1)
        guard encodingIndex < input.endIndex else { return nil }
        let q2 = input.index(after: encodingIndex)
        guard q2 < input.endIndex, input[q2] == "?" else { return nil }
        let textStart = input.index(after: q2)
        guard let close = input[textStart...].range(of: "?=") else { return nil }
        var charset = String(input[afterPrefix..<q1])
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
        guard !charset.isEmpty, !charset.contains(" ") else { return nil }
        let text = input[textStart..<close.lowerBound]
        guard !text.contains(" ") else { return nil }

        let bytes: Data
        switch input[encodingIndex] {
        case "B", "b":
            bytes = TransferEncoding.decodeBase64(Data(text.utf8))
        case "Q", "q":
            bytes = TransferEncoding.decodeQuotedPrintable(Data(text.replacingOccurrences(of: "_", with: " ").utf8))
        default:
            return nil
        }
        return (charset, bytes, close.upperBound)
    }

    /// Encodes header text as UTF-8 B encoded words when it contains non-ASCII characters.
    public static func encodeIfNeeded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7E || $0.value < 0x20 }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            let candidate = chunk + String(character)
            if candidate.utf8.count > 45 {
                words.append(chunk)
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words
            .map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }
            .joined(separator: "\r\n ")
    }
}

public enum Charset {
    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(for: charset), let string = String(data: data, encoding: encoding) {
            return string
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Header bytes are nominally ASCII but in practice often raw UTF-8 or Latin-1.
    static func decodeHeaderBytes(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    static func encoding(for name: String?) -> String.Encoding? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else {
            return nil
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8": return .utf8
        // Mislabelled Windows-1252 is far more common than true Latin-1.
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1": return .windowsCP1252
        case "gb2312", "gbk": name = "gb18030"
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

public enum TransferEncoding {
    public static func decode(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": decodeBase64(data)
        case "quoted-printable": decodeQuotedPrintable(data)
        default: data
        }
    }

    /// Lenient base64: skips line breaks and junk, tolerates truncated input.
    public static func decodeBase64(_ data: Data) -> Data {
        var filtered: [UInt8] = []
        filtered.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                filtered.append(byte)
            default: continue
            }
        }
        switch filtered.count % 4 {
        case 1: filtered.removeLast()
        case 2: filtered.append(contentsOf: [61, 61])
        case 3: filtered.append(61)
        default: break
        }
        return Data(base64Encoded: Data(filtered)) ?? Data()
    }

    public static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            } else if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                index += 3
            } else if index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    public static func encodeQuotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            var encodedLine = ""
            var lineLength = 0
            for (offset, byte) in bytes.enumerated() {
                let isLast = offset == bytes.count - 1
                var token: String
                if (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "=")) || ((byte == 0x20 || byte == 0x09) && !isLast) {
                    token = String(UnicodeScalar(byte))
                } else {
                    token = String(format: "=%02X", byte)
                }
                if lineLength + token.count > 75 {
                    encodedLine += "=\r\n"
                    lineLength = 0
                }
                encodedLine += token
                lineLength += token.count
            }
            lines.append(encodedLine)
        }
        return lines.joined(separator: "\r\n")
    }

    public static func encodeBase64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
}
