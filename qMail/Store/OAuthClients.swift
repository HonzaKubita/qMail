import AuthenticationServices
import MailCore
import SwiftUI

/// The OAuth clients registered for qMail. Native apps are public clients, so these IDs
/// identify the app but are not secrets and ship with it.
enum OAuthClients {
    /// Google Cloud project `qmail-512809` ▸ Google Auth Platform ▸ Clients ▸ "qMail macOS"
    /// (type iOS, bundle ID `com.honzakubita.qmail`). Consent screen name: qbitMail.
    static let googleClientID = "197154325667-7kf61odgihnhe2eooub9ucl9sfbao3ib.apps.googleusercontent.com"

    /// Microsoft Entra ▸ App registrations ▸ Application (client) ID.
    static let microsoftClientID = ""
    /// Registered under Authentication ▸ Mobile and desktop applications.
    static let microsoftRedirectURI = "msauth.com.honzakubita.qmail://auth"

    static func configuration(for provider: OAuthProvider) -> OAuthConfiguration? {
        switch provider {
        case .google:
            googleClientID.isEmpty ? nil : .google(clientID: googleClientID)
        case .microsoft:
            microsoftClientID.isEmpty ? nil : .microsoft(clientID: microsoftClientID, redirectURI: microsoftRedirectURI)
        }
    }

    static func isConfigured(_ provider: OAuthProvider) -> Bool {
        configuration(for: provider) != nil
    }
}

/// Runs the browser-based sign-in (Authorization Code + PKCE) and returns tokens.
@MainActor
enum OAuthSignIn {
    static func run(_ provider: OAuthProvider, loginHint: String?, using session: WebAuthenticationSession) async throws -> OAuthTokens {
        guard let config = OAuthClients.configuration(for: provider) else {
            throw MailError.oauth("Sign in with \(provider.displayName) isn't set up in this build of qMail.")
        }
        let pkce = PKCE()
        let state = UUID().uuidString
        let url = OAuthClient.authorizationURL(config, pkce: pkce, state: state, loginHint: loginHint)
        let callback = try await session.authenticate(using: url, callbackURLScheme: config.callbackScheme, preferredBrowserSession: .ephemeral)
        let code = try OAuthClient.authorizationCode(from: callback, expectedState: state)
        return try await OAuthClient.exchange(code: code, pkce: pkce, config: config)
    }

    /// True when the user closed the sign-in window themselves.
    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
