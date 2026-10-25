import MailCore
import SwiftUI

struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection: SidebarItem? = .chats
    @State private var selectedMessageID: MessageSummary.ID?
    @State private var selectedChatID: Chat.ID?
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
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection, showingAddAccount: $showingAddAccount)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            Group {
                switch sidebarSelection ?? .chats {
                case .chats:
                    ChatListView(selection: $selectedChatID, searchText: searchText)
                case let item:
                    MessageListView(item: item, selection: $selectedMessageID, searchText: searchText)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 540)
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: sidebarSelection == .chats ? "Search Chats" : "Search")
        .onChange(of: sidebarSelection) {
            searchText = ""
            selectedMessageID = nil
        }
        #if DEBUG
        .modifier(DebugSelection(showingAddAccount: $showingAddAccount, sidebar: $sidebarSelection, chat: $selectedChatID, message: $selectedMessageID))
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        if sidebarSelection == .chats {
            if let id = selectedChatID, let chat = store.chat(id: id) {
                ChatView(chat: chat)
                    .id(chat.id)
            } else {
                EmptyDetailView(
                    title: "No Chat Selected",
                    message: "Group conversations with the same people show up here as chats.",
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        } else if let id = selectedMessageID, let summary = store.summary(id: id) {
            MessageDetailView(summary: summary)
                .id(summary.id)
        } else {
            EmptyDetailView(title: "No Message Selected", message: "Choose a message to read it.", systemImage: "envelope")
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
