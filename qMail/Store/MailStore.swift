import AppKit
import Foundation
import MailCore
import Observation

enum SidebarItem: Hashable, Codable {
    case chat(String)
    case mailbox(String)
    case newMessage
}

/// A workspace's chats grouped the way the sidebar shows them.
struct ChatSections {
    var starred: [Chat] = []
    var groups: [Chat] = []
    var direct: [Chat] = []
    var updates: [Chat] = []

    var isEmpty: Bool { starred.isEmpty && groups.isEmpty && direct.isEmpty && updates.isEmpty }
}

/// What a chat bubble shows for one message.
struct ChatContent: Sendable {
    var text: String
    var attachmentNames: [String]
}

/// App-wide state: accounts, cached mail, chats, and all server interaction.
@MainActor @Observable
final class MailStore {
    let settings = AppSettings()
    @ObservationIgnored let credentials = CredentialStore()

    private(set) var isLoaded = false
    private(set) var accounts: [Account] = []
    private(set) var mailboxes: [UUID: [Mailbox]] = [:]
    private(set) var messages: [String: [MessageSummary]] = [:]
    private(set) var summaryIndex: [String: MessageSummary] = [:]
    private(set) var chats: [Chat] = []
    private(set) var chatContents: [String: ChatContent] = [:]
    private(set) var ownAddresses: [UUID: Set<String>] = [:]
    private(set) var knownContacts: [MailAddress] = []
    private(set) var syncingAccounts: Set<UUID> = []
    private(set) var accountErrors: [UUID: String] = [:]
    /// OAuth accounts whose sign-in expired or was revoked.
    private(set) var accountsNeedingSignIn: Set<UUID> = []
    private(set) var folderStates: [String: FolderState] = [:]
    var chatPreferences = ChatPreferences.load() {
        didSet { chatPreferences.save() }
    }
    /// Transient error shown as a banner.
    var errorMessage: String?

    @ObservationIgnored private var clients: [UUID: (sync: IMAPClient, interactive: IMAPClient)] = [:]
    @ObservationIgnored private var idleTasks: [UUID: (task: Task<Void, Never>, client: IMAPClient)] = [:]
    @ObservationIgnored private var parsedCache: [String: ParsedMessage] = [:]
    @ObservationIgnored private var parsedCacheOrder: [String] = []
    @ObservationIgnored private var syncingFolders: Set<String> = []
    @ObservationIgnored private var pendingSent: [MessageSummary] = []
    @ObservationIgnored private var pendingBodies: [String: Data] = [:]
    @ObservationIgnored private var lastMailboxListRefresh: [UUID: Date] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastFullSync: Date?
    @ObservationIgnored private var started = false

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        accounts = Persistence.loadAccounts()
        for account in accounts {
            let accountID = account.id
            if let cache = await Task.detached(operation: { Persistence.loadCache(accountID) }).value {
                mailboxes[accountID] = cache.mailboxes
                folderStates.merge(cache.folderStates) { $1 }
                for (mailboxID, list) in cache.messages { setMessages(list, for: mailboxID) }
            }
        }
        rebuildChats()
        isLoaded = true
        #if DEBUG
        await installTestAccountIfRequested()
        #endif
        startRefreshLoop()
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let minutes = max(1, self?.settings.refreshMinutes ?? 5)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let last = self.lastFullSync, Date().timeIntervalSince(last) > 60 else { return }
                await self.refreshAll()
            }
        }
    }

    // MARK: - Lookups

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func mailbox(id: String) -> Mailbox? {
        for list in mailboxes.values {
            if let match = list.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    func mailbox(role: MailboxRole, accountID: UUID) -> Mailbox? {
        mailboxes[accountID]?.first { $0.role == role }
    }

    func mailbox(for summary: MessageSummary) -> Mailbox? {
        mailbox(id: Mailbox.makeID(accountID: summary.accountID, path: summary.mailboxPath))
    }

    func summary(id: String) -> MessageSummary? { summaryIndex[id] }

    func isOwn(_ address: MailAddress?, accountID: UUID) -> Bool {
        guard let address else { return false }
        return ownAddresses[accountID]?.contains(address.normalizedEmail) ?? false
    }

    func isFromMe(_ summary: MessageSummary) -> Bool {
        isOwn(summary.sender, accountID: summary.accountID)
    }

    func isPending(_ summary: MessageSummary) -> Bool { summary.id.hasPrefix("pending|") }

    func messages(for item: SidebarItem) -> [MessageSummary] {
        switch item {
        case .chat, .newMessage: []
        case .mailbox(let id): messages[id] ?? []
        }
    }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .chat(let id): chat(id: id).map { title(for: $0) } ?? "Chat"
        case .mailbox(let id): mailbox(id: id)?.displayName ?? "Mailbox"
        case .newMessage: "New Message"
        }
    }

    func unreadCount(for item: SidebarItem) -> Int {
        switch item {
        case .chat(let id): chat(id: id)?.unreadCount ?? 0
        case .mailbox: messages(for: item).reduce(0) { $0 + ($1.isSeen ? 0 : 1) }
        case .newMessage: 0
        }
    }

    /// Unread messages from people (not newsletters) in a workspace, for the account rail and Dock.
    func unreadCount(forAccount accountID: UUID) -> Int {
        visibleChats(for: accountID).filter { !$0.isAutomated }.reduce(0) { $0 + $1.unreadCount }
    }

    func canLoadOlder(in mailboxID: String) -> Bool {
        (folderStates[mailboxID]?.exists ?? 0) > (messages[mailboxID]?.count ?? 0)
    }

    var isSyncing: Bool { !syncingAccounts.isEmpty }

    // MARK: - Chats

    func visibleChats(for accountID: UUID) -> [Chat] {
        chats
            .filter { $0.accountID == accountID && !chatPreferences.hidden.contains($0.id) }
            .sorted { lhs, rhs in
                let lp = chatPreferences.pinned.contains(lhs.id), rp = chatPreferences.pinned.contains(rhs.id)
                if lp != rp { return lp }
                return lhs.lastDate > rhs.lastDate
            }
    }

    func chat(id: String) -> Chat? { chats.first { $0.id == id } }

    /// The chat and thread a message lives in. Copies of a message in other folders match by
    /// Message-ID; mail you sent to several people may be in several chats, so the first wins.
    func chatAndThread(containing summary: MessageSummary) -> (Chat, ChatThread)? {
        for chat in chats where chat.accountID == summary.accountID {
            if let thread = chat.threads.first(where: { thread in
                thread.messageIDs.contains { id in
                    id == summary.id || (summary.messageID != nil && summaryIndex[id]?.messageID == summary.messageID)
                }
            }) {
                return (chat, thread)
            }
        }
        return nil
    }

    /// The chat for exactly these people in an account, if there is one.
    func chat(accountID: UUID, with people: [MailAddress]) -> Chat? {
        let mine = ownAddresses[accountID] ?? []
        let wanted = Set(people.map(\.normalizedEmail).filter { !mine.contains($0) })
        return chats.first { $0.accountID == accountID && Set($0.participants.map(\.normalizedEmail)) == wanted }
    }

    /// Everyone on a message except you.
    func audience(of summary: MessageSummary) -> [MailAddress] {
        let mine = ownAddresses[summary.accountID] ?? []
        var seen = Set<String>()
        return (summary.from + summary.to + summary.cc).filter { address in
            !mine.contains(address.normalizedEmail) && seen.insert(address.normalizedEmail).inserted
        }
    }

    func chatSections(for accountID: UUID, matching query: String = "") -> ChatSections {
        let query = query.trimmingCharacters(in: .whitespaces)
        var sections = ChatSections()
        for chat in visibleChats(for: accountID) where query.isEmpty || matches(chat, query) {
            if chatPreferences.pinned.contains(chat.id) {
                sections.starred.append(chat)
            } else if chat.isAutomated {
                sections.updates.append(chat)
            } else if chat.isGroup {
                sections.groups.append(chat)
            } else {
                sections.direct.append(chat)
            }
        }
        return sections
    }

    private func matches(_ chat: Chat, _ query: String) -> Bool {
        title(for: chat).localizedCaseInsensitiveContains(query)
            || chat.subjects.contains { $0.localizedCaseInsensitiveContains(query) }
            || chat.participants.contains {
                $0.displayName.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query)
            }
            || chat.messageIDs.contains { id in
                (chatContents[id]?.text ?? summaryIndex[id]?.snippet ?? "").localizedCaseInsensitiveContains(query)
            }
    }

    func title(for chat: Chat) -> String {
        if let custom = chatPreferences.names[chat.id], !custom.isEmpty { return custom }
        if chat.isSelf { return "\(account(chat.accountID)?.displayName ?? "Me") (you)" }
        return chat.defaultTitle
    }

    func rename(_ chat: Chat, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        chatPreferences.names[chat.id] = trimmed.isEmpty ? nil : trimmed
    }

    func togglePinned(_ chat: Chat) {
        if chatPreferences.pinned.contains(chat.id) {
            chatPreferences.pinned.remove(chat.id)
        } else {
            chatPreferences.pinned.insert(chat.id)
        }
    }

    func hide(_ chat: Chat) {
        chatPreferences.hidden.insert(chat.id)
        chatPreferences.pinned.remove(chat.id)
    }

    func unhideAllChats() {
        chatPreferences.hidden.removeAll()
    }

    /// Recomputes chats from Inbox, Sent and Archive/All Mail of every account.
    func rebuildChats() {
        var own: [UUID: Set<String>] = [:]
        var sources: [MessageSummary] = []
        for account in accounts {
            var mine = account.ownAddresses
            let sourceRoles: [MailboxRole] = [.inbox, .sent, .archive, .all]
            for role in sourceRoles {
                guard let mailbox = mailbox(role: role, accountID: account.id) else { continue }
                let list = messages[mailbox.id] ?? []
                if role == .sent {
                    // Learn aliases: whatever we send from is ours.
                    for message in list { if let from = message.sender { mine.insert(from.normalizedEmail) } }
                }
                sources.append(contentsOf: list)
            }
            own[account.id] = mine
        }

        // Drop local echoes of sent messages once the server copy has arrived.
        var realByMessageID: [String: String] = [:]
        for message in sources { if let id = message.messageID { realByMessageID[id] = message.id } }
        pendingSent.removeAll { pending in
            guard let messageID = pending.messageID, let realID = realByMessageID[messageID] else { return false }
            if chatContents[realID] == nil { chatContents[realID] = chatContents[pending.id] }
            summaryIndex[pending.id] = nil
            pendingBodies[pending.id] = nil
            return true
        }
        sources.append(contentsOf: pendingSent)

        ownAddresses = own
        chats = ChatBuilder.build(messages: sources, ownAddresses: own)
        rebuildContacts()
        updateDockBadge()
    }

    private func rebuildContacts() {
        var counts: [String: (address: MailAddress, count: Int)] = [:]
        let allOwn = ownAddresses.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for summary in summaryIndex.values where !summary.isAutomated {
            for address in summary.from + summary.to + summary.cc where !allOwn.contains(address.normalizedEmail) {
                let key = address.normalizedEmail
                var entry = counts[key] ?? (address, 0)
                if entry.address.name == nil, address.name != nil { entry.address = address }
                entry.count += 1
                counts[key] = entry
            }
        }
        knownContacts = counts.values.sorted { $0.count > $1.count }.prefix(1000).map(\.address)
    }

    /// Loads the cleaned-up text of the most recent threads in a chat.
    func loadChatContents(for chat: Chat, threadLimit: Int = 40) async {
        await loadContents(for: chat.threads.suffix(threadLimit).flatMap(\.messageIDs))
    }

    /// Loads (and caches) the cleaned-up text of messages, fetching bodies that aren't on disk yet.
    func loadContents(for messageIDs: [String]) async {
        let summaries = messageIDs
            .filter { chatContents[$0] == nil }
            .compactMap { summaryIndex[$0] }
            .filter { !isPending($0) }
        guard !summaries.isEmpty else { return }

        let lookups = summaries.map { ($0, folderStates[Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath)]?.uidValidity ?? 0) }
        var raw: [String: Data] = await Task.detached {
            var found: [String: Data] = [:]
            for (summary, validity) in lookups {
                if let data = Persistence.loadBody(summary, uidValidity: validity) { found[summary.id] = data }
            }
            return found
        }.value

        let missing = summaries.filter { raw[$0.id] == nil }
        let groups = Dictionary(grouping: missing) { Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath) }
        for (mailboxID, group) in groups {
            guard let first = group.first, let account = account(first.accountID) else { continue }
            let validity = folderStates[mailboxID]?.uidValidity ?? 0
            let client = clientPair(for: account).interactive
            for batch in group.chunked(into: 25) {
                do {
                    let fetched = try await client.fetchRawMessages(in: first.mailboxPath, uids: batch.map(\.uid))
                    for summary in batch {
                        guard let data = fetched[summary.uid] else { continue }
                        raw[summary.id] = data
                        Task.detached(priority: .utility) { Persistence.saveBody(data, for: summary, uidValidity: validity) }
                    }
                } catch {
                    break
                }
            }
        }

        let input = raw
        let parsed = await Task.detached(priority: .userInitiated) {
            input.mapValues { data -> ChatContent in
                let message = ParsedMessage(data: data)
                return ChatContent(
                    text: QuoteStripper.chatText(for: message),
                    attachmentNames: message.visibleAttachments.map(\.filename)
                )
            }
        }.value
        chatContents.merge(parsed) { $1 }
    }

    func markChatRead(_ chat: Chat) {
        let unread = chat.messageIDs.compactMap { summaryIndex[$0] }.filter { !$0.isSeen && !isFromMe($0) }
        setRead(unread, read: true)
    }

    /// Posts to a chat: a reply inside `thread`, or a new email (a new thread) when `thread` is nil.
    /// `recipients` overrides who gets it, e.g. replying to everyone from a 1:1 chat.
    /// Returns the ID of the sent message as it appears in chats until the server copy arrives.
    @discardableResult
    func post(in chat: Chat, thread: ChatThread?, text: String, subject: String?, attachments: [OutgoingAttachment],
              recipients: [MailAddress]? = nil) async throws -> String? {
        guard let account = account(chat.accountID) else { return nil }
        let target = thread.flatMap { $0.messageIDs.last }.flatMap { summaryIndex[$0] }
        var references: [String] = []
        if let target {
            references = target.references
            if references.isEmpty, let parent = target.inReplyTo { references = [parent] }
            if let id = target.messageID { references.append(id) }
        }
        let outgoing = OutgoingMessage(
            from: account.address,
            to: recipients ?? (chat.isSelf ? [account.address] : chat.participants),
            subject: target.map { ReplyBuilder.replySubject($0.subject) } ?? Self.subject(subject, fallback: text),
            body: text,
            inReplyTo: target?.messageID,
            references: Array(references.suffix(20)),
            attachments: attachments
        )
        return try await send(outgoing, account: account, replyingTo: target)
    }

    /// A new message without a subject uses its first line, the way chat messages become emails.
    static func subject(_ subject: String?, fallback text: String) -> String {
        if let subject = subject?.trimmingCharacters(in: .whitespaces), !subject.isEmpty { return subject }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard firstLine.count > 60 else { return firstLine }
        let cut = firstLine.prefix(60)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    // MARK: - Sync

    func refreshAll() async {
        lastFullSync = Date()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                let id = account.id
                group.addTask { await self.sync(accountID: id) }
            }
        }
    }

    func sync(accountID: UUID) async {
        guard let account = account(accountID), !syncingAccounts.contains(accountID) else { return }
        syncingAccounts.insert(accountID)
        defer { syncingAccounts.remove(accountID) }
        let client = clientPair(for: account).sync
        do {
            let listIsStale = lastMailboxListRefresh[accountID].map { Date().timeIntervalSince($0) > 1800 } ?? true
            if listIsStale || (mailboxes[accountID]?.isEmpty ?? true) {
                let list = try await client.listMailboxes()
                mailboxes[accountID] = Mailbox.makeList(from: list, accountID: accountID, provider: account.provider)
                lastMailboxListRefresh[accountID] = Date()
            }
            for mailbox in foldersToSync(accountID) {
                try await syncFolder(mailbox, account: account, client: client)
            }
            accountErrors[accountID] = nil
            accountsNeedingSignIn.remove(accountID)
            startIdle(for: account)
        } catch {
            accountErrors[accountID] = error.localizedDescription
            if Self.requiresSignIn(error, account: account) { accountsNeedingSignIn.insert(accountID) }
        }
        rebuildChats()
        scheduleSave(accountID)
    }

    /// Called when a folder is shown; syncs it if it hasn't been refreshed recently.
    func refreshIfStale(_ item: SidebarItem) async {
        let targets: [Mailbox]
        switch item {
        case .chat, .newMessage: return
        case .mailbox(let id): targets = mailbox(id: id).map { [$0] } ?? []
        }
        for mailbox in targets {
            if let last = folderStates[mailbox.id]?.lastSync, Date().timeIntervalSince(last) < 60 { continue }
            guard let account = account(mailbox.accountID) else { continue }
            do {
                try await syncFolder(mailbox, account: account, client: clientPair(for: account).interactive)
                scheduleSave(account.id)
            } catch {
                accountErrors[account.id] = error.localizedDescription
            }
        }
        rebuildChats()
    }

    private func foldersToSync(_ accountID: UUID) -> [Mailbox] {
        let list = mailboxes[accountID] ?? []
        var result: [Mailbox] = []
        for role in [MailboxRole.inbox, .sent, .archive, .all] {
            if let mailbox = list.first(where: { $0.role == role }) { result.append(mailbox) }
        }
        // Folders the user has opened before.
        for mailbox in list where messages[mailbox.id] != nil && !result.contains(mailbox) {
            result.append(mailbox)
        }
        return result
    }

    private func syncFolder(_ mailbox: Mailbox, account: Account, client: IMAPClient) async throws {
        guard !syncingFolders.contains(mailbox.id) else { return }
        syncingFolders.insert(mailbox.id)
        defer { syncingFolders.remove(mailbox.id) }

        let info = try await client.select(mailbox.path)
        let window = max(50, settings.messagesPerFolder)
        var current = messages[mailbox.id] ?? []
        let accountID = account.id
        let path = mailbox.path

        func summarize(_ fetched: [FetchedMessage]) async -> [MessageSummary] {
            await Task.detached(priority: .userInitiated) {
                fetched.map { MessageSummary(fetched: $0, accountID: accountID, mailboxPath: path) }
            }.value
        }

        if folderStates[mailbox.id]?.uidValidity != info.uidValidity || current.isEmpty {
            current = []
            if info.exists > 0 {
                let lower = max(1, info.exists - window + 1)
                current = await summarize(try await client.fetchSummaries(in: path, sequenceRange: lower...info.exists))
            }
        } else {
            let highest = current.map(\.uid).max() ?? 0
            let lowest = current.map(\.uid).min() ?? 0
            if info.uidNext.map({ $0 > highest + 1 }) ?? true {
                let fresh = try await client.fetchSummaries(in: path, fromUID: highest + 1)
                current.append(contentsOf: await summarize(fresh.filter { $0.uid > highest }))
            }
            if lowest > 0 {
                let flags = try await client.fetchFlags(in: path, uidRange: lowest...highest)
                current = current.compactMap { summary in
                    if summary.uid > highest { return summary }
                    guard let updated = flags[summary.uid] else { return nil } // deleted on the server
                    var copy = summary
                    copy.apply(flags: updated)
                    return copy
                }
            }
        }

        current.sort { $0.date > $1.date }
        setMessages(current, for: mailbox.id)
        folderStates[mailbox.id] = FolderState(uidValidity: info.uidValidity, exists: info.exists, lastSync: Date())
    }

    func loadOlder(in mailboxID: String) async {
        guard let mailbox = mailbox(id: mailboxID), let account = account(mailbox.accountID) else { return }
        let client = clientPair(for: account).interactive
        do {
            let info = try await client.select(mailbox.path)
            let current = messages[mailboxID] ?? []
            let upper = info.exists - current.count
            guard upper >= 1 else { return }
            let lower = max(1, upper - settings.messagesPerFolder + 1)
            let lowestUID = current.map(\.uid).min() ?? .max
            let fetched = try await client.fetchSummaries(in: mailbox.path, sequenceRange: lower...upper)
            let accountID = account.id, path = mailbox.path
            let older = await Task.detached {
                fetched.filter { $0.uid < lowestUID }.map { MessageSummary(fetched: $0, accountID: accountID, mailboxPath: path) }
            }.value
            setMessages((current + older).sorted { $0.date > $1.date }, for: mailboxID)
            folderStates[mailboxID]?.exists = info.exists
            rebuildChats()
            scheduleSave(account.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Searches the server (beyond the locally cached window) and returns up to 100 newest matches per folder.
    func searchOnServer(_ item: SidebarItem, query: String) async -> [MessageSummary] {
        let targets: [Mailbox]
        switch item {
        case .chat, .newMessage: return []
        case .mailbox(let id): targets = mailbox(id: id).map { [$0] } ?? []
        }
        var results: [MessageSummary] = []
        for mailbox in targets {
            guard let account = account(mailbox.accountID) else { continue }
            let client = clientPair(for: account).interactive
            do {
                let uids = try await client.search(in: mailbox.path, text: query)
                let fetched = try await client.fetchSummaries(in: mailbox.path, uids: Array(uids.sorted().suffix(100)))
                let accountID = account.id, path = mailbox.path
                let summaries = await Task.detached {
                    fetched.map { MessageSummary(fetched: $0, accountID: accountID, mailboxPath: path) }
                }.value
                for summary in summaries where summaryIndex[summary.id] == nil { summaryIndex[summary.id] = summary }
                results.append(contentsOf: summaries)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return results.sorted { $0.date > $1.date }
    }

    // MARK: - Reading

    func loadMessage(_ summary: MessageSummary) async throws -> ParsedMessage {
        if let cached = parsedCache[summary.id] { return cached }
        let data: Data
        if let pending = pendingBodies[summary.id] {
            data = pending
        } else {
            let validity = folderStates[Mailbox.makeID(accountID: summary.accountID, path: summary.mailboxPath)]?.uidValidity ?? 0
            if let disk = await Task.detached(operation: { Persistence.loadBody(summary, uidValidity: validity) }).value {
                data = disk
            } else {
                guard let account = account(summary.accountID) else { throw MailError.invalidConfiguration("Account not found.") }
                let fetched = try await clientPair(for: account).interactive.fetchRawMessages(in: summary.mailboxPath, uids: [summary.uid])
                guard let raw = fetched[summary.uid] else {
                    throw MailError.commandFailed("This message is no longer on the server.")
                }
                data = raw
                Task.detached(priority: .utility) { Persistence.saveBody(raw, for: summary, uidValidity: validity) }
            }
        }
        let parsed = await Task.detached(priority: .userInitiated) { ParsedMessage(data: data) }.value
        parsedCache[summary.id] = parsed
        parsedCacheOrder.append(summary.id)
        if parsedCacheOrder.count > 60 {
            parsedCache[parsedCacheOrder.removeFirst()] = nil
        }
        return parsed
    }

    // MARK: - Actions

    func setRead(_ summaries: [MessageSummary], read: Bool) {
        let targets = summaries.filter { $0.isSeen != read && !isPending($0) }
        guard !targets.isEmpty else { return }
        mutate(targets) { $0.isSeen = read }
        rebuildChats()
        perform(on: targets) { client, path, uids in
            try await client.setFlags(["\\Seen"], add: read, uids: uids, in: path)
        }
    }

    func setFlagged(_ summaries: [MessageSummary], flagged: Bool) {
        let targets = summaries.filter { $0.isFlagged != flagged && !isPending($0) }
        guard !targets.isEmpty else { return }
        mutate(targets) { $0.isFlagged = flagged }
        perform(on: targets) { client, path, uids in
            try await client.setFlags(["\\Flagged"], add: flagged, uids: uids, in: path)
        }
    }

    func archive(_ summaries: [MessageSummary]) {
        for (accountID, group) in Dictionary(grouping: summaries.filter { !isPending($0) }, by: \.accountID) {
            guard let destination = mailbox(role: .archive, accountID: accountID) ?? mailbox(role: .all, accountID: accountID) else {
                errorMessage = "This account has no Archive folder."
                continue
            }
            move(group.filter { $0.mailboxPath != destination.path }, to: destination)
        }
    }

    func delete(_ summaries: [MessageSummary]) {
        for (accountID, group) in Dictionary(grouping: summaries.filter { !isPending($0) }, by: \.accountID) {
            guard let trash = mailbox(role: .trash, accountID: accountID) else {
                errorMessage = "This account has no Trash folder."
                continue
            }
            let inTrash = group.filter { $0.mailboxPath == trash.path }
            if !inTrash.isEmpty {
                remove(inTrash)
                perform(on: inTrash) { client, path, uids in try await client.expunge(uids: uids, in: path) }
            }
            move(group.filter { $0.mailboxPath != trash.path }, to: trash)
        }
    }

    func move(_ summaries: [MessageSummary], to destination: Mailbox) {
        let targets = summaries.filter { $0.accountID == destination.accountID && !isPending($0) }
        guard !targets.isEmpty else { return }
        remove(targets)
        perform(on: targets) { client, path, uids in
            try await client.move(uids: uids, from: path, to: destination.path)
        }
    }

    private func remove(_ summaries: [MessageSummary]) {
        let ids = Set(summaries.map(\.id))
        for mailboxID in Set(summaries.map { Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath) }) {
            setMessages((messages[mailboxID] ?? []).filter { !ids.contains($0.id) }, for: mailboxID)
            folderStates[mailboxID]?.exists -= summaries.filter { Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath) == mailboxID }.count
        }
        rebuildChats()
        for accountID in Set(summaries.map(\.accountID)) { scheduleSave(accountID) }
    }

    private func mutate(_ summaries: [MessageSummary], _ change: (inout MessageSummary) -> Void) {
        let ids = Set(summaries.map(\.id))
        for mailboxID in Set(summaries.map { Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath) }) {
            var list = messages[mailboxID] ?? []
            for index in list.indices where ids.contains(list[index].id) { change(&list[index]) }
            setMessages(list, for: mailboxID)
        }
        // Search results that aren't part of a cached folder window.
        for id in ids where summaryIndex[id] != nil && !(messages[Mailbox.makeID(accountID: summaryIndex[id]!.accountID, path: summaryIndex[id]!.mailboxPath)]?.contains { $0.id == id } ?? false) {
            change(&summaryIndex[id]!)
        }
        for accountID in Set(summaries.map(\.accountID)) { scheduleSave(accountID) }
    }

    /// Runs a server operation per (account, folder) group in the background, reporting failures.
    private func perform(on summaries: [MessageSummary],
                         _ operation: @escaping @Sendable (IMAPClient, String, [UInt32]) async throws -> Void) {
        let groups = Dictionary(grouping: summaries) { Mailbox.makeID(accountID: $0.accountID, path: $0.mailboxPath) }
        for (_, group) in groups {
            guard let first = group.first, let account = account(first.accountID) else { continue }
            let client = clientPair(for: account).interactive
            let path = first.mailboxPath
            let uids = group.map(\.uid)
            Task {
                do {
                    try await operation(client, path, uids)
                } catch {
                    self.errorMessage = error.localizedDescription
                    await self.sync(accountID: account.id)
                }
            }
        }
    }

    // MARK: - Sending

    @discardableResult
    func send(_ message: OutgoingMessage, account: Account, replyingTo original: MessageSummary?) async throws -> String {
        let (data, messageID) = message.render()
        let smtp = SMTPClient(endpoint: account.smtp, authProvider: authProvider(for: account))
        try await smtp.send(data, from: message.from.email, to: message.envelopeRecipients)

        // Show the message right away; it is replaced by the server copy on the next sync.
        let sentMailbox = mailbox(role: .sent, accountID: account.id)
        let pending = MessageSummary(
            id: "pending|\(messageID)", accountID: account.id, mailboxPath: sentMailbox?.path ?? "", uid: 0,
            messageID: messageID, inReplyTo: message.inReplyTo, references: message.references,
            subject: message.subject, from: [message.from], to: message.to, cc: message.cc, date: Date(),
            isSeen: true, isFlagged: false, snippet: String(message.body.prefix(200)),
            hasAttachments: !message.attachments.isEmpty, isAutomated: false
        )
        pendingSent.append(pending)
        pendingBodies[pending.id] = data
        summaryIndex[pending.id] = pending
        chatContents[pending.id] = ChatContent(text: QuoteStripper.strip(message.body), attachmentNames: message.attachments.map(\.filename))

        if let original, !isPending(original) {
            mutate([original]) { $0.isAnswered = true }
            perform(on: [original]) { client, path, uids in
                try await client.setFlags(["\\Answered"], add: true, uids: uids, in: path)
            }
        }
        rebuildChats()

        let client = clientPair(for: account).interactive
        let saveCopy = account.saveSentCopy
        Task {
            if saveCopy, let sentMailbox {
                do {
                    try await client.append(data, to: sentMailbox.path, flags: ["\\Seen"])
                } catch {
                    self.errorMessage = "Sent, but couldn't save a copy to Sent: \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(for: .seconds(3))
            if let sentMailbox {
                try? await self.syncFolder(sentMailbox, account: account, client: client)
                self.rebuildChats()
                self.scheduleSave(account.id)
            }
        }
        return pending.id
    }

    // MARK: - Accounts

    /// Connects to both servers with the given credentials. Throws a user-facing error on failure.
    func verify(_ account: Account, secret: AccountSecret) async throws {
        if accounts.contains(where: { $0.email.caseInsensitiveCompare(account.email) == .orderedSame }) {
            throw MailError.invalidConfiguration("\(account.email) is already added.")
        }
        try await credentials.save(secret, for: account.id)
        let provider = authProvider(for: account)
        let imap = IMAPClient(endpoint: account.imap, authProvider: provider)
        do {
            try await imap.connect()
            await imap.disconnect()
        } catch {
            await credentials.delete(accountID: account.id)
            throw Self.describe(error, server: "incoming mail (IMAP)")
        }
        do {
            try await SMTPClient(endpoint: account.smtp, authProvider: provider).verify()
        } catch {
            await credentials.delete(accountID: account.id)
            throw Self.describe(error, server: "outgoing mail (SMTP)")
        }
    }

    /// Stores fresh tokens after the user signed in again, then reconnects.
    func updateSignIn(for accountID: UUID, tokens: OAuthTokens) async throws {
        guard let account = account(accountID) else { return }
        if let email = tokens.email, email.caseInsensitiveCompare(account.email) != .orderedSame {
            throw MailError.oauth("You signed in as \(email), but this account is \(account.email).")
        }
        try await credentials.save(.oauth(tokens), for: accountID)
        accountsNeedingSignIn.remove(accountID)
        accountErrors[accountID] = nil
        dropClients(for: accountID)
        Task { await sync(accountID: accountID) }
    }

    private static func requiresSignIn(_ error: Error, account: Account) -> Bool {
        guard let mailError = error as? MailError else { return false }
        switch mailError {
        case .signInRequired: return true
        case .authenticationFailed: return account.authKind == .oauth
        default: return false
        }
    }

    func addAccount(_ account: Account, secret: AccountSecret) async throws {
        var account = account
        account.colorIndex = (accounts.map(\.colorIndex).max() ?? -1) + 1
        try await credentials.save(secret, for: account.id)
        accounts.append(account)
        Persistence.saveAccounts(accounts)
        Task { await sync(accountID: account.id) }
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let old = accounts[index]
        accounts[index] = account
        Persistence.saveAccounts(accounts)
        if old.imap != account.imap || old.smtp != account.smtp || old.username != account.username {
            dropClients(for: account.id)
            Task { await sync(accountID: account.id) }
        } else {
            rebuildChats()
        }
    }

    func removeAccount(_ accountID: UUID) {
        dropClients(for: accountID)
        accounts.removeAll { $0.id == accountID }
        Persistence.saveAccounts(accounts)
        for mailbox in mailboxes[accountID] ?? [] {
            setMessages([], for: mailbox.id)
            messages[mailbox.id] = nil
            folderStates[mailbox.id] = nil
        }
        mailboxes[accountID] = nil
        accountErrors[accountID] = nil
        accountsNeedingSignIn.remove(accountID)
        Task {
            await credentials.delete(accountID: accountID)
            await Task.detached { Persistence.deleteData(for: accountID) }.value
        }
        rebuildChats()
    }

    func authProvider(for account: Account) -> MailAuthProvider {
        let credentials = self.credentials
        let oauth = account.provider.oauthProvider.flatMap { OAuthClients.configuration(for: $0) }
        return { try await credentials.auth(for: account, oauth: oauth) }
    }

    private func clientPair(for account: Account) -> (sync: IMAPClient, interactive: IMAPClient) {
        if let existing = clients[account.id] { return existing }
        let provider = authProvider(for: account)
        let pair = (
            sync: IMAPClient(endpoint: account.imap, authProvider: provider),
            interactive: IMAPClient(endpoint: account.imap, authProvider: provider)
        )
        clients[account.id] = pair
        return pair
    }

    /// Keeps a dedicated connection in IMAP IDLE on the inbox so new mail shows up right away.
    private func startIdle(for account: Account) {
        guard idleTasks[account.id] == nil else { return }
        let client = IMAPClient(endpoint: account.imap, authProvider: authProvider(for: account))
        let accountID = account.id
        let task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let inbox = self.mailbox(role: .inbox, accountID: accountID) else { return }
                do {
                    let changed = try await client.idle(in: inbox.path, timeout: 9 * 60)
                    failures = 0
                    if changed, !Task.isCancelled { await self.syncInbox(accountID) }
                } catch MailError.commandFailed {
                    return // No IDLE support; the refresh timer covers it.
                } catch {
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(300, 15 * failures)))
                }
            }
        }
        idleTasks[account.id] = (task, client)
    }

    private func syncInbox(_ accountID: UUID) async {
        guard let account = account(accountID), let inbox = mailbox(role: .inbox, accountID: accountID) else { return }
        do {
            try await syncFolder(inbox, account: account, client: clientPair(for: account).sync)
            rebuildChats()
            scheduleSave(accountID)
        } catch {
            accountErrors[accountID] = error.localizedDescription
        }
    }

    private func dropClients(for accountID: UUID) {
        if let idle = idleTasks.removeValue(forKey: accountID) {
            idle.task.cancel()
            Task { await idle.client.abort() }
        }
        guard let pair = clients.removeValue(forKey: accountID) else { return }
        Task {
            await pair.sync.disconnect()
            await pair.interactive.disconnect()
        }
    }

    private static func describe(_ error: Error, server: String) -> Error {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return MailError.commandFailed("Couldn't connect to \(server): \(message)")
    }

    // MARK: - Storage

    private func setMessages(_ list: [MessageSummary], for mailboxID: String) {
        for old in messages[mailboxID] ?? [] { summaryIndex[old.id] = nil }
        messages[mailboxID] = list
        for summary in list { summaryIndex[summary.id] = summary }
    }

    private func scheduleSave(_ accountID: UUID) {
        saveTasks[accountID]?.cancel()
        var cache = AccountCache(mailboxes: mailboxes[accountID] ?? [])
        for mailbox in cache.mailboxes {
            if let list = messages[mailbox.id] { cache.messages[mailbox.id] = list }
            if let state = folderStates[mailbox.id] { cache.folderStates[mailbox.id] = state }
        }
        let snapshot = cache
        saveTasks[accountID] = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Persistence.saveCache(snapshot, accountID: accountID)
        }
    }

    private func updateDockBadge() {
        let unread = accounts.reduce(0) { $0 + unreadCount(forAccount: $1.id) }
        NSApp?.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
