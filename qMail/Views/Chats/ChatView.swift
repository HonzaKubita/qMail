import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// A chat transcript: every email between the same people, newest at the bottom.
struct ChatView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let chat: Chat
    @State private var visibleCount = 40
    @State private var fullMessage: MessageSummary?
    @State private var showingInfo = false

    private var summaries: [MessageSummary] {
        chat.messageIDs.suffix(visibleCount).compactMap { store.summary(id: $0) }
    }

    var body: some View {
        let items = ChatTimeline.items(for: summaries, chat: chat, store: store)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if chat.messageIDs.count > visibleCount {
                        Button("Show Earlier Messages") {
                            visibleCount += 40
                            Task { await store.loadChatContents(for: chat, limit: visibleCount) }
                        }
                        .buttonStyle(.glass)
                        .padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        row(for: item)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(ChatTimeline.bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messageIDs.last) {
                withAnimation(.smooth) { proxy.scrollTo(ChatTimeline.bottomID, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(chat: chat)
        }
        .navigationTitle(store.title(for: chat))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openWindow(id: "compose", value: ComposeRequest(accountID: chat.accountID, to: chat.participants.map(\.email)))
                } label: {
                    Label("New Email to Everyone", systemImage: "square.and.pencil")
                }
                .help("New email to everyone in this chat")
                Button {
                    showingInfo.toggle()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .help("Chat details")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    ChatInfoView(chat: chat)
                }
            }
        }
        .task(id: chat.messageIDs.count) {
            await store.loadChatContents(for: chat, limit: visibleCount)
            if let current = store.chat(id: chat.id) { store.markChatRead(current) }
        }
        .sheet(item: $fullMessage) { summary in
            MessageSheet(summary: summary)
        }
    }

    private var subtitle: String {
        if chat.participants.count == 1 { return chat.participants[0].email }
        return "\(chat.participants.count + 1) people"
    }

    @ViewBuilder
    private func row(for item: ChatTimeline.Item) -> some View {
        switch item.kind {
        case .date(let date):
            Text(DateText.divider(date))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
                .padding(.bottom, 6)
        case .subject(let subject):
            Label(subject, systemImage: "text.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .padding(.vertical, 8)
        case .message(let summary, let layout):
            ChatBubble(
                summary: summary,
                content: store.chatContents[summary.id],
                layout: layout,
                isPending: store.isPending(summary),
                onOpen: { fullMessage = summary }
            )
        }
    }
}

enum ChatTimeline {
    static let bottomID = "chat-bottom"

    struct Layout: Hashable {
        var isMine: Bool
        var showSender: Bool
        var showAvatar: Bool
        var isRunStart: Bool
    }

    struct Item: Identifiable {
        enum Kind {
            case date(Date)
            case subject(String)
            case message(MessageSummary, Layout)
        }

        let id: String
        let kind: Kind
    }

    @MainActor
    static func items(for summaries: [MessageSummary], chat: Chat, store: MailStore) -> [Item] {
        var items: [Item] = []
        let calendar = Calendar.current
        var lastDay: Date?
        var lastSubject: String?
        var lastSender: String?

        for (index, summary) in summaries.enumerated() {
            let day = calendar.startOfDay(for: summary.date)
            var brokeRun = false
            if day != lastDay {
                items.append(Item(id: "d-\(day.timeIntervalSince1970)-\(index)", kind: .date(day)))
                lastDay = day
                brokeRun = true
            }
            let subject = summary.normalizedSubject
            if !subject.isEmpty, subject.caseInsensitiveCompare(lastSubject ?? "") != .orderedSame {
                items.append(Item(id: "s-\(summary.id)", kind: .subject(subject)))
                lastSubject = subject
                brokeRun = true
            }

            let sender = summary.sender?.normalizedEmail
            let isMine = store.isFromMe(summary)
            let next = index + 1 < summaries.count ? summaries[index + 1] : nil
            let nextContinuesRun = next.map {
                $0.sender?.normalizedEmail == sender
                    && calendar.isDate($0.date, inSameDayAs: summary.date)
                    && $0.normalizedSubject.caseInsensitiveCompare(subject) == .orderedSame
            } ?? false
            let isRunStart = brokeRun || sender != lastSender

            let layout = Layout(
                isMine: isMine,
                showSender: !isMine && chat.isGroup && isRunStart,
                showAvatar: !isMine && !nextContinuesRun,
                isRunStart: isRunStart
            )
            items.append(Item(id: summary.id, kind: .message(summary, layout)))
            lastSender = sender
        }
        return items
    }
}

struct ChatBubble: View {
    let summary: MessageSummary
    let content: ChatContent?
    let layout: ChatTimeline.Layout
    let isPending: Bool
    let onOpen: () -> Void
    @State private var expanded = false

    private static let collapsedLength = 1400

    private var text: String {
        content?.text ?? QuoteStripper.cleanSnippet(summary.snippet)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if layout.isMine {
                Spacer(minLength: 70)
            } else if layout.showAvatar {
                AvatarView(address: summary.sender, size: 28)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }

            VStack(alignment: layout.isMine ? .trailing : .leading, spacing: 3) {
                if layout.showSender {
                    Text(summary.sender?.displayName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                bubble
                if let names = content?.attachmentNames, !names.isEmpty {
                    attachmentChips(names)
                }
                if isPending {
                    Text("Sent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: 560, alignment: layout.isMine ? .trailing : .leading)

            if !layout.isMine { Spacer(minLength: 70) }
        }
        .padding(.top, layout.isRunStart ? 8 : 2)
        .contextMenu {
            Button("Show Full Email") { onOpen() }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private var bubble: some View {
        let isLong = text.count > Self.collapsedLength
        let display = expanded || !isLong ? text : String(text.prefix(Self.collapsedLength)) + "…"
        return VStack(alignment: .leading, spacing: 6) {
            if display.isEmpty {
                Text("Loading…")
                    .redacted(reason: .placeholder)
            } else {
                Text(ChatTimeline.linkified(display))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLong && !expanded {
                Button("Show More") { expanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(layout.isMine ? Color.white : Color.primary)
        .tint(layout.isMine ? .white : .accentColor)
        .background(
            layout.isMine ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .opacity(isPending ? 0.85 : 1)
        .help(summary.date.formatted(date: .abbreviated, time: .shortened))
        .onTapGesture(count: 2) { onOpen() }
    }

    private func attachmentChips(_ names: [String]) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                Text(names.count == 1 ? names[0] : "\(names.count) attachments")
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

extension ChatTimeline {
    /// Makes URLs and email addresses in plain text clickable.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: nsRange) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}

/// Reply box pinned to the bottom of a chat.
struct ChatComposer: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    @State private var text = ""
    @State private var sending = false
    @State private var attachments: [OutgoingAttachment] = []
    @State private var threadSubject: String?
    @State private var newSubject: String?
    @State private var showingImporter = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var currentSubject: String {
        threadSubject ?? chat.subjects.first ?? ""
    }

    private var canSend: Bool {
        !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && (newSubject.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topicBar
            if !attachments.isEmpty {
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
                            .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
            }
            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.body.weight(.medium))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Attach files")

                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...10)
                        .focused($focused)
                        .onSubmit(send)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Button(action: send) {
                        Group {
                            if sending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.body.weight(.bold))
                            }
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls.compactMap(OutgoingAttachment.load)) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OutgoingAttachment.loadDropped(providers) { attachments.append(contentsOf: $0) }
            return true
        }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        newSubject != nil ? "Message for the new topic" : "Reply to \(chat.isGroup ? "everyone" : chat.participants.first?.shortName ?? "chat")"
    }

    private var topicBar: some View {
        HStack(spacing: 8) {
            Menu {
                Section("Reply in") {
                    ForEach(chat.subjects, id: \.self) { subject in
                        Button {
                            threadSubject = subject
                            newSubject = nil
                        } label: {
                            if subject == currentSubject && newSubject == nil {
                                Label(subject, systemImage: "checkmark")
                            } else {
                                Text(subject)
                            }
                        }
                    }
                }
                Divider()
                Button("New Topic…") { newSubject = "" }
            } label: {
                Label(newSubject != nil ? "New topic" : "Re: \(currentSubject.isEmpty ? "(No Subject)" : currentSubject)",
                      systemImage: newSubject != nil ? "plus.bubble" : "text.bubble")
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()

            if newSubject != nil {
                TextField("Subject", text: Binding(get: { newSubject ?? "" }, set: { newSubject = $0 }))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: 260)
                Button {
                    newSubject = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 46)
    }

    private func send() {
        guard canSend else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        let thread = newSubject == nil ? currentSubject : nil
        let subject = newSubject?.trimmingCharacters(in: .whitespaces)
        sending = true
        error = nil
        Task {
            do {
                try await store.sendChatMessage(in: chat, text: body, threadSubject: thread, newSubject: subject, attachments: files)
                text = ""
                attachments = []
                if let subject {
                    threadSubject = subject
                    newSubject = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Participants and per-chat settings.
struct ChatInfoView: View {
    @Environment(MailStore.self) private var store
    let chat: Chat
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                GroupAvatarView(participants: chat.participants, size: 48)
                VStack(alignment: .leading) {
                    Text(store.title(for: chat)).font(.headline)
                    Text("\(chat.messageIDs.count) emails · \(chat.subjects.count) topics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Chat name", text: $name, prompt: Text(chat.defaultTitle))
                .onSubmit { store.rename(chat, to: name) }
            Divider()
            Text("People").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.participants) { person in
                        HStack(spacing: 8) {
                            AvatarView(address: person, size: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.displayName).font(.callout)
                                if person.name != nil {
                                    Text(person.email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider()
            HStack {
                Button(store.chatPreferences.pinned.contains(chat.id) ? "Unpin" : "Pin") { store.togglePinned(chat) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Save Name") { store.rename(chat, to: name) }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { name = store.chatPreferences.names[chat.id] ?? "" }
    }
}

/// Full email shown from a chat bubble.
struct MessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let summary: MessageSummary

    var body: some View {
        NavigationStack {
            MessageDetailView(summary: summary, showsToolbar: false)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            openWindow(id: "compose", value: ComposeRequest(mode: .replyAll, messageID: summary.id))
                            dismiss()
                        } label: {
                            Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                        }
                        Button {
                            openWindow(id: "compose", value: ComposeRequest(mode: .forward, messageID: summary.id))
                            dismiss()
                        } label: {
                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                        }
                    }
                }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 700)
    }
}
