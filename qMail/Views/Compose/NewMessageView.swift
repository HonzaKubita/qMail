import MailCore
import SwiftUI

/// Starting a conversation, in place of the chat view (no separate compose window).
/// If a chat with the chosen people already exists, its history shows below the To: field.
struct NewMessageView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Bindable var draft: NewMessageDraft
    @State private var fullMessage: MessageSummary?

    var body: some View {
        let existing = draft.recipients.isEmpty ? nil : store.chat(accountID: draft.accountID, with: draft.recipients)
        VStack(spacing: 0) {
            RecipientTokenField(recipients: $draft.recipients, contacts: store.knownContacts)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Divider()
            if let existing {
                Label("You already have a conversation with \(store.title(for: existing)). Your message starts a new thread in it.",
                      systemImage: "bubble.left.and.bubble.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChatTimelineView(
                    chat: existing,
                    onOpenThread: { navigator.showChat(existing.id, accountID: existing.accountID, thread: $0) },
                    onShowEmail: { fullMessage = $0 }
                )
            } else if draft.recipients.isEmpty {
                ContentUnavailableView {
                    Label("New Message", systemImage: "square.and.pencil")
                } description: {
                    Text("Add people above. If you already have a conversation with them, it appears here and your message joins it.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                newConversationIntro
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(target: .newMessage(draft))
        }
        .navigationTitle("New Message")
        .navigationSubtitle(store.account(draft.accountID)?.email ?? "")
        .sheet(item: $fullMessage) { summary in
            MessageSheet(summary: summary)
        }
    }

    private var newConversationIntro: some View {
        let names = ListFormatter.localizedString(byJoining: draft.recipients.map(\.shortName))
        return VStack(alignment: .leading, spacing: 10) {
            Spacer()
            GroupAvatarView(participants: draft.recipients, size: 64)
            Text(names)
                .font(.title.bold())
            Text(draft.recipients.count > 1
                 ? "This email goes to all of them and shows up in your chat with each person. Once someone replies to everyone, it becomes a group chat."
                 : "This starts your conversation with \(names).")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
