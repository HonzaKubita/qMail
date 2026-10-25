#if DEBUG
import Foundation
import MailCore
import SwiftUI

/// Development hooks driven by environment variables (Debug builds only):
///   QMAIL_TEST_SERVER=1        add an account for Tools/fake_mail_server.py (IMAP 127.0.0.1:1143, SMTP :1025)
///   QMAIL_TEST_SERVER=remove   remove that account again (Keychain item and cache included)
///   QMAIL_SELECT=chat:N        preselect the Nth chat
///   QMAIL_SELECT=inbox:N       preselect the Nth inbox message
///   QMAIL_SEND=text            with chat:N, reply in that chat (exercises SMTP + APPEND)
///   QMAIL_SELECT=compose:N     open a Reply All window for the Nth chat's latest message
///   QMAIL_SELECT=setup|settings  show the add-account sheet or the Settings window
extension MailStore {
    static let testAccountEmail = "me@qmail.test"

    func installTestAccountIfRequested() async {
        guard let mode = ProcessInfo.processInfo.environment["QMAIL_TEST_SERVER"] else { return }
        if mode == "remove" {
            for account in accounts where account.email == Self.testAccountEmail { removeAccount(account.id) }
            return
        }
        guard !accounts.contains(where: { $0.email == Self.testAccountEmail }) else { return }
        let account = Account(
            displayName: "Honza Test", email: Self.testAccountEmail, provider: .other,
            imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none),
            smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none),
            username: Self.testAccountEmail, authKind: .password, saveSentCopy: true
        )
        do {
            try await verify(account, secret: .password("test"))
            try await addAccount(account, secret: .password("test"))
        } catch {
            errorMessage = "Test server: \(error.localizedDescription)"
        }
    }
}

struct DebugSelection: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Binding var showingAddAccount: Bool
    @Binding var sidebar: SidebarItem?
    @Binding var chat: Chat.ID?
    @Binding var message: MessageSummary.ID?

    func body(content: Content) -> some View {
        content.task {
            guard let spec = ProcessInfo.processInfo.environment["QMAIL_SELECT"] else { return }
            let parts = spec.split(separator: ":")
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if parts.first == "setup" {
                showingAddAccount = true
                return
            }
            if parts.first == "settings" {
                openSettings()
                return
            }
            for _ in 0..<40 {
                if parts.first == "compose", store.visibleChats.count > index {
                    let target = store.visibleChats[index]
                    openWindow(id: "compose", value: ComposeRequest(mode: .replyAll, messageID: target.lastMessageID))
                    return
                }
                if parts.first == "chat", store.visibleChats.count > index {
                    let target = store.visibleChats[index]
                    sidebar = .chats
                    chat = target.id
                    if let text = ProcessInfo.processInfo.environment["QMAIL_SEND"] {
                        try? await Task.sleep(for: .seconds(1))
                        do {
                            try await store.sendChatMessage(in: target, text: text, threadSubject: nil, newSubject: nil, attachments: [])
                        } catch {
                            store.errorMessage = "Debug send failed: \(error.localizedDescription)"
                        }
                    }
                    return
                }
                if parts.first == "inbox", let account = store.accounts.first,
                   let inbox = store.mailbox(role: .inbox, accountID: account.id),
                   (store.messages[inbox.id]?.count ?? 0) > index {
                    sidebar = .mailbox(inbox.id)
                    try? await Task.sleep(for: .milliseconds(300))
                    message = store.messages[inbox.id]?[index].id
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
#endif
