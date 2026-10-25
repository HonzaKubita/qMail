import Foundation

/// A parsed IMAP data item.
public indirect enum IMAPValue: Sendable, Equatable {
    case atom(String)
    /// Quoted string or literal.
    case string(Data)
    case list([IMAPValue])
    case nilValue

    public var string: String? {
        switch self {
        case .atom(let value): value
        case .string(let data): String(decoding: data, as: UTF8.self)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let value): Data(value.utf8)
        default: nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let items) = self { items } else { nil }
    }

    public var int: Int? { string.flatMap { Int($0) } }
}

public enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

public enum IMAPUntagged: Sendable {
    case status(IMAPStatus, code: String?, text: String)
    case capability([String])
    case list(attributes: [String], delimiter: String?, name: String)
    case search([UInt32])
    case exists(Int)
    case recent(Int)
    case expunge(Int)
    case fetch(sequence: Int, attributes: [String: IMAPValue])
    case flags([String])
    case mailboxStatus(name: String, values: [String: Int])
    case other(String)
}

public enum IMAPResponse: Sendable {
    case continuation(String)
    case tagged(tag: String, status: IMAPStatus, code: String?, text: String)
    case untagged(IMAPUntagged)
}

/// Tokenizer for IMAP response data. Literals (`{n}\r\n` + n bytes) are expected inline.
struct IMAPTokenizer {
    private let bytes: [UInt8]
    private(set) var position: Int

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var isAtEnd: Bool { position >= bytes.count }

    mutating func skipSpaces() {
        while position < bytes.count, bytes[position] == 0x20 { position += 1 }
    }

    /// Reads up to the next space without any special handling.
    mutating func readWord() -> String {
        skipSpaces()
        let start = position
        while position < bytes.count, bytes[position] != 0x20 { position += 1 }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// The unparsed remainder, e.g. human-readable text after a status.
    mutating func remainder() -> String {
        skipSpaces()
        let text = String(decoding: bytes[min(position, bytes.count)...], as: UTF8.self)
        position = bytes.count
        return text
    }

    /// Reads an optional `[response code]` followed by free text.
    mutating func readStatusRest() -> (code: String?, text: String) {
        skipSpaces()
        var code: String?
        if position < bytes.count, bytes[position] == UInt8(ascii: "[") {
            var depth = 0
            let start = position + 1
            while position < bytes.count {
                if bytes[position] == UInt8(ascii: "[") { depth += 1 }
                if bytes[position] == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { break }
                }
                position += 1
            }
            code = String(decoding: bytes[start..<min(position, bytes.count)], as: UTF8.self)
            position = min(position + 1, bytes.count)
        }
        return (code, remainder())
    }

    mutating func next() throws -> IMAPValue? {
        skipSpaces()
        guard position < bytes.count else { return nil }
        switch bytes[position] {
        case UInt8(ascii: "("):
            position += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard position < bytes.count else { break }
                if bytes[position] == UInt8(ascii: ")") {
                    position += 1
                    break
                }
                guard let value = try next() else { break }
                items.append(value)
            }
            return .list(items)
        case UInt8(ascii: ")"):
            return nil
        case UInt8(ascii: "\""):
            return .string(readQuoted())
        case UInt8(ascii: "{"):
            return .string(try readLiteral())
        case UInt8(ascii: "~") where position + 1 < bytes.count && bytes[position + 1] == UInt8(ascii: "{"):
            position += 1
            return .string(try readLiteral())
        case 0x0D, 0x0A:
            position += 1
            return try next()
        default:
            let atom = readAtom()
            if atom.isEmpty {
                position += 1
                return try next()
            }
            return atom.uppercased() == "NIL" ? .nilValue : .atom(atom)
        }
    }

    mutating func readAll() throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while let value = try next() { values.append(value) }
        return values
    }

    /// Atoms may contain bracketed sections with spaces, e.g. `BODY[HEADER.FIELDS (FROM TO)]<0>`.
    private mutating func readAtom() -> String {
        let start = position
        var depth = 0
        while position < bytes.count {
            let byte = bytes[position]
            if depth == 0 {
                if byte == 0x20 || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")")
                    || byte == 0x0D || byte == 0x0A || byte == UInt8(ascii: "\"") {
                    break
                }
            }
            if byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "]") {
                depth = max(0, depth - 1)
            }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func readQuoted() -> Data {
        position += 1
        var output: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\\"), position + 1 < bytes.count {
                output.append(bytes[position + 1])
                position += 2
                continue
            }
            position += 1
            if byte == UInt8(ascii: "\"") { break }
            output.append(byte)
        }
        return Data(output)
    }

    private mutating func readLiteral() throws -> Data {
        position += 1
        var length = 0
        while position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39 {
            length = length * 10 + Int(bytes[position] - 0x30)
            position += 1
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "+") { position += 1 }
        guard position < bytes.count, bytes[position] == UInt8(ascii: "}") else {
            throw MailError.protocolError("Malformed literal")
        }
        position += 1
        if position < bytes.count, bytes[position] == 0x0D { position += 1 }
        if position < bytes.count, bytes[position] == 0x0A { position += 1 }
        let end = min(position + length, bytes.count)
        let data = Data(bytes[position..<end])
        position = end
        return data
    }
}

enum IMAPResponseParser {
    static func parse(_ data: Data) throws -> IMAPResponse {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { throw MailError.protocolError("Empty response") }

        if first == UInt8(ascii: "+") {
            let text = String(decoding: bytes.dropFirst(), as: UTF8.self)
            return .continuation(text.trimmingCharacters(in: .whitespaces))
        }

        var tokenizer = IMAPTokenizer(bytes: bytes)
        let tag = tokenizer.readWord()

        guard tag == "*" else {
            let word = tokenizer.readWord().uppercased()
            let rest = tokenizer.readStatusRest()
            return .tagged(tag: tag, status: IMAPStatus(rawValue: word) ?? .bad, code: rest.code, text: rest.text)
        }

        let keyword = tokenizer.readWord()
        let upper = keyword.uppercased()

        if let number = Int(keyword) {
            let kind = tokenizer.readWord().uppercased()
            switch kind {
            case "EXISTS": return .untagged(.exists(number))
            case "RECENT": return .untagged(.recent(number))
            case "EXPUNGE": return .untagged(.expunge(number))
            case "FETCH":
                guard case .list(let items)? = try tokenizer.next() else {
                    throw MailError.protocolError("Malformed FETCH response")
                }
                var attributes: [String: IMAPValue] = [:]
                var index = 0
                while index + 1 < items.count {
                    if let key = items[index].string { attributes[key.uppercased()] = items[index + 1] }
                    index += 2
                }
                return .untagged(.fetch(sequence: number, attributes: attributes))
            default:
                return .untagged(.other(String(decoding: bytes, as: UTF8.self)))
            }
        }

        if let status = IMAPStatus(rawValue: upper) {
            let rest = tokenizer.readStatusRest()
            return .untagged(.status(status, code: rest.code, text: rest.text))
        }

        switch upper {
        case "CAPABILITY":
            return .untagged(.capability(tokenizer.remainder().split(separator: " ").map { $0.uppercased() }))
        case "LIST", "LSUB", "XLIST":
            let attributes = try tokenizer.next()?.list?.compactMap(\.string) ?? []
            let delimiter = try tokenizer.next()?.string
            let name = try tokenizer.next()?.string ?? ""
            return .untagged(.list(attributes: attributes, delimiter: delimiter, name: name))
        case "SEARCH":
            let numbers = tokenizer.remainder().split(separator: " ").compactMap { UInt32($0) }
            return .untagged(.search(numbers))
        case "FLAGS":
            return .untagged(.flags(try tokenizer.next()?.list?.compactMap(\.string) ?? []))
        case "STATUS":
            let name = try tokenizer.next()?.string ?? ""
            let items = try tokenizer.next()?.list ?? []
            var values: [String: Int] = [:]
            var index = 0
            while index + 1 < items.count {
                if let key = items[index].string, let value = items[index + 1].int { values[key.uppercased()] = value }
                index += 2
            }
            return .untagged(.mailboxStatus(name: name, values: values))
        default:
            return .untagged(.other(String(decoding: bytes, as: UTF8.self)))
        }
    }

    /// Length of a literal announced at the end of a response line (`... {123}`), if any.
    static func trailingLiteralLength(_ line: Data) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.endIndex - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}

/// IMAP mailbox names use a modified UTF-7 encoding (RFC 3501 §5.1.3).
public enum ModifiedUTF7 {
    public static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var result = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            guard character == "&" else {
                result.append(character)
                index = input.index(after: index)
                continue
            }
            guard let dash = input[index...].firstIndex(of: "-") else {
                result += input[index...]
                break
            }
            let encoded = input[input.index(after: index)..<dash]
            if encoded.isEmpty {
                result.append("&")
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                    result += decoded
                } else {
                    result += input[index...dash]
                }
            }
            index = input.index(after: dash)
        }
        return result
    }

    public static func encode(_ input: String) -> String {
        var result = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data()
            for unit in pending {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xFF))
            }
            let base64 = data.base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            result += "&\(base64)-"
            pending.removeAll()
        }

        for scalar in input.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return result
    }
}
