import AppKit
import MailCore
import SwiftUI
import UniformTypeIdentifiers

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let summary: MessageSummary
    var showsToolbar = true
    @State private var parsed: ParsedMessage?
    @State private var loadError: String?
    @State private var remoteAllowed = false

    var body: some View {
        VStack(spacing: 0) {
            MessageHeaderView(summary: summary, parsed: parsed)
            if let parsed {
                if !parsed.visibleAttachments.isEmpty {
                    AttachmentStrip(attachments: parsed.visibleAttachments)
                }
                body(for: parsed)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Message", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.glass)
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(summary.displaySubject)
        .task(id: summary.id) {
            remoteAllowed = store.settings.loadRemoteContent
            await load()
        }
        .toolbar {
            if showsToolbar { toolbarContent }
        }
    }

    @ViewBuilder
    private func body(for parsed: ParsedMessage) -> some View {
        if let html = parsed.htmlBody, !html.isEmpty {
            let inlined = HTMLView.inlineImages(html, attachments: parsed.attachments)
            VStack(spacing: 0) {
                if !remoteAllowed && HTMLView.hasRemoteContent(inlined) {
                    HStack {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Remote images are hidden to protect your privacy.")
                            .font(.callout)
                        Spacer()
                        Button("Load Images") { remoteAllowed = true }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
                HTMLView(html: inlined, allowRemoteContent: remoteAllowed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(12)
            }
        } else {
            HTMLView(html: HTMLView.document(forPlainText: parsed.textBody ?? ""), allowRemoteContent: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
        }
    }

    private func load() async {
        loadError = nil
        do {
            parsed = try await store.loadMessage(summary)
            if !summary.isSeen, let current = store.summary(id: summary.id) {
                store.setRead([current], read: true)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let current = store.summary(id: summary.id) ?? summary
        ToolbarItemGroup {
            Button {
                store.archive([current])
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive")
            Button {
                store.delete([current])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete")
            .keyboardShortcut(.delete, modifiers: .command)
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button {
                openWindow(id: "compose", value: ComposeRequest(mode: .reply, messageID: summary.id))
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .help("Reply")
            .keyboardShortcut("r")
            Button {
                openWindow(id: "compose", value: ComposeRequest(mode: .replyAll, messageID: summary.id))
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .help("Reply All")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button {
                openWindow(id: "compose", value: ComposeRequest(mode: .forward, messageID: summary.id))
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .help("Forward")
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button {
                store.setFlagged([current], flagged: !current.isFlagged)
            } label: {
                Label(current.isFlagged ? "Unflag" : "Flag", systemImage: current.isFlagged ? "flag.slash" : "flag")
            }
            .help(current.isFlagged ? "Unflag" : "Flag")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button {
                store.setRead([current], read: !current.isSeen)
            } label: {
                Label(current.isSeen ? "Mark as Unread" : "Mark as Read", systemImage: current.isSeen ? "envelope.badge" : "envelope.open")
            }
            .help(current.isSeen ? "Mark as Unread" : "Mark as Read")
            .keyboardShortcut("u", modifiers: [.command, .shift])
        }
    }
}

struct MessageHeaderView: View {
    @Environment(MailStore.self) private var store
    let summary: MessageSummary
    let parsed: ParsedMessage?
    @State private var showDetails = false

    var body: some View {
        let current = store.summary(id: summary.id) ?? summary
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.displaySubject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 12) {
                AvatarView(address: summary.sender, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.sender?.displayName ?? "Unknown Sender")
                            .font(.headline)
                        if let email = summary.sender?.email, summary.sender?.name != nil {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if current.isFlagged {
                            Image(systemName: "flag.fill").foregroundStyle(.orange)
                        }
                        Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    recipientLine("To", summary.to)
                    if !summary.cc.isEmpty { recipientLine("Cc", summary.cc) }
                }
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recipientLine(_ label: String, _ addresses: [MailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(addresses.map { store.isOwn($0, accountID: summary.accountID) ? "Me" : $0.displayName }.joined(separator: ", "))
                .lineLimit(showDetails ? nil : 1)
                .onTapGesture { showDetails.toggle() }
                .help(addresses.map(\.email).joined(separator: ", "))
        }
        .font(.subheadline)
    }
}

/// Horizontal row of attachment chips; click to open, menu to save.
struct AttachmentStrip: View {
    let attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentChip(attachment: attachment)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }
}

struct AttachmentChip: View {
    let attachment: MailAttachment

    var body: some View {
        Menu {
            Button("Open") { open() }
            Button("Save As…") { save() }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: attachment.mimeType) ?? .data))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename)
                        .font(.callout)
                        .lineLimit(1)
                    Text(Int64(attachment.size), format: .byteCount(style: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
        } primaryAction: {
            open()
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help(attachment.filename)
    }

    private func open() {
        if let url = try? Persistence.temporaryFile(named: attachment.filename, data: attachment.data) {
            NSWorkspace.shared.open(url)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? attachment.data.write(to: url)
        }
    }
}
