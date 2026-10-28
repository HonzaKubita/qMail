import Foundation
import MailCore
import Observation

/// A message being written in the "New Message" view (also used for forwards and for
/// replies to mail that isn't part of any chat, such as messages in Junk).
@MainActor @Observable
final class NewMessageDraft: Identifiable {
    let id = UUID()
    var accountID: UUID
    var recipients: [MailAddress]
    var subject: String
    var body: String
    var attachments: [OutgoingAttachment]
    var inReplyTo: String?
    var references: [String]

    init(accountID: UUID, recipients: [MailAddress] = [], subject: String = "", body: String = "",
         attachments: [OutgoingAttachment] = [], inReplyTo: String? = nil, references: [String] = []) {
        self.accountID = accountID
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }
}

/// What the main window shows. Lets any view jump to a chat, open a thread for replying,
/// or start a new message in place — there are no separate compose windows.
@MainActor @Observable
final class AppNavigator {
    var accountID: UUID?
    var selection: SidebarItem?
    var newMessage: NewMessageDraft?
    /// A thread a chat should open once it appears, e.g. after "Reply" in a folder.
    var pendingThread: (chatID: String, threadID: String, replyAll: Bool)?
    /// The account Settings should show when it opens from an account's menu.
    var settingsAccountID: UUID?
    /// Bumped by Edit ▸ Search (⌘F) to put the cursor in the toolbar's search field.
    var searchRequest = 0

    func showChat(_ chatID: String, accountID: UUID, thread threadID: String? = nil, replyAll: Bool = false) {
        self.accountID = accountID
        selection = .chat(chatID)
        pendingThread = threadID.map { (chatID, $0, replyAll) }
    }

    func startNewMessage(_ draft: NewMessageDraft) {
        accountID = draft.accountID
        newMessage = draft
        selection = .newMessage
    }

    func startNewMessage(accountID: UUID?, to recipients: [MailAddress] = []) {
        guard let accountID = accountID ?? self.accountID else { return }
        startNewMessage(NewMessageDraft(accountID: accountID, recipients: recipients))
    }

    /// Replies in the bottom bar of the message's chat thread, or in a new message if it isn't in any chat.
    func reply(to summary: MessageSummary, all: Bool, store: MailStore) {
        if let (chat, thread) = store.chatAndThread(containing: summary) {
            showChat(chat.id, accountID: chat.accountID, thread: thread.id, replyAll: all)
            return
        }
        let mine = store.ownAddresses[summary.accountID] ?? []
        let primary = summary.replyTo.isEmpty ? summary.from : summary.replyTo
        var recipients = primary
        if all {
            for address in summary.to + summary.cc where !recipients.contains(where: { $0.normalizedEmail == address.normalizedEmail }) {
                recipients.append(address)
            }
        }
        var references = summary.references
        if let id = summary.messageID { references.append(id) }
        startNewMessage(NewMessageDraft(
            accountID: summary.accountID,
            recipients: recipients.filter { !mine.contains($0.normalizedEmail) },
            subject: ReplyBuilder.replySubject(summary.subject),
            inReplyTo: summary.messageID,
            references: Array(references.suffix(20))
        ))
    }

    /// Opens a new message with the original quoted and its attachments included.
    func forward(_ summary: MessageSummary, store: MailStore) async {
        do {
            let original = try await store.loadMessage(summary)
            startNewMessage(NewMessageDraft(
                accountID: summary.accountID,
                subject: ReplyBuilder.forwardSubject(original.subject),
                body: ReplyBuilder.forwarded(original),
                attachments: original.visibleAttachments.map {
                    OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
                }
            ))
        } catch {
            store.errorMessage = "Couldn't load the message to forward: \(error.localizedDescription)"
        }
    }
}
