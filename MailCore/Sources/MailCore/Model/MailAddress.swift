import Foundation

public struct MailAddress: Codable, Hashable, Sendable, Identifiable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var id: String { normalizedEmail }
    public var normalizedEmail: String { email.lowercased() }

    public var displayName: String {
        guard let name, name.caseInsensitiveCompare(email) != .orderedSame else { return email }
        return name
    }

    /// First name (or the local part of the address) for compact lists like chat titles.
    public var shortName: String {
        if let name, name.caseInsensitiveCompare(email) != .orderedSame {
            // "Last, First" ordering
            if name.contains(",") {
                let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[1].isEmpty { return parts[1].split(separator: " ").first.map(String.init) ?? parts[1] }
            }
            return name.split(separator: " ").first.map(String.init) ?? name
        }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    public var initials: String {
        let source = (name?.isEmpty == false ? name! : email.split(separator: "@").first.map(String.init) ?? email)
        let words = source
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? String(source.prefix(1)).uppercased() : letters.joined()
    }

    public var domain: String {
        email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
    }

    /// RFC 5322 representation suitable for outgoing headers.
    public var headerValue: String {
        guard let name, !name.isEmpty else { return email }
        let encodedName: String
        if name.unicodeScalars.contains(where: { $0.value > 0x7E }) {
            encodedName = EncodedWords.encodeIfNeeded(name)
        } else if name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
            encodedName = "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            encodedName = name
        }
        return "\(encodedName) <\(email)>"
    }

    /// Parses an address list header such as `"Doe, Jane" <jane@x.com>, bob@y.org, Team: a@b.c;`.
    public static func parseList(_ raw: String) -> [MailAddress] {
        var chunks: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var commentDepth = 0
        var escaped = false

        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes || commentDepth > 0:
                current.append(character)
                escaped = true
                continue
            case "\"" where commentDepth == 0:
                inQuotes.toggle()
            case "(" where !inQuotes:
                commentDepth += 1
            case ")" where !inQuotes && commentDepth > 0:
                commentDepth -= 1
            case "<" where !inQuotes && commentDepth == 0:
                inAngle = true
            case ">" where !inQuotes && commentDepth == 0:
                inAngle = false
            case ":" where !inQuotes && !inAngle && commentDepth == 0:
                // Group name, e.g. "Team: a@b.c, d@e.f;" — drop the label.
                current = ""
                continue
            case ",", ";":
                if !inQuotes && !inAngle && commentDepth == 0 {
                    chunks.append(current)
                    current = ""
                    continue
                }
            default:
                break
            }
            current.append(character)
        }
        chunks.append(current)
        return chunks.compactMap(parseSingle)
    }

    private static func parseSingle(_ chunk: String) -> MailAddress? {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
            let email = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { return nil }
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            name = unquote(stripComments(name))
            return MailAddress(name: EncodedWords.decode(name), email: email)
        }

        // Bare address, possibly with a trailing "(Display Name)" comment.
        var comment: String?
        if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
            comment = String(trimmed[trimmed.index(after: open)..<close])
        }
        let email = stripComments(trimmed).trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !email.contains(" ") else { return nil }
        return MailAddress(name: comment.map(EncodedWords.decode), email: unquote(email))
    }

    private static func stripComments(_ text: String) -> String {
        var output = ""
        var depth = 0
        var inQuotes = false
        for character in text {
            if character == "\"" && depth == 0 { inQuotes.toggle() }
            if !inQuotes {
                if character == "(" { depth += 1; continue }
                if character == ")" && depth > 0 { depth -= 1; continue }
            }
            if depth == 0 { output.append(character) }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
            value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Extracts `<message-id>` tokens from Message-ID / In-Reply-To / References headers.
    public static func messageIDs(in raw: String?) -> [String] {
        guard let raw else { return [] }
        var ids: [String] = []
        var current: String?
        for character in raw {
            if character == "<" {
                current = ""
            } else if character == ">" {
                if let id = current, !id.isEmpty { ids.append(id.trimmingCharacters(in: .whitespaces)) }
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        if ids.isEmpty {
            let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bare.isEmpty, !bare.contains(" "), bare.contains("@") { ids.append(bare) }
        }
        return ids
    }
}

extension Array where Element == MailAddress {
    /// Folded, comma separated header value.
    public var headerValue: String {
        var result = ""
        var lineLength = 4
        for (index, address) in enumerated() {
            let piece = address.headerValue
            if index > 0 {
                if lineLength + piece.count + 2 > 76 {
                    result += ",\r\n "
                    lineLength = 1
                } else {
                    result += ", "
                    lineLength += 2
                }
            }
            result += piece
            lineLength += piece.count
        }
        return result
    }
}
