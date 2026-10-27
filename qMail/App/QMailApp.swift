import MailCore
import SwiftUI

@main
struct QMailApp: App {
    @State private var store = MailStore()
    @State private var navigator = AppNavigator()
    @State private var updater = Updater()

    var body: some Scene {
        Window("qMail", id: "main") {
            RootView()
                .modifier(UpdateWindowPresenter())
                .environment(store)
                .environment(navigator)
                .environment(updater)
                .task { await store.start() }
                .task { updater.start() }
        }
        .defaultSize(width: 1480, height: 900)
        .commands { MailCommands(store: store, navigator: navigator, updater: updater) }

        Window("Software Update", id: UpdateWindowPresenter.windowID) {
            UpdateView()
                .environment(updater)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(store)
                .environment(navigator)
                .environment(updater)
        }
    }
}

/// Brings the Software Update window forward when the updater has something to show.
struct UpdateWindowPresenter: ViewModifier {
    static let windowID = "update"
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: updater.presentation) { openWindow(id: Self.windowID) }
    }
}

struct MailCommands: Commands {
    let store: MailStore
    let navigator: AppNavigator
    let updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkNow()
                openWindow(id: UpdateWindowPresenter.windowID)
            }
        }
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
