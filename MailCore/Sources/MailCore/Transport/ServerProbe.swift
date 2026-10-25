import Foundation

/// Unauthenticated reachability check: connects, completes TLS/STARTTLS and reads capabilities.
public enum ServerProbe {
    public enum Kind: Sendable { case imap, smtp }

    public static func probe(kind: Kind, endpoint: ServerEndpoint) async throws -> String {
        let connection = StreamConnection(host: endpoint.host, port: endpoint.port)
        defer { Task { await connection.close() } }
        if endpoint.security == .tls { await connection.startTLS() }

        switch kind {
        case .imap:
            let greeting = String(decoding: try await connection.readLine(timeout: 15), as: UTF8.self)
            if endpoint.security == .startTLS {
                try await connection.write("A0 STARTTLS\r\n")
                _ = try await connection.readLine(timeout: 15)
                await connection.startTLS()
            }
            try await connection.write("A1 CAPABILITY\r\n")
            var capabilities = ""
            while true {
                let line = String(decoding: try await connection.readLine(timeout: 15), as: UTF8.self)
                if line.hasPrefix("* CAPABILITY") { capabilities = String(line.dropFirst(13)) }
                if line.hasPrefix("A1 ") { break }
            }
            try? await connection.write("A2 LOGOUT\r\n")
            return "\(greeting.prefix(60)) | \(capabilities)"
        case .smtp:
            func reply() async throws -> [String] {
                var lines: [String] = []
                while true {
                    let line = String(decoding: try await connection.readLine(timeout: 15), as: UTF8.self)
                    lines.append(line)
                    if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" { return lines }
                }
            }
            let greeting = try await reply().first ?? ""
            try await connection.write("EHLO [127.0.0.1]\r\n")
            var extensions = try await reply()
            if endpoint.security == .startTLS {
                try await connection.write("STARTTLS\r\n")
                let response = try await reply()
                guard response.first?.hasPrefix("220") == true else {
                    throw MailError.protocolError(response.joined(separator: " "))
                }
                await connection.startTLS()
                try await connection.write("EHLO [127.0.0.1]\r\n")
                extensions = try await reply()
            }
            try? await connection.write("QUIT\r\n")
            let auth = extensions.first { $0.uppercased().contains("AUTH ") } ?? "no AUTH advertised"
            return "\(greeting.prefix(60)) | \(auth)"
        }
    }
}
