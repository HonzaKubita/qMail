import AuthenticationServices
import MailCore
import SwiftUI

/// Account rail plus the selected account's chats, like a Slack workspace.
struct WorkspaceSidebar: View {
    @Environment(MailStore.self) private var store
    @Binding var accountID: UUID?
    @Binding var selection: SidebarItem?
    let searchText: String
    @Binding var showingAddAccount: Bool

    var body: some View {
        HStack(spacing: 0) {
            AccountRail(accountID: $accountID, showingAddAccount: $showingAddAccount)
            if let account = accountID.flatMap({ store.account($0) }) {
                ChatSidebar(account: account, selection: $selection, searchText: searchText)
                    .id(account.id)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Get New Mail", systemImage: "arrow.clockwise")
                }
                .help("Get New Mail")
                .disabled(store.isSyncing)
            }
        }
    }
}

/// Vertical strip of accounts ("workspaces") with unread badges.
private struct AccountRail: View {
    @Environment(MailStore.self) private var store
    @Binding var accountID: UUID?
    @Binding var showingAddAccount: Bool

    var body: some View {
        VStack(spacing: 14) {
            ForEach(store.accounts) { account in
                Button {
                    accountID = account.id
                } label: {
                    AccountTile(account: account, isSelected: account.id == accountID, unread: store.unreadCount(forAccount: account.id))
                }
                .buttonStyle(.plain)
                .help("\(account.displayName) — \(account.email)")
            }
            Button {
                showingAddAccount = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Add Account")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
        }
        .padding(.vertical, 12)
        .frame(width: 62)
    }
}

private struct AccountTile: View {
    let account: Account
    let isSelected: Bool
    let unread: Int

    private var letter: String {
        String(account.email.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ProviderIcon(provider: account.provider, size: 40)
                .overlay {
                    // The first letter tells accounts at the same provider apart.
                    Text(letter)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.35), in: Circle())
                        .offset(x: -13, y: 13)
                }
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
                }
                .opacity(isSelected ? 1 : 0.75)
            if unread > 0 && !isSelected {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
    }
}

/// The selected account's conversations, grouped like Slack's sidebar.
private struct ChatSidebar: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let account: Account
    @Binding var selection: SidebarItem?
    let searchText: String
    @State private var collapsed: Set<String> = ["folders"]
    @State private var renaming: Chat?
    @State private var newName = ""

    var body: some View {
        let sections = store.chatSections(for: account.id, matching: searchText)
        VStack(spacing: 0) {
            header
            List(selection: $selection) {
                if store.accountsNeedingSignIn.contains(account.id) {
                    Button {
                        Task { await signInAgain() }
                    } label: {
                        Label("Sign In Again…", systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .help(store.accountErrors[account.id] ?? "Your sign-in has expired.")
                }
                if selection == .newMessage {
                    Label("New message", systemImage: "square.and.pencil")
                        .tag(SidebarItem.newMessage)
                }
                chatSection("Starred", key: "starred", chats: sections.starred)
                chatSection("Group chats", key: "groups", chats: sections.groups)
                chatSection("Direct messages", key: "direct", chats: sections.direct)
                chatSection("Updates", key: "updates", chats: sections.updates)
                if sections.isEmpty {
                    Text(searchText.isEmpty ? (store.syncingAccounts.contains(account.id) ? "Loading conversations…" : "No conversations yet") : "No matches")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Section(isExpanded: expansion("folders")) {
                    ForEach(store.mailboxes[account.id] ?? []) { mailbox in
                        Label(mailbox.displayName, systemImage: mailbox.systemImage)
                            .padding(.leading, CGFloat(mailbox.depth) * 14)
                            .badge(mailbox.role == .inbox ? store.unreadCount(for: .mailbox(mailbox.id)) : 0)
                            .tag(SidebarItem.mailbox(mailbox.id))
                    }
                } header: {
                    Text("Folders")
                }
            }
            .listStyle(.sidebar)
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

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if store.syncingAccounts.contains(account.id) {
                ProgressView()
                    .controlSize(.small)
            } else if let error = store.accountErrors[account.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
            Button {
                navigator.startNewMessage(accountID: account.id)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("New Message")
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func chatSection(_ title: LocalizedStringKey, key: String, chats: [Chat]) -> some View {
        if !chats.isEmpty {
            Section(isExpanded: expansion(key)) {
                ForEach(chats) { chat in
                    ChatSidebarRow(chat: chat, account: account)
                        .tag(SidebarItem.chat(chat.id))
                        .contextMenu { contextMenu(for: chat) }
                }
            } header: {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for chat: Chat) -> some View {
        Button(store.chatPreferences.pinned.contains(chat.id) ? "Unstar" : "Star") { store.togglePinned(chat) }
        Button("Rename…") {
            newName = store.chatPreferences.names[chat.id] ?? ""
            renaming = chat
        }
        Button("Mark as Read") { store.markChatRead(chat) }
            .disabled(chat.unreadCount == 0)
        Divider()
        Button("Hide Chat", role: .destructive) {
            if selection == .chat(chat.id) { selection = nil }
            store.hide(chat)
        }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(key) },
            set: { expanded in
                if expanded { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        )
    }

    private func signInAgain() async {
        guard let provider = account.provider.oauthProvider else { return }
        do {
            let tokens = try await OAuthSignIn.run(provider, loginHint: account.email, using: webAuthenticationSession)
            try await store.updateSignIn(for: account.id, tokens: tokens)
        } catch where !OAuthSignIn.isCancellation(error) {
            store.errorMessage = error.localizedDescription
        } catch {}
    }
}

private struct ChatSidebarRow: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    let account: Account

    var body: some View {
        let isUnread = chat.unreadCount > 0
        HStack(spacing: 8) {
            GroupAvatarView(participants: chat.isSelf ? [account.address] : chat.participants, size: 22)
            Text(store.title(for: chat))
                .fontWeight(isUnread ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isUnread && !chat.isAutomated {
                Text("\(chat.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
            }
        }
        .help(chat.participants.map(\.email).joined(separator: ", "))
    }
}
