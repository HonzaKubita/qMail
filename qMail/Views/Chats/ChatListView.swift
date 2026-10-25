import MailCore
import SwiftUI

enum ChatFilter: String, CaseIterable, Identifiable {
    case all, groups, people, unread

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .groups: "Groups"
        case .people: "People"
        case .unread: "Unread"
        }
    }
}

struct ChatListView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: Chat.ID?
    let searchText: String
    @State private var filter: ChatFilter = .all
    @State private var renaming: Chat?
    @State private var newName = ""

    private var chats: [Chat] {
        var list = store.visibleChats
        switch filter {
        case .all: break
        case .groups: list = list.filter(\.isGroup)
        case .people: list = list.filter { !$0.isGroup }
        case .unread: list = list.filter { $0.unreadCount > 0 || $0.id == selection }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { chat in
            store.title(for: chat).localizedCaseInsensitiveContains(query)
                || chat.subjects.contains { $0.localizedCaseInsensitiveContains(query) }
                || chat.participants.contains {
                    $0.displayName.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query)
                }
                || chat.messageIDs.contains { id in
                    (store.chatContents[id]?.text ?? store.summary(id: id)?.snippet ?? "").localizedCaseInsensitiveContains(query)
                }
        }
    }

    var body: some View {
        let chats = chats
        List(selection: $selection) {
            ForEach(chats) { chat in
                ChatRow(chat: chat)
                    .tag(chat.id)
                    .contextMenu { contextMenu(for: chat) }
                    .swipeActions(edge: .leading) {
                        Button {
                            store.togglePinned(chat)
                        } label: {
                            Label("Pin", systemImage: store.chatPreferences.pinned.contains(chat.id) ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            store.markChatRead(chat)
                        } label: {
                            Label("Read", systemImage: "envelope.open")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            ChatFilterBar(filter: $filter)
        }
        .overlay {
            if chats.isEmpty { emptyState }
        }
        .navigationTitle("Chats")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: "compose", value: ComposeRequest())
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message")
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming { store.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave empty to use the participants' names.")
        }
    }

    private var subtitle: String {
        let unread = store.unreadCount(for: .chats)
        return unread > 0 ? "\(unread) unread" : "\(store.visibleChats.count) conversations"
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if store.isSyncing && store.chats.isEmpty {
            ContentUnavailableView {
                Label("Loading Conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your email threads are being grouped into chats.")
            }
        } else {
            ContentUnavailableView {
                Label(filter == .unread ? "No Unread Chats" : "No Chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Conversations with real people show up here, grouped by who's in them. Newsletters and notifications stay in your inbox.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for chat: Chat) -> some View {
        Button(store.chatPreferences.pinned.contains(chat.id) ? "Unpin" : "Pin") { store.togglePinned(chat) }
        Button("Rename…") {
            newName = store.chatPreferences.names[chat.id] ?? ""
            renaming = chat
        }
        Button("Mark as Read") { store.markChatRead(chat) }
            .disabled(chat.unreadCount == 0)
        Button("New Email to Everyone") {
            openWindow(id: "compose", value: ComposeRequest(accountID: chat.accountID, to: chat.participants.map(\.email)))
        }
        Divider()
        Button("Hide Chat", role: .destructive) {
            if selection == chat.id { selection = nil }
            store.hide(chat)
        }
    }
}

/// Liquid Glass filter chips that morph between selections.
struct ChatFilterBar: View {
    @Binding var filter: ChatFilter
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ChatFilter.allCases) { option in
                    Button {
                        withAnimation(.snappy) { filter = option }
                    } label: {
                        Text(option.title)
                            .font(.callout.weight(filter == option ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(filter == option ? Color.white : Color.primary)
                    .glassEffect(
                        filter == option ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .glassEffectID(option, in: namespace)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ChatRow: View {
    @Environment(MailStore.self) private var store
    let chat: Chat

    var body: some View {
        let last = store.summary(id: chat.lastMessageID)
        let isUnread = chat.unreadCount > 0
        HStack(spacing: 11) {
            GroupAvatarView(participants: chat.participants, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if store.chatPreferences.pinned.contains(chat.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(store.title(for: chat))
                        .font(.headline)
                        .fontWeight(isUnread ? .semibold : .medium)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(DateText.short(chat.lastDate))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(isUnread ? Color.accentColor : Color.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(preview(for: last))
                        .font(.subheadline)
                        .foregroundStyle(isUnread ? .primary : .secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if isUnread {
                        Text("\(chat.unreadCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: .capsule)
                    }
                }
                if let subject = chat.subjects.first {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                        Text(subject)
                        if chat.subjects.count > 1 {
                            Text("+\(chat.subjects.count - 1)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func preview(for last: MessageSummary?) -> String {
        guard let last else { return "" }
        let text = (store.chatContents[last.id]?.text ?? QuoteStripper.cleanSnippet(last.snippet))
            .replacingOccurrences(of: "\n", with: " ")
        if store.isFromMe(last) { return "You: " + text }
        if chat.isGroup, let sender = last.sender { return "\(sender.shortName): " + text }
        return text
    }
}
