import CryptoKit
import Foundation

public enum OAuthProvider: String, Codable, Sendable {
    case google
    case microsoft

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .microsoft: "Microsoft"
        }
    }
}

public struct OAuthConfiguration: Sendable, Hashable {
    public var provider: OAuthProvider
    public var authorizeURL: URL
    public var tokenURL: URL
    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: String
    public var scopes: [String]
    /// Scopes that must actually be granted for mail to work. Google's consent screen lets people
    /// untick individual permissions, so sign-in can succeed without mail access.
    public var mailScopes: [String]
    public var extraParameters: [String: String]

    public var callbackScheme: String {
        URL(string: redirectURI)?.scheme ?? ""
    }

    /// Google "iOS" OAuth clients redirect to the reversed client ID scheme.
    public static func google(clientID: String, clientSecret: String? = nil) -> OAuthConfiguration {
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return OAuthConfiguration(
            provider: .google,
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: clientID,
            clientSecret: clientSecret?.isEmpty == true ? nil : clientSecret,
            redirectURI: "\(reversed):/oauth2redirect",
            scopes: ["https://mail.google.com/", "openid", "email", "profile"],
            mailScopes: ["https://mail.google.com/"],
            extraParameters: ["access_type": "offline", "prompt": "consent"]
        )
    }

    public static func microsoft(clientID: String, redirectURI: String) -> OAuthConfiguration {
        OAuthConfiguration(
            provider: .microsoft,
            authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            clientID: clientID,
            clientSecret: nil,
            redirectURI: redirectURI,
            scopes: [
                "https://outlook.office.com/IMAP.AccessAsUser.All",
                "https://outlook.office.com/SMTP.Send",
                "offline_access", "openid", "email", "profile",
            ],
            mailScopes: ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send"],
            extraParameters: ["prompt": "select_account", "response_mode": "query"]
        )
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var email: String?
    public var name: String?
    /// Scopes the user actually granted, when the token response lists them.
    public var grantedScopes: [String]?

    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        verifier = Self.base64URL(Data(bytes))
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthClient {
    public static func authorizationURL(_ config: OAuthConfiguration, pkce: PKCE, state: String, loginHint: String?) -> URL {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        for (key, value) in config.extraParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw MailError.oauth(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw MailError.oauth("The sign-in response did not match the request.") }
        guard let code = value("code") else { throw MailError.oauth("No authorization code was returned.") }
        return code
    }

    public static func exchange(code: String, pkce: PKCE, config: OAuthConfiguration) async throws -> OAuthTokens {
        var parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": pkce.verifier,
        ]
        if let secret = config.clientSecret { parameters["client_secret"] = secret }
        if config.provider == .microsoft { parameters["scope"] = config.scopes.joined(separator: " ") }
        let tokens = try await tokenRequest(parameters, config: config, previous: nil)
        if let granted = tokens.grantedScopes {
            let missing = config.mailScopes.filter { required in
                !granted.contains { $0.caseInsensitiveCompare(required) == .orderedSame || required.hasSuffix("/" + $0) }
            }
            if !missing.isEmpty { throw MailError.mailAccessNotGranted }
        }
        return tokens
    }

    public static func refresh(_ tokens: OAuthTokens, config: OAuthConfiguration) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw MailError.signInRequired }
        var parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        if let secret = config.clientSecret { parameters["client_secret"] = secret }
        if config.provider == .microsoft { parameters["scope"] = config.scopes.joined(separator: " ") }
        do {
            return try await tokenRequest(parameters, config: config, previous: tokens)
        } catch TokenError.invalidGrant {
            // Refresh token expired (e.g. 7 days for Google apps in testing) or access was revoked.
            throw MailError.signInRequired
        }
    }

    private enum TokenError: Error { case invalidGrant }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var refresh_token: String?
        var expires_in: Double?
        var id_token: String?
        var scope: String?
        var error: String?
        var error_description: String?
    }

    private static func tokenRequest(_ parameters: [String: String], config: OAuthConfiguration, previous: OAuthTokens?) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(parameters).utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let accessToken = response.access_token else {
            if response.error == "invalid_grant" && previous != nil { throw TokenError.invalidGrant }
            throw MailError.oauth(response.error_description ?? response.error ?? "Sign-in failed.")
        }
        let claims = response.id_token.flatMap(decodeJWTClaims) ?? [:]
        let email = (claims["email"] as? String) ?? (claims["preferred_username"] as? String) ?? previous?.email
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: response.refresh_token ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expires_in ?? 3600),
            email: email,
            name: (claims["name"] as? String) ?? previous?.name,
            grantedScopes: response.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.grantedScopes
        )
    }

    static func formEncode(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
