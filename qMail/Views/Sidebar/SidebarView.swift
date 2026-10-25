import MailCore
import SwiftUI

struct SidebarView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SidebarItem?
    @Binding var showingAddAccount: Bool
    @State private var collapsedAccounts: Set<UUID> = []

    var body: some View {
        List(selection: $selection) {
            Section {
                row("Chats", systemImage: "bubble.left.and.bubble.right.fill", item: .chats, tint: .accentColor)
                if store.accounts.count > 1 {
                    row("All Inboxes", systemImage: "tray.2.fill", item: .allInboxes, tint: .blue)
                }
            }

            ForEach(store.accounts) { account in
                Section(isExpanded: expansion(for: account.id)) {
                    ForEach(store.mailboxes[account.id] ?? []) { mailbox in
                        mailboxRow(mailbox)
                    }
                    if store.mailboxes[account.id]?.isEmpty ?? true {
                        Text(store.syncingAccounts.contains(account.id) ? "Loading folders…" : "No folders")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } header: {
                    AccountHeader(account: account)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    showingAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Spacer()
                if store.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .help("Checking for new mail…")
                }
            }
            .padding(12)
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

    private func row(_ title: LocalizedStringKey, systemImage: String, item: SidebarItem, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .badge(store.unreadCount(for: item))
        .tag(item)
    }

    private func mailboxRow(_ mailbox: Mailbox) -> some View {
        let item = SidebarItem.mailbox(mailbox.id)
        let showBadge = mailbox.role == .inbox || mailbox.role == .custom || mailbox.role == .flagged
        return Label(mailbox.displayName, systemImage: mailbox.systemImage)
            .padding(.leading, CGFloat(mailbox.depth) * 14)
            .badge(showBadge ? store.unreadCount(for: item) : 0)
            .tag(item)
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccounts.contains(id) },
            set: { expanded in
                if expanded { collapsedAccounts.remove(id) } else { collapsedAccounts.insert(id) }
            }
        )
    }
}

private struct AccountHeader: View {
    @Environment(MailStore.self) private var store
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            Text(account.email)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if store.syncingAccounts.contains(account.id) {
                ProgressView()
                    .controlSize(.mini)
            } else if let error = store.accountErrors[account.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}
