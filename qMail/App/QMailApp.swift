import MailCore
import SwiftUI

@main
struct QMailApp: App {
    @State private var store = MailStore()

    var body: some Scene {
        WindowGroup("qMail", id: "main") {
            RootView()
                .environment(store)
                .task { await store.start() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands { MailCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: ComposeRequest.self) { $request in
            ComposeView(request: request ?? ComposeRequest())
                .environment(store)
        }
        .defaultSize(width: 680, height: 580)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Identifies what a compose window should be prefilled with.
struct ComposeRequest: Codable, Hashable {
    enum Mode: String, Codable {
        case new, reply, replyAll, forward
    }

    var id = UUID()
    var mode: Mode = .new
    /// Summary ID of the message being replied to or forwarded.
    var messageID: String?
    var accountID: UUID?
    var to: [String] = []
    var subject = ""
}

struct MailCommands: Commands {
    let store: MailStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                openWindow(id: "compose", value: ComposeRequest())
            }
            .keyboardShortcut("n")
            Button("New Viewer Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") {
                Task { await store.refreshAll() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
