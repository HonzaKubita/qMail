import AuthenticationServices
import MailCore
import SwiftUI

/// Account rail plus the selected account's chats, like a Slack workspace.
struct WorkspaceSidebar: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Binding var accountID: UUID?
    @Binding var selection: SidebarItem?
    @Binding var showingAddAccount: Bool

    var body: some View {
        HStack(spacing: 0) {
            AccountRail(accountID: $accountID, showingAddAccount: $showingAddAccount)
                .zIndex(1) // its hover labels overlap the chat list
            if let account = accountID.flatMap({ store.account($0) }) {
                ChatSidebar(account: account, selection: $selection)
                    .id(account.id)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                // While mail is loading, a spinner covers the (hidden) icon inside the same button,
                // so the button keeps its size and its place in the toolbar's glass group.
                Button {
                    guard !store.isSyncing else { return }
                    Task { await store.refreshAll() }
                } label: {
                    Label {
                        Text("Get New Mail")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                            .opacity(store.isSyncing ? 0 : 1)
                            .overlay {
                                if store.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                    }
                }
                .help(store.isSyncing ? "Getting New Mail…" : "Get New Mail")
                Button {
                    navigator.startNewMessage(accountID: accountID)
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message")
                .disabled(accountID == nil)
            }
        }
    }
}

/// Vertical strip of accounts ("workspaces") with unread badges.
private struct AccountRail: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openSettings) private var openSettings
    @Binding var accountID: UUID?
    @Binding var showingAddAccount: Bool
    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(store.accounts) { account in
                let isSelected = account.id == accountID
                Button {
                    accountID = account.id
                } label: {
                    AccountIcon(account: account, size: 32)
                        .overlay(alignment: .topTrailing) {
                            UnreadBadge(count: isSelected ? 0 : store.unreadCount(forAccount: account.id))
                                .offset(x: 7, y: -6)
                        }
                }
                .buttonStyle(RailButtonStyle(isSelected: isSelected))
                // Shown at once on hover (a tooltip takes a second), so same-looking accounts are easy to tell apart.
                .onHover { inside in
                    if inside { hovered = account.id } else if hovered == account.id { hovered = nil }
                }
                .overlay(alignment: .leading) {
                    if hovered == account.id {
                        AccountHoverLabel(account: account, unread: store.unreadCount(forAccount: account.id))
                            .offset(x: 50)
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .accessibilityLabel(account.email)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .contextMenu {
                    AccountAppearancePickers(account: account)
                    Divider()
                    Button("Get New Mail") { Task { await store.sync(accountID: account.id) } }
                    Button("Account Settings…") {
                        navigator.settingsAccountID = account.id
                        openSettings()
                    }
                }
            }
            Button {
                showingAddAccount = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(RailButtonStyle())
            .help("Add Account")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(RailButtonStyle())
            .help("Settings")
        }
        .padding(.vertical, 8)
        .frame(width: 56)
        #if DEBUG
        .onAppear {
            // QMAIL_HOVER_ACCOUNT=N shows the Nth account's hover label, for screenshots.
            if let index = ProcessInfo.processInfo.environment["QMAIL_HOVER_ACCOUNT"].flatMap(Int.init),
               store.accounts.indices.contains(index) { hovered = store.accounts[index].id }
        }
        #endif
    }
}

/// The account's address next to its icon in the rail.
private struct AccountHoverLabel: View {
    let account: Account
    let unread: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(account.email)
                .font(.callout.weight(.medium))
            if unread > 0 {
                Text("\(unread) unread")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial, in: .capsule) // keeps the list underneath from showing through
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

/// Borderless rail button that highlights on hover and shows the selected account
/// the way macOS shows an inactive sidebar selection.
private struct RailButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        RailButton(configuration: configuration, isSelected: isSelected)
    }

    private struct RailButton: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                }
                .contentShape(.rect(cornerRadius: 10))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if configuration.isPressed { return .primary.opacity(0.16) }
            if isSelected { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
            return hovering ? .primary.opacity(0.07) : .clear
        }
    }
}

/// Red count like the Dock's.
private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(.red, in: .capsule)
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
    @State private var collapsed: Set<String> = ["folders"]
    @State private var renaming: Chat?
    @State private var newName = ""

    var body: some View {
        let sections = store.chatSections(for: account.id)
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
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .badge(store.unreadCount(forAccount: account.id))
                    .tag(SidebarItem.activity)
                if selection == .newMessage {
                    Label("New message", systemImage: "square.and.pencil")
                        .tag(SidebarItem.newMessage)
                }
                chatSection("Starred", key: "starred", chats: sections.starred)
                chatSection("Group chats", key: "groups", chats: sections.groups)
                chatSection("Direct messages", key: "direct", chats: sections.direct)
                chatSection("Updates", key: "updates", chats: sections.updates)
                if sections.isEmpty {
                    Text(store.syncingAccounts.contains(account.id) ? "Loading conversations…" : "No conversations yet")
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
            if let error = store.accountErrors[account.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func chatSection(_ title: LocalizedStringKey, key: String, chats: [Chat]) -> some View {
        if !chats.isEmpty {
            Section(isExpanded: expansion(key)) {
                ForEach(chats) { chat in
                    ChatSidebarRow(chat: chat, account: account)
                        .badge(chat.isAutomated ? 0 : chat.unreadCount)
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
        }
        .help(chat.participants.map(\.email).joined(separator: ", "))
    }
}
