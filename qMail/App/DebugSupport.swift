#if DEBUG
import AppKit
import Foundation
import MailCore
import SwiftUI

/// Development hooks driven by environment variables (Debug builds only):
///   QMAIL_TEST_SERVER=1        add an account for Tools/fake_mail_server.py (IMAP 127.0.0.1:1143, SMTP :1025)
///   QMAIL_TEST_SERVER=2        also add a second account (work@qmail.test) on the same server
///   QMAIL_TEST_SERVER=demo     add demo accounts for `fake_mail_server.py --demo` (for screenshots)
///   QMAIL_TEST_SERVER=remove   remove the test accounts again (Keychain items and cache included)
///   QMAIL_WINDOW=1440x900      resize the main window (points)
///   QMAIL_APPEARANCE=light|dark  force light or dark mode
///   QMAIL_SELECT=chat:N        preselect the Nth chat
///   QMAIL_SELECT=inbox:N       preselect the Nth inbox message
///   QMAIL_SEND=text            with chat:N, post a new thread in that chat (exercises SMTP + APPEND)
///   QMAIL_REPLY=text           with chat:N, reply in that chat's latest thread
///   QMAIL_OPEN_THREAD=1        open the latest thread that has replies
///   QMAIL_SELECT=activity      open Activity
///   QMAIL_SELECT=new           open New Message (QMAIL_NEW_TO=a@b.c,… prefills recipients)
///   QMAIL_SELECT=reply:N       Reply All from the Nth inbox message, or reply:Subject words (opens its chat thread)
///   QMAIL_REPLY_ALL=text       with reply:…, send a reply to everyone and follow it, like the bottom bar does
///   QMAIL_SELECT=setup|settings[:accounts]  show the add-account sheet or the Settings window
///   QMAIL_RESYNC=N             get new mail again N seconds after launch
///   QMAIL_SEARCH=text          type text into the search field
///   QMAIL_KEY=f                after a few seconds, press ⌘ and that key (e.g. ⌘F to search); `all` lists the menus
///   QMAIL_HOVER_ACCOUNT=N      show the Nth account's hover label in the rail
///   QMAIL_UPDATE_FEED=url      check this release JSON for updates (Debug builds don't check otherwise)
///   QMAIL_UPDATE_INSTALL=1     with QMAIL_UPDATE_FEED, install the update it finds right away
///   QMAIL_FIND=text            print where cached mail from/about `text` landed, then quit (no sync)
///   QMAIL_SNAPSHOT=1           after a few seconds, write each window as base64 PNG to stderr
///                              (works while the screen is locked; Liquid Glass isn't drawn)
extension MailStore {
    static let testAccountEmail = "me@qmail.test"
    static let secondTestAccountEmail = "work@qmail.test"
    /// Demo accounts: the fake server's --demo mail is addressed to the first one.
    static let demoAccounts = [("Emma Lindqvist", "emma@example.com"), ("Emma Lindqvist", "emma@studio.example.com")]

    /// QMAIL_FIND=text: prints where cached messages whose sender or subject contains `text` ended up
    /// (folder, chat, position in their thread) to stderr, then quits before syncing or showing anything.
    func runFindIfRequested() {
        guard let text = ProcessInfo.processInfo.environment["QMAIL_FIND"] else { return }
        func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        for account in accounts {
            log("ACCOUNT \(account.email)")
            for mailbox in mailboxes[account.id] ?? [] where mailbox.role != .custom {
                let list = messages[mailbox.id] ?? []
                let state = folderStates[mailbox.id]
                log("FOLDER \(mailbox.path) role=\(mailbox.role) cached=\(list.count) exists=\(state?.exists ?? -1) lastSync=\(state?.lastSync.map { "\($0)" } ?? "-") newest=\(list.map(\.date).max().map { "\($0)" } ?? "-")")
            }
            let found = summaryIndex.values.filter { summary in
                summary.accountID == account.id
                    && "\(summary.sender?.email ?? "") \(summary.sender?.name ?? "") \(summary.subject)".localizedCaseInsensitiveContains(text)
            }
            for summary in found.sorted(by: { $0.date > $1.date }).prefix(25) {
                var place = "NOT IN ANY CHAT"
                if let (chat, thread) = chatAndThread(containing: summary) {
                    let position = thread.messageIDs.firstIndex { summaryIndex[$0]?.messageID == summary.messageID } ?? -1
                    place = "chat=\(title(for: chat)) hidden=\(chatPreferences.hidden.contains(chat.id)) thread=\((chat.threads.firstIndex(of: thread) ?? -1) + 1)/\(chat.threads.count) position=\(position + 1)/\(thread.messageIDs.count) threadStart=\(thread.startDate)"
                }
                log("MSG \(summary.date) folder=\(summary.mailboxPath) from=\(summary.sender?.email ?? "-") seen=\(summary.isSeen) gmailThread=\(summary.gmailThreadID ?? "-") subject=\(summary.subject.prefix(50)) | \(place)")
                let validity = folderStates[Mailbox.makeID(accountID: account.id, path: summary.mailboxPath)]?.uidValidity ?? 0
                if let data = Persistence.loadBody(summary, uidValidity: validity) {
                    let parsed = ParsedMessage(data: data)
                    log("  BODY bytes=\(data.count) plain=\(parsed.textBody?.count ?? -1) html=\(parsed.htmlBody?.count ?? -1) chat=\(QuoteStripper.chatText(for: parsed).prefix(300).debugDescription)")
                } else {
                    log("  BODY not on disk")
                }
            }
        }
        exit(0)
    }

    func installTestAccountIfRequested() async {
        guard let mode = ProcessInfo.processInfo.environment["QMAIL_TEST_SERVER"] else { return }
        let testAccounts = [("Honza Test", Self.testAccountEmail), ("Honza Work", Self.secondTestAccountEmail)]
        if mode == "remove" {
            let emails = (testAccounts + Self.demoAccounts).map(\.1)
            for account in accounts where emails.contains(account.email) { removeAccount(account.id) }
            return
        }
        let wanted = mode == "demo" ? Self.demoAccounts : Array(testAccounts.prefix(mode == "2" ? 2 : 1))
        for (name, email) in wanted where !accounts.contains(where: { $0.email == email }) {
            await addTestAccount(name: name, email: email)
        }
    }

    private func addTestAccount(name: String, email: String) async {
        let account = Account(
            displayName: name, email: email, provider: .other,
            imap: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none),
            smtp: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none),
            username: email, authKind: .password, saveSentCopy: true
        )
        do {
            try await verify(account, secret: .password("test"))
            try await addAccount(account, secret: .password("test"))
            if email == Self.demoAccounts[0].1 { setAppearance(of: account.id, tint: AccountTint.blue.rawValue, symbol: "person.fill") }
            if email == Self.demoAccounts[1].1 { setAppearance(of: account.id, tint: AccountTint.orange.rawValue, symbol: "briefcase.fill") }
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

@MainActor
private func applyWindowOverrides() async {
    let environment = ProcessInfo.processInfo.environment
    switch environment["QMAIL_APPEARANCE"] {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: break
    }
    guard let size = environment["QMAIL_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 else { return }
    try? await Task.sleep(for: .milliseconds(300))
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
    var frame = window.frame
    frame.origin.y += frame.height - size[1]
    frame.size = CGSize(width: size[0], height: size[1])
    window.setFrame(frame, display: true)
}

/// QMAIL_KEY=f: sends ⌘F through the main menu and then the window, as if typed, to check a shortcut.
@MainActor
private func pressShortcutIfRequested() async {
    guard let key = ProcessInfo.processInfo.environment["QMAIL_KEY"] else { return }
    try? await Task.sleep(for: .seconds(4))
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
          let event = NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
              isARepeat: false, keyCode: 0
          ) else { return }
    func items(_ menu: NSMenu?, _ path: String) -> [String] {
        (menu?.items ?? []).flatMap { item in
            let here = path + " > " + item.title
            let own = item.keyEquivalent == key || key == "all" ? ["\(here) [\(item.keyEquivalentModifierMask.rawValue)] enabled=\(item.isEnabled)"] : []
            return own + items(item.submenu, here)
        }
    }
    FileHandle.standardError.write(Data("QMAIL_KEY items: \(items(NSApp.mainMenu, ""))\n".utf8))
    // Shortcuts on views (not menu items) are handled by the window instead.
    let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "menu"
        : window.performKeyEquivalent(with: event) ? "window" : "nothing"
    try? await Task.sleep(for: .seconds(1))
    // Names the focused view and the views it sits in, e.g. a search field's editor inside the toolbar.
    var chain: [String] = []
    var view = window.firstResponder as? NSView
    while let current = view, chain.count < 6 {
        chain.append(String(describing: type(of: current)))
        view = current.superview
    }
    let responder = chain.isEmpty ? window.firstResponder.map { String(describing: type(of: $0)) } ?? "none" : chain.joined(separator: " < ")
    FileHandle.standardError.write(Data("QMAIL_KEY ⌘\(key) handled by \(handled), focus: \(responder)\n".utf8))
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
            .task { await applyWindowOverrides() }
            .task { await pressShortcutIfRequested() }
            .task { await runMailAuditIfRequested(store) }
            .task {
            guard let spec = ProcessInfo.processInfo.environment["QMAIL_SELECT"] else { return }
            let parts = spec.split(separator: ":")
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if parts.first == "setup" {
                showingAddAccount = true
                return
            }
            if parts.first == "settings" {
                if parts.count > 1, parts[1] == "accounts" { navigator.settingsAccountID = store.accounts.last?.id }
                openSettings()
                return
            }
            for _ in 0..<40 {
                let sections = store.accounts.first.map { store.chatSections(for: $0.id) } ?? ChatSections()
                let chats = sections.starred + sections.groups + sections.direct + sections.updates
                // msg:<end of summary ID> opens the chat containing that message (IDs as printed by QMAIL_AUDIT).
                if parts.first == "msg", parts.count > 1, !chats.isEmpty {
                    let suffix = spec.dropFirst(4)
                    if let summary = store.summaryIndex.values.first(where: { $0.id.hasSuffix(suffix) }),
                       let (chat, _) = store.chatAndThread(containing: summary) {
                        navigator.accountID = chat.accountID
                        try? await Task.sleep(for: .milliseconds(100))
                        navigator.selection = .chat(chat.id)
                    }
                    return
                }
                if parts.first == "activity", !chats.isEmpty {
                    navigator.selection = .activity
                    return
                }
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

#if DEBUG
/// QMAIL_AUDIT=N: reads the N most recent chat messages per account (without marking them read)
/// and reports quote-stripping leftovers and how HTML emails reference images. Output goes to stderr.
/// QMAIL_AUDIT_TAGS=<ID suffix> also lists that message's <img> sources and image parts;
/// QMAIL_AUDIT_SUBJECT=<subject> prints the raw and chat text of messages with that subject.
@MainActor
func runMailAuditIfRequested(_ store: MailStore) async {
    guard let raw = ProcessInfo.processInfo.environment["QMAIL_AUDIT"] else { return }
    let limit = Int(raw) ?? 150
    for _ in 0..<60 where store.chats.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
    try? await Task.sleep(for: .seconds(3))
    func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    let quoteLine = try! NSRegularExpression(
        pattern: #"(wrote|napsal|napsala|odesílatel|schrieb|a écrit|escribió|ha scritto|schreef|skrev)\s*:?\s*$|^\s*>|^\s*\*?(from|od|von|de)\s*:\*?\s|original message|původní zpráva|^_{8,}"#,
        options: [.caseInsensitive])
    let imgSrc = try! NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*(["']?)([^"'\s>]+)\1"#, options: [.caseInsensitive])
    func matches(_ line: String) -> Bool {
        quoteLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    log("AUDIT-BEGIN accounts=\(store.accounts.count)")
    for account in store.accounts {
        let ids = Set(store.chats.filter { $0.accountID == account.id && !$0.isAutomated }.flatMap(\.messageIDs))
        let summaries = ids.compactMap { store.summary(id: $0) }.filter { !store.isPending($0) }
            .sorted { $0.date > $1.date }.prefix(limit)
        log("ACCOUNT \(account.email) checking=\(summaries.count)")
        var snippetIssues = 0, quoteIssues = 0, imageMails = 0
        for summary in summaries {
            let tag = String(summary.id.suffix(6))
            let snippet = QuoteStripper.cleanSnippet(summary.snippet)
            if snippet.range(of: #"(wrote:|napsal|odesílatel|> )"#, options: [.regularExpression, .caseInsensitive]) != nil {
                snippetIssues += 1
                log("SNIPPET \(tag): …\(snippet.suffix(160))")
            }
            guard let parsed = try? await store.loadMessage(summary) else { log("LOADFAIL \(tag)"); continue }
            let source = (parsed.textBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "text" : "html"
            let text = QuoteStripper.chatText(for: parsed)
            if let subject = ProcessInfo.processInfo.environment["QMAIL_AUDIT_SUBJECT"], summary.subject == subject {
                log("TEXT \(tag) source=\(source) mailbox=\(summary.mailboxPath) plain=\((parsed.textBody ?? "-").debugDescription.prefix(120)) chat=\(text.debugDescription.prefix(120))")
            }
            let lines = text.components(separatedBy: "\n")
            let bad = lines.indices.filter { matches(lines[$0]) }
            if !bad.isEmpty {
                quoteIssues += 1
                log("QUOTE \(tag) source=\(source) lines=\(lines.count) client=\(parsed.headers["X-Mailer"] ?? parsed.headers["User-Agent"] ?? "?")")
                for index in bad.prefix(3) {
                    let context = lines[max(0, index - 1)...min(lines.count - 1, index + 1)].map { "    | " + $0.prefix(140) }
                    log(context.joined(separator: "\n"))
                }
            }
            if let html = parsed.htmlBody {
                let range = NSRange(html.startIndex..., in: html)
                let sources = imgSrc.matches(in: html, range: range).compactMap { Range($0.range(at: 2), in: html).map { String(html[$0]) } }
                let imageAttachments = parsed.attachments.filter { $0.mimeType.hasPrefix("image/") }
                guard !sources.isEmpty || !imageAttachments.isEmpty else { continue }
                imageMails += 1
                let cids = sources.filter { $0.lowercased().hasPrefix("cid:") }
                let ids = Set(parsed.attachments.compactMap { $0.contentID?.lowercased() })
                let unmatched = cids.filter { !ids.contains(String($0.dropFirst(4)).lowercased().removingPercentEncoding ?? "") }
                let remote = sources.filter { $0.lowercased().hasPrefix("http") }
                let protocolRelative = sources.filter { $0.hasPrefix("//") }
                let data = sources.filter { $0.lowercased().hasPrefix("data:") }
                let other = sources.count - cids.count - remote.count - protocolRelative.count - data.count
                let quotedURL = html.range(of: #"url\(\s*['"]?\s*(https?:)?//"#, options: .regularExpression) != nil
                log("IMAGES \(tag) src=\(sources.count) cid=\(cids.count) cidUnmatched=\(unmatched.count) remote=\(remote.count) protoRel=\(protocolRelative.count) data=\(data.count) other=\(other) cssURL=\(quotedURL) detectedRemote=\(HTMLView.hasRemoteContent(html)) imageAttachments=\(imageAttachments.count) inline=\(imageAttachments.filter(\.isInline).count) chatThumbnails=\(ChatImages.extract(from: parsed).count)")
                for cid in unmatched.prefix(2) { log("    unmatched \(cid.prefix(80)) ids=\(ids.prefix(3).joined(separator: ","))") }
                if ProcessInfo.processInfo.environment["QMAIL_AUDIT_TAGS"].map({ tag.hasSuffix($0) }) ?? false {
                    let tags = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: .caseInsensitive)
                        .matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
                    for found in tags { log("    tag " + (found.range(of: #"src=\S{0,80}"#, options: .regularExpression).map { String(found[$0]) } ?? "no-src").replacingOccurrences(of: "\n", with: " ")) }
                    for attachment in parsed.attachments where attachment.mimeType.hasPrefix("image/") {
                        log("    part \(attachment.mimeType) \(attachment.filename) bytes=\(attachment.data.count) cid=\(attachment.contentID ?? "-")")
                    }
                }
                if !unmatched.isEmpty || other > 0 {
                    func dump(_ part: MIMEPart, _ depth: Int) {
                        let disposition = part.headers["Content-Disposition"].map { String($0.prefix(40)) } ?? "-"
                        log("    tree " + String(repeating: "  ", count: depth) + "\(part.mimeType) enc=\(part.transferEncoding) disp=\(disposition) cid=\(part.contentID ?? "-") bytes=\(part.body.count) params=\(part.parameters.keys.sorted())")
                        part.children.forEach { dump($0, depth + 1) }
                    }
                    log("    top Content-Type: \(parsed.headers["Content-Type"]?.prefix(120) ?? "-")")
                    dump(parsed.root, 0)
                }
                if other > 0 { log("    other: \(sources.filter { !$0.lowercased().hasPrefix("cid:") && !$0.lowercased().hasPrefix("http") && !$0.hasPrefix("//") && !$0.lowercased().hasPrefix("data:") }.prefix(2).map { String($0.prefix(60)) })") }
            }
        }
        log("SUMMARY \(account.email) snippetIssues=\(snippetIssues) quoteIssues=\(quoteIssues) imageMails=\(imageMails)")
    }
    log("AUDIT-END")
}
#endif
