import MailCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Accounts", systemImage: "at") {
                AccountsSettingsView()
            }
        }
        .frame(width: 600)
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
    }
}

private struct AccountsSettingsView: View {
    @Environment(MailStore.self) private var store
    @State private var selection: UUID?
    @State private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 8) {
                            ProviderIcon(provider: account.provider, size: 24)
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
        .onAppear { selection = selection ?? store.accounts.first?.id }
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
                TextField("Aliases", text: $aliases, prompt: Text("other@example.com, …"))
                Toggle("Save sent messages to the Sent folder", isOn: $account.saveSentCopy)
            } footer: {
                Text(account.provider.savesSentMessages
                     ? "\(account.provider.displayName) files sent messages automatically, so this is usually off."
                     : "Turn off if sent messages appear twice in Sent.")
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
        account.aliases = aliases
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        store.updateAccount(account)
    }
}
