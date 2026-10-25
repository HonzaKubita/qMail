import Foundation

public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable, Identifiable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plaintext greeting upgraded with STARTTLS (SMTP 587).
    case startTLS
    case none

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tls: "SSL/TLS"
        case .startTLS: "STARTTLS"
        case .none: "None"
        }
    }
}

public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public enum MailAuth: Sendable {
    case password(username: String, password: String)
    case oauth2(username: String, accessToken: String)

    /// SASL XOAUTH2 initial response, shared by IMAP and SMTP.
    var xoauth2Payload: String? {
        guard case .oauth2(let username, let token) = self else { return nil }
        let raw = "user=\(username)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }

    /// SASL PLAIN initial response.
    var plainPayload: String? {
        guard case .password(let username, let password) = self else { return nil }
        return Data("\u{00}\(username)\u{00}\(password)".utf8).base64EncodedString()
    }
}

public typealias MailAuthProvider = @Sendable () async throws -> MailAuth
