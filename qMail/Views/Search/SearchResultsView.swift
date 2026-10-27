import MailCore
import SwiftUI

/// Search results for the selected workspace, shown in the middle of the window right under
/// the search field: matching chats first, then every matching email from the full-mail index.
struct SearchResultsView: View {
    @Environment(MailStore.self) private var store
    let account: Account
    let query: String
    /// Opens a result (a chat, or a message in its chat) and closes the results.
    let onOpen: (SidebarItem) -> Void
    /// Matches from the index of all mail, newest first.
    @State private var messageHits: [MessageSummary] = []
    @State private var searching = true
    @State private var showAllChats = false

    private static let chatLimit = 5

    var body: some View {
        let sections = store.chatSections(for: account.id, matching: query, hits: Set(messageHits.compactMap(\.messageID)))
        let chats = sections.starred + sections.groups + sections.direct + sections.updates
        List {
            if !chats.isEmpty {
                Section {
                    ForEach(showAllChats ? chats : Array(chats.prefix(Self.chatLimit))) { chat in
                        Button {
                            onOpen(.chat(chat.id))
                        } label: {
                            SearchChatRow(chat: chat, account: account)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if chats.count > Self.chatLimit {
                        Button(showAllChats ? "Show Fewer" : "Show All \(chats.count) Chats") { showAllChats.toggle() }
                            .buttonStyle(.link)
                    }
                } header: {
                    Text("Chats")
                }
            }
            if !messageHits.isEmpty {
                Section {
                    ForEach(messageHits.prefix(100)) { summary in
                        Button {
                            onOpen(.message(summary.id))
                        } label: {
                            EmailRow(summary: summary, account: account, chatTitle: store.chatAndThread(containing: summary).map { store.title(for: $0.0) })
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(messageHits.count > 100 ? "Messages (100 newest)" : "Messages")
                }
            }
            indexNote
        }
        .listStyle(.inset)
        .overlay {
            if chats.isEmpty && messageHits.isEmpty && !searching {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(account.email)
        .task(id: "\(account.id)|\(query)") {
            searching = true
            showAllChats = false
            try? await Task.sleep(for: .milliseconds(200)) // wait for typing to pause
            guard !Task.isCancelled else { return }
            let results = await store.searchAllMail(query, accountID: account.id)
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            messageHits = results.filter { seen.insert($0.messageID ?? $0.id).inserted }
            searching = false
        }
    }

    /// Why some old mail may be missing from the results.
    @ViewBuilder
    private var indexNote: some View {
        let status = store.indexStatus[account.id]
        if let status, !status.isComplete, status.total > 0 {
            Label {
                Text("Downloading mail for search: \(status.withText.formatted()) of \(status.total.formatted())")
            } icon: {
                ProgressView(value: Double(status.withText), total: Double(max(status.total, 1)))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
        } else if status == nil, !store.settings.downloadAllMail {
            Text("Search covers recent mail. Turn on “Download all mail for search” in Settings to search everything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
    }
}

/// A chat found by search: its people, name and when it was last active.
private struct SearchChatRow: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatarView(participants: chat.isSelf ? [account.address] : chat.participants, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title(for: chat))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(chat.isGroup ? "\(chat.participants.count + 1) people" : chat.participants.first?.email ?? account.email)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(DateText.short(chat.lastDate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
