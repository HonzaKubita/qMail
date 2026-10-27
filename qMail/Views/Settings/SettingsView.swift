import MailCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppNavigator.self) private var navigator
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettingsView()
            }
            Tab("Accounts", systemImage: "at", value: "accounts") {
                AccountsSettingsView()
            }
        }
        .frame(width: 600)
        // "Account Settings…" in an account's menu opens straight to that account.
        .onAppear { if navigator.settingsAccountID != nil { tab = "accounts" } }
        .onChange(of: navigator.settingsAccountID) { _, id in
            if id != nil { tab = "accounts" }
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Mail") {
                Picker("Check for new mail", selection: $settings.refreshMinutes) {
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                }
                Picker("Messages to keep per folder", selection: $settings.messagesPerFolder) {
                    Text("100").tag(100)
                    Text("250").tag(250)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                }
                Toggle("Load remote images automatically", isOn: $settings.loadRemoteContent)
            }
            Section {
                Toggle("Download all mail for search", isOn: $settings.downloadAllMail)
                    .onChange(of: settings.downloadAllMail) { store.updateIndexing() }
                ForEach(store.accounts) { account in
                    if let status = store.indexStatus[account.id], status.total > 0 {
                        IndexStatusRow(account: account, status: status)
                    }
                }
            } header: {
                Text("Search")
            } footer: {
                Text("Downloads the text of every email (not attachments) in the background, so search covers your whole mailbox, not just recent mail. Search ignores accents, so “zamestnanec” finds “zaměstnanec”.")
            }
            Section {
                LabeledContent("Hidden chats") {
                    Button("Show All (\(store.chatPreferences.hidden.count))") { store.unhideAllChats() }
                        .disabled(store.chatPreferences.hidden.isEmpty)
                }
            } header: {
                Text("Chats")
            } footer: {
                Text("Every email lives in a chat with the people on it. Replies to an email collect in its thread, and a different group of people gets its own chat.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 380)
        .task { await store.refreshIndexStatus() }
    }
}

/// Download progress of one account's search index.
private struct IndexStatusRow: View {
    let account: Account
    let status: IndexStatus

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                if status.isComplete {
                    Text("\(status.total.formatted()) messages")
                } else {
                    ProgressView(value: Double(status.withText), total: Double(status.total))
                        .frame(width: 160)
                    Text("\(status.withText.formatted()) of \(status.total.formatted())\(status.isRunning ? "" : " · paused")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 8) {
                AccountIcon(account: account, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.email)
                    Text(ByteCountFormatter.string(fromByteCount: Persistence.searchIndexSize(account.id), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AccountsSettingsView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: UUID?
    @State private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 8) {
                            AccountIcon(account: account, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(account.displayName).lineLimit(1)
                                Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(account.id)
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Account")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 210)
            Divider()
            Group {
                if let id = selection, let account = store.account(id) {
                    AccountDetailForm(account: account)
                        .id(account.id)
                } else {
                    ContentUnavailableView("No Account Selected", systemImage: "at")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 440)
        .sheet(isPresented: $showingAdd) { AccountSetupView() }
        .onAppear { selection = navigator.settingsAccountID ?? selection ?? store.accounts.first?.id }
        .onChange(of: navigator.settingsAccountID) { _, id in
            if let id { selection = id }
        }
    }
}

private struct AccountDetailForm: View {
    @Environment(MailStore.self) private var store
    @State var account: Account
    @State private var aliases = ""
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $account.displayName)
                LabeledContent("Email", value: account.email)
                TextField("Aliases", text: $aliases, prompt: Text(verbatim: "other@example.com, …"))
                Toggle("Save sent messages to the Sent folder", isOn: $account.saveSentCopy)
            } footer: {
                Text(account.provider.savesSentMessages
                     ? "\(account.provider.displayName) files sent messages automatically, so this is usually off."
                     : "Turn off if sent messages appear twice in Sent.")
            }
            Section("Appearance") {
                AccountAppearancePickers(account: account, inForm: true)
            }
            Section("Servers") {
                LabeledContent("Incoming", value: "\(account.imap.host):\(account.imap.port) · \(account.imap.security.label)")
                LabeledContent("Outgoing", value: "\(account.smtp.host):\(account.smtp.port) · \(account.smtp.security.label)")
                LabeledContent("Sign-in", value: account.authKind == .oauth ? "\(account.provider.oauthProvider?.displayName ?? "OAuth") account" : "Password (Keychain)")
            }
            Section {
                HStack {
                    Button("Remove Account…", role: .destructive) { confirmRemove = true }
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { aliases = account.aliases.joined(separator: ", ") }
        .confirmationDialog("Remove \(account.email)?", isPresented: $confirmRemove) {
            Button("Remove Account", role: .destructive) { store.removeAccount(account.id) }
        } message: {
            Text("Messages stay on the server. The local cache and saved password are deleted.")
        }
    }

    private func save() {
        // Color and icon apply as soon as they're picked; keep those.
        if let current = store.account(account.id) {
            account.tint = current.tint
            account.symbol = current.symbol
        }
        account.aliases = aliases
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        store.updateAccount(account)
    }
}
