import MailCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    let request: ComposeRequest

    @State private var fromAccountID: UUID?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var showCcBcc = false
    @State private var sending = false
    @State private var error: String?
    @State private var prepared = false
    @State private var showingImporter = false
    @State private var replyTarget: MessageSummary?
    @State private var replyReferences: [String] = []
    @State private var replyMessageID: String?
    @FocusState private var focus: Field?

    enum Field { case to, subject, body }

    private var fromAccount: Account? {
        fromAccountID.flatMap { store.account($0) } ?? store.accounts.first
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if store.accounts.count > 1 {
                    HeaderRow(label: "From") {
                        Picker("From", selection: Binding(get: { fromAccount?.id }, set: { fromAccountID = $0 })) {
                            ForEach(store.accounts) { account in
                                Text("\(account.displayName) <\(account.email)>").tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                HeaderRow(label: "To") {
                    RecipientField(text: $to, contacts: store.knownContacts)
                        .focused($focus, equals: .to)
                    Button {
                        withAnimation(.snappy) { showCcBcc.toggle() }
                    } label: {
                        Text("Cc/Bcc").font(.caption)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                if showCcBcc {
                    HeaderRow(label: "Cc") { RecipientField(text: $cc, contacts: store.knownContacts) }
                    HeaderRow(label: "Bcc") { RecipientField(text: $bcc, contacts: store.knownContacts) }
                }
                HeaderRow(label: "Subject") {
                    TextField("", text: $subject)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .subject)
                }
            }
            .padding(.top, 6)

            TextEditor(text: $messageBody)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focus, equals: .body)

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { attachment in
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: attachment.mimeType) ?? .data))
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                    Text(attachment.filename).lineLimit(1)
                                    Text(Int64(attachment.data.count), format: .byteCount(style: .file)).foregroundStyle(.secondary)
                                    Button {
                                        attachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .navigationTitle(subject.isEmpty ? "New Message" : subject)
        .toolbar {
            ToolbarItem {
                Button {
                    showingImporter = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .help("Attach files")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button(action: send) {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(sending || to.trimmingCharacters(in: .whitespaces).isEmpty || store.accounts.isEmpty)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Send (⇧⌘D)")
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls.compactMap(OutgoingAttachment.load)) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OutgoingAttachment.loadDropped(providers) { attachments.append(contentsOf: $0) }
            return true
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        fromAccountID = request.accountID ?? store.accounts.first?.id
        to = request.to.joined(separator: ", ")
        subject = request.subject
        focus = to.isEmpty ? .to : .body

        guard request.mode != .new, let id = request.messageID, let summary = store.summary(id: id) else { return }
        fromAccountID = summary.accountID
        replyTarget = summary
        guard let original = try? await store.loadMessage(summary) else {
            error = "Couldn't load the original message."
            return
        }
        let mine = store.ownAddresses[summary.accountID] ?? []
        switch request.mode {
        case .reply, .replyAll:
            subject = ReplyBuilder.replySubject(original.subject)
            replyReferences = ReplyBuilder.references(for: original)
            replyMessageID = original.messageID
            let isMine = original.from.contains { mine.contains($0.normalizedEmail) }
            var primary: [MailAddress] = isMine ? original.to : (original.replyTo.isEmpty ? original.from : original.replyTo)
            var copies: [MailAddress] = []
            if request.mode == .replyAll {
                let others = (isMine ? [] : original.to) + original.cc
                copies = others.filter { address in
                    !mine.contains(address.normalizedEmail) && !primary.contains { $0.normalizedEmail == address.normalizedEmail }
                }
            }
            primary = primary.filter { !mine.contains($0.normalizedEmail) || isMine }
            to = primary.map(\.headerValueForEditing).joined(separator: ", ")
            cc = copies.map(\.headerValueForEditing).joined(separator: ", ")
            showCcBcc = !cc.isEmpty
            messageBody = ReplyBuilder.quoted(original)
            focus = .body
        case .forward:
            subject = ReplyBuilder.forwardSubject(original.subject)
            messageBody = ReplyBuilder.forwarded(original)
            attachments = original.visibleAttachments.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
            focus = .to
        case .new:
            break
        }
    }

    private func send() {
        guard let account = fromAccount else { return }
        let recipients = MailAddress.parseList(to)
        guard !recipients.isEmpty else {
            error = "Add at least one valid recipient."
            return
        }
        let outgoing = OutgoingMessage(
            from: account.address,
            to: recipients,
            cc: MailAddress.parseList(cc),
            bcc: MailAddress.parseList(bcc),
            subject: subject,
            body: messageBody,
            inReplyTo: replyMessageID,
            references: replyReferences,
            attachments: attachments
        )
        sending = true
        error = nil
        Task {
            do {
                try await store.send(outgoing, account: account, replyingTo: replyTarget)
                dismissWindow(id: "compose", value: request)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

private struct HeaderRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider().padding(.leading, 14)
        }
    }
}

/// Comma separated recipients with native completion from people you've emailed.
struct RecipientField: View {
    @Binding var text: String
    let contacts: [MailAddress]

    private var suggestions: [MailAddress] {
        let token = currentToken
        guard token.count >= 1 else { return [] }
        return contacts.filter {
            $0.email.localizedCaseInsensitiveContains(token) || ($0.name?.localizedCaseInsensitiveContains(token) ?? false)
        }
        .prefix(8)
        .map { $0 }
    }

    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return parts.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private var prefix: String {
        guard let comma = text.lastIndex(of: ",") else { return "" }
        return String(text[...comma]) + " "
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .textInputSuggestions {
                ForEach(suggestions) { contact in
                    VStack(alignment: .leading) {
                        Text(contact.displayName)
                        if contact.name != nil {
                            Text(contact.email).foregroundStyle(.secondary)
                        }
                    }
                    .textInputCompletion(prefix + contact.headerValueForEditing + ", ")
                }
            }
    }
}

extension MailAddress {
    /// `Name <email>` without MIME encoding, for editable text fields.
    var headerValueForEditing: String {
        guard let name, !name.isEmpty else { return email }
        let needsQuotes = name.contains(",") || name.contains("\"") || name.contains("<")
        return needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\" <\(email)>" : "\(name) <\(email)>"
    }
}

extension OutgoingAttachment {
    static func load(_ url: URL) -> OutgoingAttachment? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
    }

    static func loadDropped(_ providers: [NSItemProvider], completion: @escaping @MainActor ([OutgoingAttachment]) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let attachment = load(url) else { return }
                Task { @MainActor in completion([attachment]) }
            }
        }
    }
}
