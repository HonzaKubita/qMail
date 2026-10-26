import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// The message box at the bottom of a chat, a thread, or the New Message view.
/// In a chat it starts a new email thread; in a thread it replies; in New Message it emails the chosen people.
struct ChatComposer: View {
    enum Target {
        case chat(Chat)
        case thread(Chat, ChatThread)
        /// A group chat: replies to everyone on the given email (or the latest one).
        case group(Chat, ChatThread?)
        case newMessage(NewMessageDraft)
    }

    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let target: Target
    /// In a 1:1 chat, everyone on the email — when set, the box offers "Reply to everyone".
    let replyAllPeople: [MailAddress]
    var onClearReplyTarget: (() -> Void)?
    @State private var replyAll: Bool
    @State private var text: String
    @State private var subject: String
    @State private var showSubject: Bool
    @State private var attachments: [OutgoingAttachment]
    @State private var textHeight: CGFloat = 24
    @State private var sending = false
    @State private var showingImporter = false
    @State private var error: String?

    init(target: Target, replyAllPeople: [MailAddress] = [], replyAll: Bool = false, onClearReplyTarget: (() -> Void)? = nil) {
        self.target = target
        self.replyAllPeople = replyAllPeople
        self.onClearReplyTarget = onClearReplyTarget
        _replyAll = State(initialValue: replyAll && !replyAllPeople.isEmpty)
        if case .newMessage(let draft) = target {
            _text = State(initialValue: draft.body)
            _subject = State(initialValue: draft.subject)
            _showSubject = State(initialValue: !draft.subject.isEmpty)
            _attachments = State(initialValue: draft.attachments)
        } else {
            #if DEBUG
            // QMAIL_DRAFT prefills the chat box, for screenshots of the subject highlight.
            let debugDraft = ProcessInfo.processInfo.environment["QMAIL_DRAFT"].flatMap { draft -> String? in
                if case .chat = target { return draft.replacingOccurrences(of: "\\n", with: "\n") }
                return nil
            }
            _text = State(initialValue: debugDraft ?? "")
            #else
            _text = State(initialValue: "")
            #endif
            _subject = State(initialValue: "")
            _showSubject = State(initialValue: false)
            _attachments = State(initialValue: [])
        }
    }

    private var isReply: Bool {
        if case .thread = target { return true }
        return false
    }

    private var groupChat: Chat? {
        if case .group(let chat, _) = target { return chat }
        return nil
    }

    /// The email a group-chat message replies to: the chosen one, or the latest.
    private var groupReplyThread: ChatThread? {
        if case .group(let chat, let thread) = target { return thread ?? chat.threads.last }
        return nil
    }

    /// Without an explicit subject, the first line becomes the subject of a new email.
    /// In a group chat you reply by default, so there's no subject unless you start a new one.
    private var highlightsSubject: Bool { !isReply && groupChat == nil && !showSubject }

    private var derivedSubject: String { MailStore.subject(nil, fallback: text) }

    private var canSend: Bool {
        !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var placeholder: String {
        switch target {
        case .thread: return replyAll ? "Reply to everyone…" : "Reply…"
        case .chat(let chat): return chat.isSelf ? "Note to self" : "Message \(store.title(for: chat))"
        case .group(let chat, _): return showSubject ? "Message for the new subject" : "Message \(store.title(for: chat))"
        case .newMessage(let draft):
            let names = draft.recipients.map(\.shortName)
            return names.isEmpty ? "Write a message" : "Message \(ListFormatter.localizedString(byJoining: names))"
        }
    }

    private var focusOnAppear: Bool {
        if case .newMessage(let draft) = target { return !draft.recipients.isEmpty }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if isReply && !replyAllPeople.isEmpty {
                    replyModeBar
                }
                if !isReply && showSubject {
                    TextField("Subject", text: $subject)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    Divider()
                        .padding(.horizontal, 10)
                }
                ZStack(alignment: .topLeading) {
                    ComposerTextView(
                        text: $text, height: $textHeight, highlightsFirstLine: highlightsSubject,
                        focusOnAppear: focusOnAppear, onSubmit: send
                    )
                    .frame(height: textHeight)
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
                if !attachments.isEmpty {
                    attachmentChips
                }
                HStack(spacing: 2) {
                    toolButton("paperclip", help: "Attach files") { showingImporter = true }
                    if !isReply {
                        toolButton(showSubject ? "textformat.size.smaller" : "textformat",
                                   help: groupChat != nil ? (showSubject ? "Reply instead" : "Start a new subject") : (showSubject ? "Use the first line as the subject" : "Write a separate subject")) {
                            showSubject.toggle()
                            if !showSubject { subject = "" }
                        }
                    }
                    subjectStatus
                        .padding(.leading, 6)
                    Spacer(minLength: 8)
                    Button(action: send) {
                        Group {
                            if sending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "paperplane.fill")
                            }
                        }
                        .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return) · new line with Shift-Return")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls.compactMap(OutgoingAttachment.load)) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OutgoingAttachment.loadDropped(providers) { attachments.append(contentsOf: $0) }
            return true
        }
    }

    /// Shows exactly what the subject will be, or what the box does for replies.
    @ViewBuilder
    private var subjectStatus: some View {
        if highlightsSubject && !derivedSubject.isEmpty {
            HStack(spacing: 5) {
                Text("SUBJECT")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: .capsule)
                Text(derivedSubject)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help("The highlighted first line becomes the email's subject. Click Aa to write a separate subject.")
        } else if highlightsSubject {
            Text("The first line becomes the subject")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if groupChat != nil, !showSubject, let thread = groupReplyThread {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left")
                Text(thread.subject.isEmpty ? "Replies to everyone" : "Replies to everyone · Re: \(thread.subject)")
                    .lineLimit(1)
                if case .group(_, let chosen?) = target, chosen.id != groupChat?.threads.last?.id {
                    Button {
                        onClearReplyTarget?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Reply to the latest email instead")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if groupChat != nil {
            Text("Starts a new subject for everyone")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if isReply {
            Text(replyAll ? "Replies to \(replyAllPeople.count) people" : "Replies in this thread")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var replyModeBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Reply to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Reply to", selection: $replyAll) {
                    Text(onlyLabel).tag(false)
                    Text("Everyone (\(replyAllPeople.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(replyAllPeople.map(\.displayName).joined(separator: ", "))
            }
            if replyAll {
                Text("Replying to everyone turns this thread into a group chat.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var onlyLabel: String {
        if case .thread(let chat, _) = target, let person = chat.participants.first, chat.participants.count == 1 {
            return "\(person.shortName) only"
        }
        return "This chat"
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(attachment.filename).lineLimit(1)
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
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: .capsule)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func toolButton(_ icon: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func send() {
        guard canSend else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        let explicitSubject = showSubject ? subject : nil
        if case .newMessage(let draft) = target, draft.recipients.isEmpty {
            error = "Add at least one person to send to."
            return
        }
        sending = true
        error = nil
        Task {
            do {
                let sentID: String?
                switch target {
                case .chat(let chat):
                    sentID = try await store.post(in: chat, thread: nil, text: body, subject: explicitSubject, attachments: files)
                case .thread(let chat, let thread):
                    sentID = try await store.post(in: chat, thread: thread, text: body, subject: nil, attachments: files,
                                                  recipients: replyAll ? replyAllPeople : nil)
                case .group(let chat, _):
                    sentID = try await store.post(in: chat, thread: explicitSubject == nil ? groupReplyThread : nil,
                                                  text: body, subject: explicitSubject, attachments: files)
                    onClearReplyTarget?()
                case .newMessage(let draft):
                    sentID = try await sendNewMessage(draft, body: body, subject: explicitSubject, attachments: files)
                }
                text = ""
                subject = ""
                showSubject = false
                attachments = []
                followSentMessage(sentID)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    private func sendNewMessage(_ draft: NewMessageDraft, body: String, subject: String?, attachments: [OutgoingAttachment]) async throws -> String? {
        guard let account = store.account(draft.accountID) else { return nil }
        let outgoing = OutgoingMessage(
            from: account.address,
            to: draft.recipients,
            subject: MailStore.subject(subject, fallback: body),
            body: body,
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            attachments: attachments
        )
        return try await store.send(outgoing, account: account, replyingTo: nil)
    }

    /// Goes to the chat the message landed in when that isn't the one on screen — a new
    /// conversation, or a reply to everyone that turned a 1:1 thread into a group chat.
    private func followSentMessage(_ sentID: String?) {
        guard let sentID, let summary = store.summary(id: sentID),
              let (chat, thread) = store.chatAndThread(containing: summary) else { return }
        switch target {
        case .chat(let current) where current.id == chat.id: return
        case .thread(let current, _) where current.id == chat.id: return
        case .group(let current, _) where current.id == chat.id: return
        default: break
        }
        navigator.showChat(chat.id, accountID: chat.accountID, thread: isReply ? thread.id : nil)
    }
}
