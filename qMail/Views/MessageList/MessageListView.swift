import MailCore
import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let item: SidebarItem
    @Binding var selection: MessageSummary.ID?
    let searchText: String
    @State private var unreadOnly = false
    @State private var loadingOlder = false
    @State private var serverResults: [MessageSummary]?
    @State private var searchingServer = false

    private var mailboxID: String? {
        if case .mailbox(let id) = item { return id }
        return nil
    }

    private var isSentFolder: Bool {
        mailboxID.flatMap { store.mailbox(id: $0) }.map { $0.role == .sent || $0.role == .drafts } ?? false
    }

    private var visibleMessages: [MessageSummary] {
        var list = store.messages(for: item)
        if unreadOnly { list = list.filter { !$0.isSeen || $0.id == selection } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        var matches = list.filter { message in
            message.subject.localizedCaseInsensitiveContains(query)
                || message.snippet.localizedCaseInsensitiveContains(query)
                || (message.from + message.to).contains {
                    $0.displayName.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query)
                }
        }
        if let serverResults {
            let known = Set(matches.map(\.id))
            matches += serverResults.filter { !known.contains($0.id) }
            matches.sort { $0.date > $1.date }
        }
        return matches
    }

    var body: some View {
        let messages = visibleMessages
        List(selection: $selection) {
            ForEach(messages) { message in
                MessageRow(message: message, showRecipients: isSentFolder, showAccount: false)
                    .tag(message.id)
                    .contextMenu { contextMenu(for: message) }
                    .swipeActions(edge: .leading) {
                        Button {
                            store.setRead([message], read: !message.isSeen)
                        } label: {
                            Label(message.isSeen ? "Unread" : "Read", systemImage: message.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete([message])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            store.archive([message])
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.purple)
                    }
            }
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty, serverResults == nil {
                HStack {
                    Spacer()
                    Button {
                        searchingServer = true
                        let query = searchText
                        Task {
                            let results = await store.searchOnServer(item, query: query)
                            if searchText == query { serverResults = results }
                            searchingServer = false
                        }
                    } label: {
                        if searchingServer {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Search on Server", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(searchingServer)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)
            }
            if let mailboxID, searchText.isEmpty, !unreadOnly, store.canLoadOlder(in: mailboxID) {
                HStack {
                    Spacer()
                    Button {
                        loadingOlder = true
                        Task {
                            await store.loadOlder(in: mailboxID)
                            loadingOlder = false
                        }
                    } label: {
                        if loadingOlder {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load Older Messages")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(loadingOlder)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)
            }
        }
        .listStyle(.inset)
        .onChange(of: searchText) { serverResults = nil }
        .overlay {
            if messages.isEmpty && !searchingServer {
                if !searchText.isEmpty {
                    // Before a server search, keep the "Search on Server" row clickable.
                    if serverResults != nil { ContentUnavailableView.search(text: searchText) }
                } else if unreadOnly {
                    ContentUnavailableView("No Unread Messages", systemImage: "envelope.open", description: Text("You're all caught up."))
                } else {
                    ContentUnavailableView("No Messages", systemImage: "tray")
                }
            }
        }
        .navigationTitle(store.title(for: item))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $unreadOnly) {
                    Label("Unread Only", systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Show only unread messages")
                Button {
                    navigator.startNewMessage(accountID: mailboxID.flatMap { store.mailbox(id: $0) }?.accountID)
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New Message")
            }
        }
        .task(id: item) {
            await store.refreshIfStale(item)
        }
        .onKeyPress(.delete) {
            guard let id = selection, let message = store.summary(id: id) else { return .ignored }
            store.delete([message])
            return .handled
        }
    }

    private var subtitle: String {
        let unread = store.unreadCount(for: item)
        return unread > 0 ? "\(unread) unread" : ""
    }

    @ViewBuilder
    private func contextMenu(for message: MessageSummary) -> some View {
        Button("Reply") { navigator.reply(to: message, all: false, store: store) }
        Button("Reply All") { navigator.reply(to: message, all: true, store: store) }
        Button("Forward") { Task { await navigator.forward(message, store: store) } }
        Divider()
        Button(message.isSeen ? "Mark as Unread" : "Mark as Read") { store.setRead([message], read: !message.isSeen) }
        Button(message.isFlagged ? "Unflag" : "Flag") { store.setFlagged([message], flagged: !message.isFlagged) }
        Divider()
        Menu("Move To") {
            ForEach(store.mailboxes[message.accountID] ?? []) { mailbox in
                if mailbox.path != message.mailboxPath {
                    Button(mailbox.displayName) { store.move([message], to: mailbox) }
                }
            }
        }
        Button("Archive") { store.archive([message]) }
        Button("Delete", role: .destructive) { store.delete([message]) }
    }
}

struct MessageRow: View {
    @Environment(MailStore.self) private var store
    let message: MessageSummary
    var showRecipients = false
    var showAccount = false

    private var title: String {
        if showRecipients {
            let names = (message.to + message.cc).map(\.displayName)
            return names.isEmpty ? "(No Recipients)" : "To: " + names.joined(separator: ", ")
        }
        return message.sender?.displayName ?? "(Unknown Sender)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isSeen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 14)
            AvatarView(address: showRecipients ? message.to.first : message.sender, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(message.isSeen ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if message.isFlagged {
                        Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption)
                    }
                    if message.hasAttachments {
                        Image(systemName: "paperclip").foregroundStyle(.secondary).font(.caption)
                    }
                    Text(DateText.short(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    if message.isAnswered {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.displaySubject)
                        .font(.subheadline)
                        .fontWeight(message.isSeen ? .regular : .medium)
                        .lineLimit(1)
                }
                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showAccount, let account = store.account(message.accountID) {
                    Text(account.email)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
