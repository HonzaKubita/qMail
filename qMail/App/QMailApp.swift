import MailCore
import SwiftUI

@main
struct QMailApp: App {
    @State private var store = MailStore()
    @State private var navigator = AppNavigator()

    var body: some Scene {
        Window("qMail", id: "main") {
            RootView()
                .environment(store)
                .environment(navigator)
                .task { await store.start() }
        }
        .defaultSize(width: 1480, height: 900)
        .commands { MailCommands(store: store, navigator: navigator) }

        Settings {
            SettingsView()
                .environment(store)
                .environment(navigator)
        }
    }
}

struct MailCommands: Commands {
    let store: MailStore
    let navigator: AppNavigator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                navigator.startNewMessage(accountID: navigator.accountID ?? store.accounts.first?.id)
            }
            .keyboardShortcut("n")
            .disabled(store.accounts.isEmpty)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            // ⌘1…⌘9 switch accounts, like tabs.
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.email) { navigator.accountID = account.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") {
                Task { await store.refreshAll() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
