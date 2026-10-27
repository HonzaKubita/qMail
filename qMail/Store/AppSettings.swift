import Foundation
import MailCore
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    var loadRemoteContent: Bool { didSet { defaults.set(loadRemoteContent, forKey: "loadRemoteContent") } }
    var messagesPerFolder: Int { didSet { defaults.set(messagesPerFolder, forKey: "messagesPerFolder") } }
    /// Download every message's text in the background so search covers the whole mailbox.
    var downloadAllMail: Bool { didSet { defaults.set(downloadAllMail, forKey: "downloadAllMail") } }

    init() {
        defaults.register(defaults: [
            "refreshMinutes": 5,
            "loadRemoteContent": false,
            "messagesPerFolder": 250,
            "downloadAllMail": true,
        ])
        refreshMinutes = defaults.integer(forKey: "refreshMinutes")
        loadRemoteContent = defaults.bool(forKey: "loadRemoteContent")
        messagesPerFolder = defaults.integer(forKey: "messagesPerFolder")
        downloadAllMail = defaults.bool(forKey: "downloadAllMail")
    }
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
