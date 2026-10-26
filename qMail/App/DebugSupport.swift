#if DEBUG
import AppKit
import Foundation
import MailCore
import SwiftUI

/// Development hooks driven by environment variables (Debug builds only):
///   QMAIL_TEST_SERVER=1        add an account for Tools/fake_mail_server.py (IMAP 127.0.0.1:1143, SMTP :1025)
///   QMAIL_TEST_SERVER=2        also add a second account (work@qmail.test) on the same server
///   QMAIL_TEST_SERVER=remove   remove the test accounts again (Keychain items and cache included)
///   QMAIL_SELECT=chat:N        preselect the Nth chat
///   QMAIL_SELECT=inbox:N       preselect the Nth inbox message
///   QMAIL_SEND=text            with chat:N, post a new thread in that chat (exercises SMTP + APPEND)
///   QMAIL_REPLY=text           with chat:N, reply in that chat's latest thread
///   QMAIL_OPEN_THREAD=1        open the latest thread that has replies
///   QMAIL_SELECT=new           open New Message (QMAIL_NEW_TO=a@b.c,… prefills recipients)
///   QMAIL_SELECT=reply:N       Reply All from the Nth inbox message, or reply:Subject words (opens its chat thread)
///   QMAIL_REPLY_ALL=text       with reply:…, send a reply to everyone and follow it, like the bottom bar does
///   QMAIL_SELECT=setup|settings  show the add-account sheet or the Settings window
///   QMAIL_SNAPSHOT=1           after a few seconds, write each window as base64 PNG to stderr
///                              (works while the screen is locked; Liquid Glass isn't drawn)
extension MailStore {
    static let testAccountEmail = "me@qmail.test"
    static let secondTestAccountEmail = "work@qmail.test"

    func installTestAccountIfRequested() async {
        guard let mode = ProcessInfo.processInfo.environment["QMAIL_TEST_SERVER"] else { return }
        let testEmails = [Self.testAccountEmail, Self.secondTestAccountEmail]
        if mode == "remove" {
            for account in accounts where testEmails.contains(account.email) { removeAccount(account.id) }
            return
        }
        for email in testEmails.prefix(mode == "2" ? 2 : 1) where !accounts.contains(where: { $0.email == email }) {
            await addTestAccount(email: email)
        }
    }

    private func addTestAccount(email: String) async {
        let account = Account(
            displayName: email == Self.testAccountEmail ? "Honza Test" : "Honza Work", email: email, provider: .other,
            imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none),
            smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none),
            username: email, authKind: .password, saveSentCopy: true
        )
        do {
            try await verify(account, secret: .password("test"))
            try await addAccount(account, secret: .password("test"))
        } catch {
            errorMessage = "Test server: \(error.localizedDescription)"
        }
    }
}

@MainActor
private func snapshotIfRequested(_ store: MailStore) async {
    guard ProcessInfo.processInfo.environment["QMAIL_SNAPSHOT"] != nil else { return }
    try? await Task.sleep(for: .seconds(9))
    // Text dump of the sidebar model, since list content doesn't render offscreen.
    for account in store.accounts {
        let sections = store.chatSections(for: account.id)
        func describe(_ chats: [Chat]) -> String {
            chats.map { "\(store.title(for: $0)) (\($0.threads.count) threads, \($0.unreadCount) unread)" }.joined(separator: " | ")
        }
        let lines = [
            "SIDEBAR \(account.email) unread=\(store.unreadCount(forAccount: account.id))",
            "  starred: \(describe(sections.starred))",
            "  groups: \(describe(sections.groups))",
            "  direct: \(describe(sections.direct))",
            "  updates: \(describe(sections.updates))",
            "  folders: \((store.mailboxes[account.id] ?? []).map(\.displayName).joined(separator: ", "))",
        ]
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
    for (index, window) in NSApp.windows.enumerated() where window.isVisible {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { continue }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
        // The sandbox keeps files inside the container, so hand the image out through stderr.
        let text = "SNAPSHOT-BEGIN \(index)\n\(png.base64EncodedString())\nSNAPSHOT-END\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

struct DebugSelection: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openSettings) private var openSettings
    @Binding var showingAddAccount: Bool
    @Binding var message: MessageSummary.ID?

    func body(content: Content) -> some View {
        content
            .task { await snapshotIfRequested(store) }
            .task {
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
                let sections = store.accounts.first.map { store.chatSections(for: $0.id) } ?? ChatSections()
                let chats = sections.starred + sections.groups + sections.direct + sections.updates
                if parts.first == "new", let account = store.accounts.first, !chats.isEmpty {
                    let recipients = MailAddress.parseList(ProcessInfo.processInfo.environment["QMAIL_NEW_TO"] ?? "")
                    navigator.startNewMessage(accountID: account.id, to: recipients)
                    return
                }
                if parts.first == "reply", let account = store.accounts.first,
                   let inbox = store.mailbox(role: .inbox, accountID: account.id),
                   let summary = Int(parts.count > 1 ? String(parts[1]) : "0") != nil
                       ? store.messages[inbox.id]?.dropFirst(index).first
                       : store.messages[inbox.id]?.first(where: { $0.subject.localizedCaseInsensitiveContains(String(parts[1])) }),
                   !chats.isEmpty {
                    navigator.reply(to: summary, all: true, store: store)
                    if let text = ProcessInfo.processInfo.environment["QMAIL_REPLY_ALL"],
                       let (chat, thread) = store.chatAndThread(containing: summary),
                       let last = thread.messageIDs.last.flatMap({ store.summary(id: $0) }) {
                        try? await Task.sleep(for: .seconds(1))
                        do {
                            let sentID = try await store.post(in: chat, thread: thread, text: text, subject: nil, attachments: [],
                                                              recipients: store.audience(of: last))
                            if let sentID, let sent = store.summary(id: sentID), let (target, targetThread) = store.chatAndThread(containing: sent) {
                                navigator.showChat(target.id, accountID: target.accountID, thread: targetThread.id)
                            }
                        } catch {
                            store.errorMessage = "Debug reply failed: \(error.localizedDescription)"
                        }
                    }
                    return
                }
                if parts.first == "chat", chats.count > index {
                    let target = chats[index]
                    navigator.accountID = target.accountID
                    try? await Task.sleep(for: .milliseconds(100))
                    navigator.selection = .chat(target.id)
                    let environment = ProcessInfo.processInfo.environment
                    if let text = environment["QMAIL_SEND"] ?? environment["QMAIL_REPLY"] {
                        try? await Task.sleep(for: .seconds(1))
                        let thread = environment["QMAIL_REPLY"] != nil ? target.threads.last : nil
                        do {
                            try await store.post(in: target, thread: thread, text: text, subject: nil, attachments: [])
                        } catch {
                            store.errorMessage = "Debug send failed: \(error.localizedDescription)"
                        }
                    }
                    return
                }
                if parts.first == "inbox", let account = store.accounts.first,
                   let inbox = store.mailbox(role: .inbox, accountID: account.id),
                   (store.messages[inbox.id]?.count ?? 0) > index {
                    navigator.accountID = account.id
                    try? await Task.sleep(for: .milliseconds(100))
                    navigator.selection = .mailbox(inbox.id)
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
