import MailCore
import SwiftUI

/// Slack-style layout: account rail + chat sidebar, the open chat in the middle,
/// and the selected thread in an inspector on the right.
struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @State private var selectedMessageID: MessageSummary.ID?
    /// The open chat's messages, to follow the conversation if its chat changes (someone joined or left).
    @State private var openChatMessages: [String] = []
    @State private var searchText = ""
    @State private var showingAddAccount = false

    var body: some View {
        Group {
            if !store.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.accounts.isEmpty {
                WelcomeView(showingAddAccount: $showingAddAccount)
            } else {
                splitView
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $showingAddAccount) {
            AccountSetupView()
        }
        .overlay(alignment: .bottom) {
            ErrorBanner()
        }
    }

    private var splitView: some View {
        @Bindable var navigator = navigator
        return NavigationSplitView {
            WorkspaceSidebar(
                accountID: $navigator.accountID, selection: $navigator.selection, searchText: searchText,
                showingAddAccount: $showingAddAccount
            )
            .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 440)
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .onChange(of: navigator.selection) { selectedMessageID = nil }
        .onChange(of: navigator.accountID) { _, newAccount in
            // Switching workspace opens its most recent conversation.
            switch navigator.selection {
            case .chat(let id) where store.chat(id: id)?.accountID == newAccount: return
            case .newMessage where navigator.newMessage?.accountID == newAccount: return
            default: navigator.selection = newAccount.flatMap(defaultSelection)
            }
        }
        .onAppear(perform: validate)
        #if DEBUG
        .onAppear { if let query = ProcessInfo.processInfo.environment["QMAIL_SEARCH"] { searchText = query } }
        .task {
            // QMAIL_RESYNC=N gets new mail again N seconds after launch, to see the toolbar while it loads.
            guard let delay = ProcessInfo.processInfo.environment["QMAIL_RESYNC"].flatMap(Double.init) else { return }
            try? await Task.sleep(for: .seconds(delay))
            await store.refreshAll()
        }
        #endif
        .onChange(of: store.accounts) { validate() }
        .onChange(of: store.chats) { followMovedChat() }
        #if DEBUG
        .modifier(DebugSelection(showingAddAccount: $showingAddAccount, message: $selectedMessageID))
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch navigator.selection {
        case .chat(let id):
            if let chat = store.chat(id: id) {
                ChatView(chat: chat)
                    .id(chat.id)
            } else {
                EmptyDetailView(title: "Conversation Moved", message: "Someone joined or left, so it continues in another chat.", systemImage: "bubble.left.and.bubble.right")
            }
        case .mailbox(let id):
            FolderView(mailboxID: id, selection: $selectedMessageID, searchText: searchText)
                .id(id)
        case .message(let id):
            if let summary = store.summary(id: id) {
                if let (chat, thread) = store.chatAndThread(containing: summary) {
                    // A search result in a chat opens there, with its thread.
                    Color.clear.task(id: id) {
                        navigator.showChat(chat.id, accountID: chat.accountID, thread: thread.id)
                    }
                } else {
                    MessageDetailView(summary: summary)
                        .id(id)
                }
            }
        case .newMessage:
            if let draft = navigator.newMessage {
                NewMessageView(draft: draft)
                    .id(draft.id)
            }
        case nil:
            EmptyDetailView(
                title: "No Chat Selected",
                message: "Every email lives in a chat with the people on it. Pick one from the sidebar.",
                systemImage: "bubble.left.and.bubble.right"
            )
        }
    }

    private func validate() {
        if navigator.accountID.flatMap({ store.account($0) }) == nil {
            navigator.accountID = store.accounts.first?.id
        }
        switch navigator.selection {
        case .chat(let id) where store.chat(id: id) != nil: return
        case .mailbox(let id) where store.mailbox(id: id) != nil: return
        case .newMessage where navigator.newMessage.flatMap({ store.account($0.accountID) }) != nil: return
        case .message(let id) where store.summary(id: id) != nil: return
        default: navigator.selection = navigator.accountID.flatMap(defaultSelection)
        }
    }

    private func followMovedChat() {
        guard case .chat(let id) = navigator.selection else { return }
        if let chat = store.chat(id: id) {
            openChatMessages = chat.messageIDs
            return
        }
        // Find where the newest message we were looking at lives now.
        for messageID in openChatMessages.reversed() {
            if let summary = store.summary(id: messageID), let (chat, _) = store.chatAndThread(containing: summary) {
                navigator.selection = .chat(chat.id)
                return
            }
        }
        navigator.selection = navigator.accountID.flatMap(defaultSelection)
    }

    private func defaultSelection(for accountID: UUID) -> SidebarItem? {
        let sections = store.chatSections(for: accountID)
        let recent = (sections.starred + sections.groups + sections.direct).max { $0.lastDate < $1.lastDate }
        return (recent ?? sections.updates.first).map { .chat($0.id) }
    }
}

/// A classic folder: message list on the left, the selected email on the right.
struct FolderView: View {
    @Environment(MailStore.self) private var store
    let mailboxID: String
    @Binding var selection: MessageSummary.ID?
    let searchText: String

    var body: some View {
        HSplitView {
            MessageListView(item: .mailbox(mailboxID), selection: $selection, searchText: searchText)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 540)
            Group {
                if let id = selection, let summary = store.summary(id: id) {
                    MessageDetailView(summary: summary)
                        .id(summary.id)
                } else {
                    EmptyDetailView(title: "No Message Selected", message: "Choose a message to read it.", systemImage: "envelope")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EmptyDetailView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Transient error message floating above the content.
struct ErrorBanner: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if let message = store.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .lineLimit(3)
                    .font(.callout)
                Button {
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 24)
            .padding(.horizontal, 40)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(8))
                if store.errorMessage == message { store.errorMessage = nil }
            }
        }
    }
}
