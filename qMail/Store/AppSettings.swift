import Foundation
import MailCore
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    var loadRemoteContent: Bool { didSet { defaults.set(loadRemoteContent, forKey: "loadRemoteContent") } }
    var chatsIncludeAutomated: Bool { didSet { defaults.set(chatsIncludeAutomated, forKey: "chatsIncludeAutomated") } }
    var chatsRequireOwnMessage: Bool { didSet { defaults.set(chatsRequireOwnMessage, forKey: "chatsRequireOwnMessage") } }
    var messagesPerFolder: Int { didSet { defaults.set(messagesPerFolder, forKey: "messagesPerFolder") } }

    var googleClientID: String { didSet { defaults.set(googleClientID, forKey: "googleClientID") } }
    var googleClientSecret: String { didSet { defaults.set(googleClientSecret, forKey: "googleClientSecret") } }
    var microsoftClientID: String { didSet { defaults.set(microsoftClientID, forKey: "microsoftClientID") } }

    /// Register this exact redirect URI for the app in the Azure portal ("Mobile and desktop applications").
    static let microsoftRedirectURI = "msauth.com.honzakubita.qmail://auth"

    init() {
        defaults.register(defaults: [
            "refreshMinutes": 5,
            "loadRemoteContent": false,
            "chatsIncludeAutomated": false,
            "chatsRequireOwnMessage": false,
            "messagesPerFolder": 250,
            "googleClientID": OAuthDefaults.googleClientID,
            "googleClientSecret": OAuthDefaults.googleClientSecret,
            "microsoftClientID": OAuthDefaults.microsoftClientID,
        ])
        refreshMinutes = defaults.integer(forKey: "refreshMinutes")
        loadRemoteContent = defaults.bool(forKey: "loadRemoteContent")
        chatsIncludeAutomated = defaults.bool(forKey: "chatsIncludeAutomated")
        chatsRequireOwnMessage = defaults.bool(forKey: "chatsRequireOwnMessage")
        messagesPerFolder = defaults.integer(forKey: "messagesPerFolder")
        googleClientID = defaults.string(forKey: "googleClientID") ?? ""
        googleClientSecret = defaults.string(forKey: "googleClientSecret") ?? ""
        microsoftClientID = defaults.string(forKey: "microsoftClientID") ?? ""
    }

    func oauthConfiguration(for provider: OAuthProvider) -> OAuthConfiguration? {
        switch provider {
        case .google:
            let id = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : .google(clientID: id, clientSecret: googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        case .microsoft:
            let id = microsoftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : .microsoft(clientID: id, redirectURI: Self.microsoftRedirectURI)
        }
    }
}

/// Bake OAuth client IDs into the build here, or enter them in Settings ▸ Sign-In.
/// See README.md for how to create them.
enum OAuthDefaults {
    static let googleClientID = ""
    static let googleClientSecret = ""
    static let microsoftClientID = ""
}

/// Per-chat customizations (custom names, pins, hidden chats).
struct ChatPreferences: Codable, Equatable {
    var names: [String: String] = [:]
    var pinned: Set<String> = []
    var hidden: Set<String> = []

    static func load() -> ChatPreferences {
        guard let data = UserDefaults.standard.data(forKey: "chatPreferences"),
              let value = try? JSONDecoder().decode(ChatPreferences.self, from: data) else { return ChatPreferences() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "chatPreferences")
        }
    }
}
