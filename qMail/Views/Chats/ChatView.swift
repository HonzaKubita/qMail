import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// A chat laid out like a Slack channel: each email conversation is one message in the timeline,
/// and its replies live in a thread that opens on the right.
struct ChatView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let chat: Chat
    @State private var openThreadID: String?
    @State private var openWithReplyAll = false
    /// In a group chat: the email the box replies to, when it isn't the latest one.
    @State private var replyThreadID: String?
    @State private var fullMessage: MessageSummary?
    @State private var showingInfo = false
    /// Unread messages when the chat was opened. Marking read happens right away, so this keeps
    /// the "New" line and "new replies" badges stable while you look.
    @State private var unreadAtOpen: Set<String>?
    /// The chat's width with no thread open; a thread opens at half of it.
    @State private var chatWidth: CGFloat = 0
    #if DEBUG
    @State private var debugThreadSheet: ChatThread?
    #endif

    private var openThread: ChatThread? {
        openThreadID.flatMap { id in chat.threads.first { $0.id == id } }
    }

    var body: some View {
        ChatTimelineView(
            chat: chat,
            unreadAtOpen: unreadAtOpen ?? [],
            onOpenThread: { id in
                if chat.isGroup {
                    replyThreadID = id
                } else {
                    openWithReplyAll = false
                    openThreadID = id
                }
            },
            onShowEmail: { fullMessage = $0 }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chat.isAutomated {
                Label("Newsletters and notifications can't be answered here. Reply inside a thread instead.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 14)
            } else if chat.isGroup {
                // A group chat is already one conversation: the box replies to everyone.
                ChatComposer(
                    target: .group(chat, replyThreadID.flatMap { id in chat.threads.first { $0.id == id } }),
                    onClearReplyTarget: { replyThreadID = nil }
                )
            } else {
                ChatComposer(target: .chat(chat))
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            // While a thread is open the timeline is only what's left beside it.
            if openThread == nil { chatWidth = width }
        }
        .inspector(isPresented: Binding(get: { openThread != nil }, set: { if !$0 { openThreadID = nil } })) {
            Group {
                if let openThread {
                    ThreadPanel(
                        chat: chat, thread: openThread, replyAll: openWithReplyAll,
                        onClose: { openThreadID = nil }, onShowEmail: { fullMessage = $0 }
                    )
                    .id("\(openThread.id)|\(openWithReplyAll)")
                }
            }
            .inspectorColumnWidth(min: 320, ideal: max(320, chatWidth / 2), max: max(620, chatWidth * 0.7))
        }
        .navigationTitle(store.title(for: chat))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    showingInfo.toggle()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .help("Chat details")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    ChatInfoView(chat: chat)
                }
            }
        }
        .onAppear {
            if unreadAtOpen == nil {
                unreadAtOpen = Set(chat.messageIDs.filter { id in
                    store.summary(id: id).map { !$0.isSeen && !store.isFromMe($0) } ?? false
                })
            }
        }
        .task {
            // The inspector ignores being opened during the chat's first layout pass.
            try? await Task.sleep(for: .milliseconds(150))
            consumePendingThread()
        }
        .onChange(of: navigator.pendingThread?.threadID) { consumePendingThread() }
        .task(id: chat.messageIDs.count) {
            if let current = store.chat(id: chat.id) { store.markChatRead(current) }
        }
        .sheet(item: $fullMessage) { summary in
            MessageSheet(summary: summary)
        }
        #if DEBUG
        .task {
            let environment = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(1))
            if environment["QMAIL_OPEN_THREAD"] != nil {
                openThreadID = chat.threads.last { $0.replyCount > 0 }?.id
            }
            if environment["QMAIL_THREAD_SHEET"] != nil {
                // Offscreen snapshots can't draw inspector columns, but they can draw sheets.
                debugThreadSheet = chat.threads.last { $0.replyCount > 0 } ?? chat.threads.last
            }
        }
        .sheet(item: $debugThreadSheet) { thread in
            ThreadPanel(chat: chat, thread: thread, replyAll: false, onClose: { debugThreadSheet = nil }, onShowEmail: { _ in })
                .frame(width: 400, height: 720)
        }
        #endif
    }

    private var subtitle: String {
        if chat.isSelf { return store.account(chat.accountID)?.email ?? "" }
        if chat.participants.count == 1 { return chat.participants[0].email }
        return "\(chat.participants.count + 1) people"
    }

    private func consumePendingThread() {
        guard let pending = navigator.pendingThread, pending.chatID == chat.id else { return }
        navigator.pendingThread = nil
        if chat.isGroup {
            replyThreadID = pending.threadID
        } else {
            openWithReplyAll = pending.replyAll
            openThreadID = pending.threadID
        }
    }
}

// MARK: - Timeline

/// The scrolling list of a chat's threads, shared by chats and the New Message view.
struct ChatTimelineView: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    var unreadAtOpen: Set<String> = []
    let onOpenThread: (String) -> Void
    let onShowEmail: (MessageSummary) -> Void
    @State private var visibleThreads = 30
    @State private var visibleMessages = 80

    private static let bottomID = "chat-bottom"

    var body: some View {
        if chat.isGroup {
            flatBody
        } else {
            threadedBody
        }
    }

    /// Group chats: every email in order, like one long conversation. A new subject gets a heading.
    private var flatBody: some View {
        let ids = Array(chat.messageIDs.suffix(visibleMessages))
        let summaries = ids.compactMap { store.summary(id: $0) }
        var threadOf: [String: ChatThread] = [:]
        for thread in chat.threads { for id in thread.messageIDs where threadOf[id] == nil { threadOf[id] = thread } }
        let firstNewID = summaries.first { unreadAtOpen.contains($0.id) }?.id
        let calendar = Calendar.current
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if chat.messageIDs.count > visibleMessages {
                        Button("Show Earlier Messages") { visibleMessages += 80 }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        ChatIntro(chat: chat)
                    }
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        let previous = index > 0 ? summaries[index - 1] : nil
                        let thread = threadOf[summary.id]
                        let newDay = previous.map { !calendar.isDate($0.date, inSameDayAs: summary.date) } ?? true
                        let newTopic = previous.map { threadOf[$0.id]?.id != thread?.id } ?? true
                        let continues = !newDay && !newTopic && previous.map {
                            $0.sender?.normalizedEmail == summary.sender?.normalizedEmail && summary.date.timeIntervalSince($0.date) < 300
                        } ?? false
                        if newDay {
                            DateDivider(date: summary.date)
                        }
                        if summary.id == firstNewID {
                            NewDivider()
                        }
                        ChatMessageRow(
                            summary: summary, chat: chat, showSubject: newTopic, compact: continues,
                            replyLabel: "Reply",
                            onOpenThread: thread.map { thread in { onOpenThread(thread.id) } },
                            onShowEmail: onShowEmail
                        )
                        .id(summary.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messageIDs.last) {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(200))
                if let firstNewID, firstNewID != summaries.last?.id {
                    proxy.scrollTo(firstNewID, anchor: .top)
                }
            }
        }
        .task(id: "\(chat.messageIDs.count)|\(visibleMessages)") {
            await store.loadContents(for: ids)
        }
    }

    /// 1:1 chats: each email conversation is one message; replies open as a thread.
    private var threadedBody: some View {
        let threads = Array(chat.threads.suffix(visibleThreads))
        let firstNewThreadID = threads.first { $0.messageIDs.contains(where: unreadAtOpen.contains) }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if chat.threads.count > visibleThreads {
                        Button("Show Earlier Messages") {
                            visibleThreads += 30
                            Task { await store.loadChatContents(for: chat, threadLimit: visibleThreads) }
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        ChatIntro(chat: chat)
                    }
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                        if index == 0 || !Calendar.current.isDate(threads[index - 1].startDate, inSameDayAs: thread.startDate) {
                            DateDivider(date: thread.startDate)
                        }
                        if thread.id == firstNewThreadID {
                            NewDivider()
                        }
                        if let root = store.summary(id: thread.rootID) {
                            ChatMessageRow(
                                summary: root, chat: chat, thread: thread, unreadAtOpen: unreadAtOpen, showSubject: true,
                                onOpenThread: { onOpenThread(thread.id) },
                                onShowEmail: onShowEmail
                            )
                            .id(thread.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.threads.last?.messageIDs.last) {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .task {
                // Like Slack, open at the first unread message rather than the very bottom.
                try? await Task.sleep(for: .milliseconds(200))
                if let firstNewThreadID, firstNewThreadID != threads.last?.id {
                    proxy.scrollTo(firstNewThreadID, anchor: .top)
                }
            }
        }
        .task(id: chat.messageIDs.count) {
            await store.loadChatContents(for: chat, threadLimit: visibleThreads)
        }
    }
}

// MARK: - Message row

/// One message, Slack style: avatar, bold name and time, then the text.
struct ChatMessageRow: View {
    @Environment(MailStore.self) private var store
    let summary: MessageSummary
    /// The chat the row is shown in; used to say who else a message went to.
    var chat: Chat?
    var thread: ChatThread?
    var unreadAtOpen: Set<String> = []
    var showSubject = false
    /// A follow-up from the same person moments later: no avatar or name, like Slack.
    var compact = false
    var replyLabel = "Reply in thread"
    var onOpenThread: (() -> Void)?
    let onShowEmail: (MessageSummary) -> Void
    @State private var hovering = false
    @State private var expanded = false

    private static let collapsedLength = 1200

    private var text: String {
        store.chatContents[summary.id]?.text ?? QuoteStripper.cleanSnippet(summary.snippet)
    }

    private var senderName: String {
        if store.isFromMe(summary) { return store.account(summary.accountID)?.displayName ?? "Me" }
        return summary.sender?.displayName ?? "Unknown Sender"
    }

    /// "Sent to you, Bob & Carol" when a message in a 1:1 chat also went to other people.
    private var audienceLabel: String? {
        guard let chat, !chat.isGroup else { return nil }
        let mine = store.ownAddresses[summary.accountID] ?? []
        let sender = summary.sender?.normalizedEmail
        var seen = Set<String>()
        let audience = (summary.to + summary.cc).filter {
            $0.normalizedEmail != sender && seen.insert($0.normalizedEmail).inserted
        }
        let others = audience.filter { !mine.contains($0.normalizedEmail) }
        guard others.count >= (store.isFromMe(summary) ? 2 : 1) else { return nil }
        let includesMe = audience.contains { mine.contains($0.normalizedEmail) }
        let names = (includesMe ? ["you"] : []) + others.map(\.displayName)
        return "Sent to " + ListFormatter.localizedString(byJoining: names)
    }

    var body: some View {
        let current = store.summary(id: summary.id) ?? summary
        let attachments = store.chatContents[summary.id]?.attachmentNames ?? []
        HStack(alignment: .top, spacing: 10) {
            if compact {
                Text(summary.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.top, 3)
                    .opacity(hovering ? 1 : 0)
            } else {
                AvatarView(address: summary.sender, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                if !compact {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(senderName)
                            .font(.body.weight(.bold))
                            .lineLimit(1)
                        Text(summary.date, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if current.isFlagged {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if store.isPending(summary) {
                            Text("Sent")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let audienceLabel {
                    Label(audienceLabel, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .help((summary.to + summary.cc).map(\.email).joined(separator: ", "))
                }
                if showSubject, !summary.normalizedSubject.isEmpty, !text.hasPrefix(summary.normalizedSubject) {
                    Text(summary.normalizedSubject)
                        .font(.body.weight(.semibold))
                }
                messageText
                if let images = store.chatContents[summary.id]?.images, !images.isEmpty {
                    ChatImageStrip(images: images) { onShowEmail(current) }
                        .padding(.top, 2)
                }
                if !attachments.isEmpty {
                    Button { onShowEmail(current) } label: {
                        Label(attachments.count == 1 ? attachments[0] : "\(attachments.count) attachments", systemImage: "paperclip")
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.top, 2)
                }
                if let thread, thread.replyCount > 0 {
                    ThreadSummaryButton(thread: thread, unreadAtOpen: unreadAtOpen) { onOpenThread?() }
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, compact ? 2 : 8)
        .padding(.bottom, compact ? 2 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.045) : .clear)
        .contentShape(.rect)
        .overlay(alignment: .topTrailing) {
            if hovering {
                MessageHoverActions(summary: current, text: text, replyLabel: replyLabel, onOpenThread: onOpenThread, onShowEmail: { onShowEmail(current) })
                    .offset(y: -12)
                    .padding(.trailing, 18)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            MessageMenuItems(summary: current, text: text, replyLabel: replyLabel, onOpenThread: onOpenThread, onShowEmail: { onShowEmail(current) })
        }
    }

    @ViewBuilder
    private var messageText: some View {
        let isLong = text.count > Self.collapsedLength
        let display = expanded || !isLong ? text : String(text.prefix(Self.collapsedLength)) + "…"
        let content = store.chatContents[summary.id]
        if display.isEmpty && content == nil {
            Text("Loading…")
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
        } else if display.isEmpty {
            // Loaded but nothing of its own besides quotes — e.g. a reply that only adds an attachment.
            if content?.images.isEmpty ?? true, content?.attachmentNames.isEmpty ?? true {
                Text("No message text")
                    .italic()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(LinkText.attributed(display))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isLong && !expanded {
            Button("Show more") { expanded = true }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// "3 replies · Last reply 2 hours ago" under a message; opens the thread.
private struct ThreadSummaryButton: View {
    @Environment(MailStore.self) private var store
    let thread: ChatThread
    let unreadAtOpen: Set<String>
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let replies = thread.replyIDs.compactMap { store.summary(id: $0) }
        var seen = Set<String>()
        let repliers = replies.compactMap(\.sender).filter { seen.insert($0.normalizedEmail).inserted }
        let newCount = thread.replyIDs.filter { unreadAtOpen.contains($0) }.count
        let latest = replies.max { $0.date < $1.date }
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: -8) {
                    ForEach(Array(repliers.prefix(3))) { person in
                        AvatarView(address: person, size: 28)
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                        if newCount > 0 {
                            Text("\(newCount) new")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: .capsule)
                        }
                        Text(latest.map { $0.date.formatted(.relative(presentation: .named)) } ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let latest, let preview = preview(of: latest) {
                        Text("\(Text(latest.sender?.shortName ?? "").fontWeight(.medium)): \(preview)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 560, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(newCount > 0 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("View thread")
        .padding(.top, 2)
    }

    /// The first line of the latest reply, or what it sent if it has no text.
    private func preview(of summary: MessageSummary) -> String? {
        let content = store.chatContents[summary.id]
        let text = content?.text ?? QuoteStripper.cleanSnippet(summary.snippet)
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !line.isEmpty { return line }
        if let images = content?.images, !images.isEmpty {
            return images.count == 1 ? String(localized: "Photo") : String(localized: "\(images.count) photos")
        }
        return content?.attachmentNames.first
    }
}

/// Floating Liquid Glass toolbar shown when hovering a message.
private struct MessageHoverActions: View {
    @Environment(MailStore.self) private var store
    let summary: MessageSummary
    let text: String
    let replyLabel: String
    let onOpenThread: (() -> Void)?
    let onShowEmail: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let onOpenThread {
                action("arrowshape.turn.up.left", help: replyLabel, perform: onOpenThread)
            }
            action("envelope.open", help: "View email", perform: onShowEmail)
            action(summary.isFlagged ? "flag.fill" : "flag", help: summary.isFlagged ? "Unflag" : "Flag") {
                store.setFlagged([summary], flagged: !summary.isFlagged)
            }
            Menu {
                MessageMenuItems(summary: summary, text: text, replyLabel: replyLabel, onOpenThread: onOpenThread, onShowEmail: onShowEmail)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("More")
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func action(_ icon: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct MessageMenuItems: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let summary: MessageSummary
    let text: String
    let replyLabel: String
    let onOpenThread: (() -> Void)?
    let onShowEmail: () -> Void

    var body: some View {
        if let onOpenThread {
            Button(replyLabel, action: onOpenThread)
        }
        Button("View Email", action: onShowEmail)
        if !store.isPending(summary) {
            Button("Forward…") {
                Task { await navigator.forward(summary, store: store) }
            }
        }
        Button(summary.isFlagged ? "Unflag" : "Flag") { store.setFlagged([summary], flagged: !summary.isFlagged) }
        if !store.isFromMe(summary) {
            Button(summary.isSeen ? "Mark as Unread" : "Mark as Read") { store.setRead([summary], read: !summary.isSeen) }
        }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Divider()
        Button("Delete Email", role: .destructive) { store.delete([summary]) }
    }
}

// MARK: - Timeline decorations

private struct DateDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(DateText.divider(date))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private struct NewDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red).frame(height: 1)
            Text("New")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }
}

/// Shown above the first message, like the start of a Slack conversation.
private struct ChatIntro: View {
    @Environment(MailStore.self) private var store
    let chat: Chat

    var body: some View {
        let account = store.account(chat.accountID)
        VStack(alignment: .leading, spacing: 10) {
            GroupAvatarView(participants: chat.isSelf ? (account.map { [$0.address] } ?? []) : chat.participants, size: 64)
            Text(store.title(for: chat))
                .font(.title.bold())
            Text(introText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    private var introText: String {
        let names = ListFormatter.localizedString(byJoining: chat.participants.map(\.shortName))
        if chat.isSelf { return "Your own space. Emails you send only to yourself land here." }
        if chat.isAutomated { return "Newsletters and notifications from \(names) collect here." }
        if chat.isGroup {
            return "The start of your group conversation with \(names). Every email between all of you appears here in order, like one conversation."
        }
        return "The start of your direct messages with \(names). Emails between you two land here — including ones that also went to other people, until someone replies to everyone."
    }
}

// MARK: - Thread panel

/// The open thread, shown in the inspector on the right.
struct ThreadPanel: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    let thread: ChatThread
    /// Start with "Reply to everyone" selected (e.g. after Reply All in a folder).
    var replyAll: Bool
    let onClose: () -> Void
    let onShowEmail: (MessageSummary) -> Void

    private static let bottomID = "thread-bottom"

    /// In a 1:1 chat, everyone on the latest email — offered as "Reply to everyone".
    private var replyAllPeople: [MailAddress] {
        guard !chat.isGroup, let last = thread.messageIDs.last.flatMap({ store.summary(id: $0) }) else { return [] }
        let everyone = store.audience(of: last)
        return everyone.count > max(1, chat.participants.count) ? everyone : []
    }

    var body: some View {
        let replies = thread.replyIDs.compactMap { store.summary(id: $0) }
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thread")
                        .font(.headline)
                    Text(thread.subject.isEmpty ? store.title(for: chat) : thread.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .help("Close thread")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let root = store.summary(id: thread.rootID) {
                            ChatMessageRow(summary: root, chat: chat, showSubject: true, onShowEmail: onShowEmail)
                        }
                        if !replies.isEmpty {
                            HStack(spacing: 8) {
                                Text(replies.count == 1 ? "1 reply" : "\(replies.count) replies")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Rectangle().fill(.separator).frame(height: 1)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                        }
                        ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                            let previous = index > 0 ? replies[index - 1] : nil
                            let continues = previous.map {
                                $0.sender?.normalizedEmail == reply.sender?.normalizedEmail && reply.date.timeIntervalSince($0.date) < 300
                            } ?? false
                            ChatMessageRow(summary: reply, chat: chat, compact: continues, onShowEmail: onShowEmail)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                    .padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.messageIDs.count) {
                    withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            ChatComposer(target: .thread(chat, thread), replyAllPeople: replyAllPeople, replyAll: replyAll)
        }
        .task(id: thread.messageIDs.count) {
            await store.loadContents(for: thread.messageIDs)
        }
    }
}

// MARK: - Details and full email

/// Participants and per-chat settings.
struct ChatInfoView: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GroupAvatarView(participants: chat.participants, size: 48)
                VStack(alignment: .leading) {
                    Text(store.title(for: chat)).font(.headline)
                    Text("\(chat.messageIDs.count) emails · \(chat.threads.count) threads")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Chat name", text: $name, prompt: Text(chat.defaultTitle))
                .onSubmit { store.rename(chat, to: name) }
            if !chat.participants.isEmpty {
                Divider()
                Text("People").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.participants) { person in
                            HStack(spacing: 8) {
                                AvatarView(address: person, size: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(person.displayName).font(.callout)
                                    if person.name != nil {
                                        Text(person.email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider()
            HStack {
                Button(store.chatPreferences.pinned.contains(chat.id) ? "Unstar" : "Star") { store.togglePinned(chat) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Save Name") { store.rename(chat, to: name) }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { name = store.chatPreferences.names[chat.id] ?? "" }
    }
}

/// Full email shown from a chat message. Reply and forward continue in the main window.
struct MessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let summary: MessageSummary

    var body: some View {
        NavigationStack {
            MessageDetailView(summary: summary, showsToolbar: false)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            dismiss()
                            navigator.reply(to: summary, all: false, store: store)
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        Button {
                            dismiss()
                            navigator.reply(to: summary, all: true, store: store)
                        } label: {
                            Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                        }
                        Button {
                            dismiss()
                            Task { await navigator.forward(summary, store: store) }
                        } label: {
                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                        }
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 700)
    }
}

enum LinkText {
    /// Makes URLs and email addresses in plain text clickable.
    static func attributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: nsRange) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}

/// Inline thumbnails of the photos in a message.
private struct ChatImageStrip: View {
    let images: [ChatImage]
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(images.prefix(4)) { image in
                ChatImageThumbnail(image: image, maxHeight: images.count == 1 ? 280 : 180)
                    .onTapGesture(perform: onOpen)
                    .help(image.filename)
            }
            if images.count > 4 {
                Button("+\(images.count - 4)", action: onOpen)
                    .buttonStyle(.glass)
            }
        }
    }
}

private struct ChatImageThumbnail: View {
    let image: ChatImage
    let maxHeight: CGFloat
    @State private var nsImage: NSImage?

    var body: some View {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let height = min(maxHeight, CGFloat(image.height))
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: min(height * aspect, 420), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator, lineWidth: 0.5))
        .contentShape(.rect)
        .task(id: image.attachmentID) { nsImage = NSImage(data: image.data) }
    }
}
