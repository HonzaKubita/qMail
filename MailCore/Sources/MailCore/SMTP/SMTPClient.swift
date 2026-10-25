import Foundation

/// Minimal SMTP submission client (RFC 5321 + AUTH + STARTTLS). Each send uses its own session.
public struct SMTPClient: Sendable {
    private let endpoint: ServerEndpoint
    private let authProvider: MailAuthProvider

    public init(endpoint: ServerEndpoint, authProvider: @escaping MailAuthProvider) {
        self.endpoint = endpoint
        self.authProvider = authProvider
    }

    /// Opens a session and authenticates, without sending anything.
    public func verify() async throws {
        let session = try await open()
        await session.quit()
    }

    public func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        guard !recipients.isEmpty else { throw MailError.invalidConfiguration("Add at least one recipient.") }
        let session = try await open()
        do {
            try await session.command("MAIL FROM:<\(sender)>", expect: [250])
            for recipient in recipients {
                try await session.command("RCPT TO:<\(recipient)>", expect: [250, 251])
            }
            try await session.command("DATA", expect: [354])
            try await session.sendData(Self.dotStuffed(message))
            await session.quit()
        } catch {
            await session.close()
            throw error
        }
    }

    private func open() async throws -> SMTPSession {
        let session = SMTPSession(endpoint: endpoint)
        do {
            try await session.handshake()
            try await session.authenticate(try await authProvider())
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    /// Normalizes line endings to CRLF, escapes leading dots and appends the terminating `.` line.
    static func dotStuffed(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 1024)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A && previous != 0x0D { output.append(0x0D) }
            if atLineStart && byte == UInt8(ascii: ".") { output.append(UInt8(ascii: ".")) }
            output.append(byte)
            atLineStart = byte == 0x0A
            previous = byte
        }
        if !atLineStart { output.append(contentsOf: [0x0D, 0x0A]) }
        output.append(contentsOf: Array(".\r\n".utf8))
        return output
    }
}

private actor SMTPSession {
    private let endpoint: ServerEndpoint
    private let connection: StreamConnection
    private var extensions: Set<String> = []
    private var authMechanisms: Set<String> = []

    init(endpoint: ServerEndpoint) {
        self.endpoint = endpoint
        self.connection = StreamConnection(host: endpoint.host, port: endpoint.port)
    }

    func handshake() async throws {
        if endpoint.security == .tls { await connection.startTLS() }
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw MailError.protocolError(greeting.text) }
        try await ehlo()
        if endpoint.security == .startTLS {
            guard extensions.contains("STARTTLS") else {
                throw MailError.invalidConfiguration("The server does not support STARTTLS.")
            }
            try await command("STARTTLS", expect: [220])
            await connection.startTLS()
            try await ehlo()
        }
    }

    func authenticate(_ auth: MailAuth) async throws {
        do {
            switch auth {
            case .oauth2:
                let reply = try await rawCommand("AUTH XOAUTH2 \(auth.xoauth2Payload ?? "")")
                if reply.code == 334 {
                    // Error details arrive base64-encoded; an empty line ends the exchange.
                    let failure = try await rawCommand("")
                    throw MailError.authenticationFailed(failure.text)
                }
                guard reply.code == 235 else { throw MailError.authenticationFailed(reply.text) }
            case .password(let username, let password):
                if authMechanisms.contains("PLAIN") || authMechanisms.isEmpty {
                    let reply = try await rawCommand("AUTH PLAIN \(auth.plainPayload ?? "")")
                    guard reply.code == 235 else { throw MailError.authenticationFailed(reply.text) }
                } else {
                    try await command("AUTH LOGIN", expect: [334])
                    try await command(Data(username.utf8).base64EncodedString(), expect: [334])
                    let reply = try await rawCommand(Data(password.utf8).base64EncodedString())
                    guard reply.code == 235 else { throw MailError.authenticationFailed(reply.text) }
                }
            }
        } catch MailError.commandFailed(let message) {
            throw MailError.authenticationFailed(message)
        }
    }

    @discardableResult
    func command(_ line: String, expect codes: Set<Int>) async throws -> (code: Int, text: String) {
        let reply = try await rawCommand(line)
        guard codes.contains(reply.code) else {
            throw MailError.commandFailed("\(reply.code) \(reply.text)")
        }
        return reply
    }

    func sendData(_ data: Data) async throws {
        try await connection.write(data, timeout: max(60, Double(data.count) / 20_000))
        let reply = try await readReply(timeout: 180)
        guard reply.code == 250 else { throw MailError.commandFailed("\(reply.code) \(reply.text)") }
    }

    func quit() async {
        _ = try? await rawCommand("QUIT")
        await connection.close()
    }

    func close() async {
        await connection.close()
    }

    private func ehlo() async throws {
        let reply = try await command("EHLO [127.0.0.1]", expect: [250])
        extensions = []
        authMechanisms = []
        for line in reply.text.split(separator: "\n").dropFirst() {
            let words = line.uppercased().split(separator: " ").map(String.init)
            guard let keyword = words.first else { continue }
            extensions.insert(keyword)
            if keyword == "AUTH" { authMechanisms.formUnion(words.dropFirst()) }
        }
    }

    private func rawCommand(_ line: String) async throws -> (code: Int, text: String) {
        try await connection.write(line + "\r\n")
        return try await readReply()
    }

    private func readReply(timeout: TimeInterval = 60) async throws -> (code: Int, text: String) {
        var lines: [String] = []
        while true {
            let line = String(decoding: try await connection.readLine(timeout: timeout), as: UTF8.self)
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.protocolError(line)
            }
            let separator = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            lines.append(String(line.dropFirst(4)))
            if separator != "-" {
                return (code, lines.joined(separator: "\n"))
            }
        }
    }
}
