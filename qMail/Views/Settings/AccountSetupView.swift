import AuthenticationServices
import MailCore
import SwiftUI

struct AccountSetupView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var provider: MailProvider?
    /// Gmail can fall back to an app password instead of signing in with Google.
    @State private var useAppPassword = false
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var imapSecurity: ConnectionSecurity = .tls
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var smtpSecurity: ConnectionSecurity = .tls
    @State private var showServerSettings = false
    @State private var working = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let provider {
                if provider.oauthProvider != nil && !useAppPassword {
                    oauthPage(for: provider)
                } else {
                    details(for: provider)
                }
            } else {
                providerPicker
            }
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        #if DEBUG
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["QMAIL_SETUP_PROVIDER"], let preset = MailProvider(rawValue: raw) {
                select(preset)
            }
        }
        #endif
    }

    // MARK: - Provider picker

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an Account").font(.title2.bold())
                Text("Choose your email provider.").foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(MailProvider.allCases) { option in
                        Button {
                            select(option)
                        } label: {
                            HStack(spacing: 12) {
                                ProviderIcon(provider: option, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.displayName).font(.headline)
                                    Text(option.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .contentShape(.rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }

    // MARK: - Details

    // MARK: - Sign in with Google / Microsoft

    private func oauthPage(for provider: MailProvider) -> some View {
        let kind = provider.oauthProvider ?? .google
        let configured = OAuthClients.isConfigured(kind)
        return VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 16) {
                ProviderIcon(provider: provider, size: 72)
                Text("Add \(provider.displayName)")
                    .font(.largeTitle.bold())
                Text("You'll sign in with your \(kind.displayName) account in a secure browser window. qMail never sees your password.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
                Label("When \(kind.displayName) asks what qMail can access, make sure the box for reading and sending email is ticked.",
                      systemImage: "checkmark.square.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
                Button {
                    Task { await signInWithOAuth(provider) }
                } label: {
                    Label("Sign in with \(kind.displayName)", systemImage: "person.badge.key.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(working || !configured)
                .padding(.top, 8)

                Group {
                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status ?? "").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    } else if !configured {
                        Text("Sign in with \(kind.displayName) isn't set up in this build of qMail yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: 420, minHeight: 36)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                Button {
                    self.provider = nil
                    error = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(working)
                Spacer()
                if provider == .gmail {
                    Button("Use an App Password Instead") {
                        useAppPassword = true
                        error = nil
                    }
                    .buttonStyle(.link)
                    .disabled(working)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
        }
    }

    // MARK: - Password sign-in

    private func details(for provider: MailProvider) -> some View {
        let passwordAllowed = provider != .outlook

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderIcon(provider: provider, size: 34)
                Text(provider == .other ? "Other Mail Account" : "Add \(provider.displayName)")
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 4)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Your name, as recipients see it"))
                    TextField("Email", text: $email, prompt: Text("name@example.com"))
                }

                if passwordAllowed {
                    Section {
                        SecureField(provider == .other ? "Password" : "App Password", text: $password)
                    } header: {
                        Text(provider == .other ? "Password" : "App Password")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.passwordHelp)
                            if let url = provider.appPasswordURL {
                                Link("Create an app password ↗", destination: url)
                            }
                        }
                    }
                }

                if passwordAllowed && (provider == .other || showServerSettings) {
                    Section("Incoming Mail (IMAP)") {
                        TextField("Server", text: $imapHost, prompt: Text("imap.example.com"))
                        TextField("Port", value: $imapPort, format: .number.grouping(.never))
                        Picker("Security", selection: $imapSecurity) {
                            ForEach(ConnectionSecurity.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    Section("Outgoing Mail (SMTP)") {
                        TextField("Server", text: $smtpHost, prompt: Text("smtp.example.com"))
                        TextField("Port", value: $smtpPort, format: .number.grouping(.never))
                        Picker("Security", selection: $smtpSecurity) {
                            ForEach(ConnectionSecurity.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Username", text: $username, prompt: Text(email.isEmpty ? "Same as email" : email))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                Button {
                    if useAppPassword {
                        useAppPassword = false
                    } else {
                        self.provider = nil
                    }
                    error = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(working)
                if passwordAllowed && provider != .other {
                    Toggle("Server settings", isOn: $showServerSettings)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if passwordAllowed {
                    Button("Sign In") {
                        Task { await signInWithPassword(provider) }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !email.contains("@") || password.isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .padding(.top, 8)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            }
        }
    }

    // MARK: - Actions

    private func select(_ option: MailProvider) {
        provider = option
        useAppPassword = false
        error = nil
        if let imap = option.imap {
            imapHost = imap.host
            imapPort = imap.port
            imapSecurity = imap.security
        }
        if let smtp = option.smtp {
            smtpHost = smtp.host
            smtpPort = smtp.port
            smtpSecurity = smtp.security
        }
    }

    private func signInWithPassword(_ provider: MailProvider) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        error = nil
        defer { working = false }

        // Unknown domain without server settings yet: ask Mozilla's ISP database.
        if provider == .other && imapHost.isEmpty {
            status = "Looking up server settings…"
            if let found = await AutoDiscovery.discover(email: address) {
                imapHost = found.imap.host
                imapPort = found.imap.port
                imapSecurity = found.imap.security
                smtpHost = found.smtp.host
                smtpPort = found.smtp.port
                smtpSecurity = found.smtp.security
                if !found.usernameIsEmail, username.isEmpty {
                    username = String(address.split(separator: "@").first ?? "")
                }
            } else {
                error = "Couldn't find server settings for this domain. Please enter them below."
                return
            }
        }

        let imap = ServerEndpoint(host: imapHost.trimmingCharacters(in: .whitespaces), port: imapPort, security: imapSecurity)
        let smtp = ServerEndpoint(host: smtpHost.trimmingCharacters(in: .whitespaces), port: smtpPort, security: smtpSecurity)
        guard !imap.host.isEmpty, !smtp.host.isEmpty else {
            error = "Enter the incoming and outgoing server names."
            return
        }

        var usernames = [username.trimmingCharacters(in: .whitespaces).isEmpty ? address : username]
        // Some iCloud accounts only accept the part before the @.
        if provider == .icloud, username.isEmpty, let local = address.split(separator: "@").first {
            usernames.append(String(local))
        }

        var lastError: Error?
        for user in usernames {
            let account = Account(
                displayName: name.isEmpty ? address : name, email: address, provider: provider, imap: imap, smtp: smtp,
                username: user, authKind: .password, saveSentCopy: !provider.savesSentMessages
            )
            status = "Connecting to \(imap.host)…"
            do {
                try await store.verify(account, secret: .password(password))
                try await store.addAccount(account, secret: .password(password))
                dismiss()
                return
            } catch {
                lastError = error
            }
        }
        error = lastError?.localizedDescription
        if provider != .other { showServerSettings = true }
    }

    private func signInWithOAuth(_ provider: MailProvider) async {
        guard let kind = provider.oauthProvider, let imap = provider.imap, let smtp = provider.smtp else { return }
        working = true
        error = nil
        status = "Waiting for \(kind.displayName) sign-in…"
        defer { working = false }
        do {
            let tokens = try await OAuthSignIn.run(kind, loginHint: nil, using: webAuthenticationSession)
            guard let address = tokens.email, address.contains("@") else {
                throw MailError.oauth("Couldn't determine which email address you signed in with.")
            }
            status = "Connecting to \(provider.displayName)…"
            let account = Account(
                displayName: tokens.name ?? name, email: address, provider: provider, imap: imap, smtp: smtp,
                username: address, authKind: .oauth, saveSentCopy: !provider.savesSentMessages
            )
            try await store.verify(account, secret: .oauth(tokens))
            try await store.addAccount(account, secret: .oauth(tokens))
            dismiss()
        } catch where OAuthSignIn.isCancellation(error) {
            // The user closed the sign-in window.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ProviderIcon: View {
    let provider: MailProvider
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { glyph.foregroundStyle(.white) }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }

    @ViewBuilder
    private var glyph: some View {
        switch provider {
        case .gmail: Image(systemName: "envelope.fill").font(.system(size: size * 0.46, weight: .semibold))
        case .outlook: Image(systemName: "envelope.open.fill").font(.system(size: size * 0.46, weight: .semibold))
        case .icloud: Image(systemName: "icloud.fill").font(.system(size: size * 0.46, weight: .semibold))
        case .yahoo: Text("Y!").font(.system(size: size * 0.44, weight: .heavy, design: .rounded))
        case .fastmail: Image(systemName: "bolt.fill").font(.system(size: size * 0.46, weight: .semibold))
        case .aol: Text("Aol").font(.system(size: size * 0.34, weight: .bold, design: .rounded))
        case .other: Image(systemName: "server.rack").font(.system(size: size * 0.42, weight: .semibold))
        }
    }

    private var colors: [Color] {
        switch provider {
        case .gmail: [Color(red: 0.96, green: 0.36, blue: 0.30), Color(red: 0.82, green: 0.18, blue: 0.18)]
        case .outlook: [Color(red: 0.16, green: 0.60, blue: 0.96), Color(red: 0.04, green: 0.38, blue: 0.80)]
        case .icloud: [Color(red: 0.42, green: 0.80, blue: 1.00), Color(red: 0.16, green: 0.55, blue: 0.95)]
        case .yahoo: [Color(red: 0.55, green: 0.30, blue: 0.95), Color(red: 0.38, green: 0.10, blue: 0.80)]
        case .fastmail: [Color(red: 0.25, green: 0.45, blue: 0.95), Color(red: 0.10, green: 0.25, blue: 0.70)]
        case .aol: [Color(red: 0.25, green: 0.25, blue: 0.30), Color(red: 0.08, green: 0.08, blue: 0.12)]
        case .other: [Color(red: 0.60, green: 0.63, blue: 0.68), Color(red: 0.40, green: 0.43, blue: 0.48)]
        }
    }
}
