import Foundation
import Testing
@testable import MailCore

@Suite struct ChatTests {
    let account = UUID()
    let me = MailAddress(name: "Me", email: "me@example.com")
    let alice = MailAddress(name: "Alice Smith", email: "alice@example.com")
    let bob = MailAddress(name: "Bob Jones", email: "bob@example.com")
    let carol = MailAddress(name: "Carol", email: "carol@example.com")

    func message(
        _ uid: UInt32, from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], subject: String,
        id: String, replyTo parent: String? = nil, refs: [String] = [], automated: Bool = false, seen: Bool = true,
        folder: String = "INBOX"
    ) -> MessageSummary {
        MessageSummary(
            id: MessageSummary.makeID(accountID: account, mailboxPath: folder, uid: uid), accountID: account,
            mailboxPath: folder, uid: uid, messageID: id, inReplyTo: parent, references: refs, subject: subject,
            from: [from], to: to, cc: cc, date: Date(timeIntervalSince1970: TimeInterval(uid) * 60), isSeen: seen,
            isFlagged: false, snippet: "", hasAttachments: false, isAutomated: automated
        )
    }

    @Test func groupsThreadsByParticipants() {
        let messages = [
            // Thread 1 with Alice + Bob: my reply-all makes it a group conversation.
            message(1, from: alice, to: [me, bob], subject: "Trip", id: "t1"),
            message(2, from: me, to: [alice], cc: [bob], subject: "Re: Trip", id: "t1r", replyTo: "t1", refs: ["t1"], folder: "Sent"),
            // Thread 2: same people, and Alice replies to everyone, so it joins the group chat.
            message(3, from: bob, to: [alice, me], subject: "Dinner", id: "t2", seen: false),
            message(30, from: bob, to: [alice, me], subject: "Dinner", id: "t2", seen: false, folder: "Archive"),
            message(7, from: alice, to: [bob, me], subject: "Re: Dinner", id: "t2r", replyTo: "t2", refs: ["t2"], seen: false),
            // 1:1 with Alice.
            message(4, from: alice, to: [me], subject: "Quick question", id: "t3"),
            // A one-off email to several people: nobody replied to the group, so it's in Carol's 1:1 chat.
            message(5, from: carol, to: [me, alice, bob], subject: "Party", id: "t4"),
            // Newsletter.
            message(6, from: MailAddress(email: "news@shop.com"), to: [me], subject: "Sale", id: "n1", automated: true),
        ]
        let chats = ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]])
        #expect(chats.count == 4)

        let group = chats.first { Set($0.participants.map(\.email)) == ["alice@example.com", "bob@example.com"] }
        #expect(group?.messageIDs.count == 4)
        #expect(group?.unreadCount == 2)
        #expect(group?.subjects == ["Dinner", "Trip"])
        #expect(group?.defaultTitle == "Alice & Bob")
        #expect(group?.isGroup == true)
        #expect(group?.isAutomated == false)
        #expect(group?.threads.map(\.subject) == ["Trip", "Dinner"])
        #expect(group?.threads.map(\.replyCount) == [1, 1])

        #expect(!chats.contains { $0.participants.count == 3 })
        let carolChat = chats.first { $0.participants.map(\.email) == ["carol@example.com"] }
        #expect(carolChat?.subjects == ["Party"])
        #expect(chats.contains { $0.participants.map(\.email) == ["alice@example.com"] && $0.subjects == ["Quick question"] })
        // Newsletters are chats too, flagged so the UI can file them under Updates.
        #expect(chats.first { $0.participants.contains { $0.email == "news@shop.com" } }?.isAutomated == true)
    }

    @Test func myEmailToSeveralPeopleShowsInEachChat() {
        let sent = message(1, from: me, to: [alice, bob], subject: "Lunch?", id: "l1", folder: "Sent")
        let chats = ChatBuilder.build(messages: [sent], ownAddresses: [account: ["me@example.com"]])
        #expect(Set(chats.map { $0.participants.map(\.email) }) == [["alice@example.com"], ["bob@example.com"]])
        #expect(chats.allSatisfy { $0.messageIDs == [sent.id] })
    }

    @Test func privateReplyKeepsThreadInOneToOneChats() {
        let messages = [
            message(1, from: me, to: [alice, bob], subject: "Lunch?", id: "l1", folder: "Sent"),
            // Alice answers only me: still not a group conversation.
            message(2, from: alice, to: [me], subject: "Re: Lunch?", id: "l2", replyTo: "l1", refs: ["l1"]),
        ]
        let chats = ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]])
        let aliceChat = chats.first { $0.participants.map(\.email) == ["alice@example.com"] }
        let bobChat = chats.first { $0.participants.map(\.email) == ["bob@example.com"] }
        #expect(chats.count == 2)
        #expect(aliceChat?.threads.count == 1)
        #expect(aliceChat?.threads.first?.replyCount == 1)
        #expect(bobChat?.threads.first?.replyCount == 0)
        // The same conversation keeps the same thread ID in both chats.
        #expect(aliceChat?.threads.first?.id == bobChat?.threads.first?.id)

        // Once Bob replies to everyone, the whole thread becomes a group chat.
        let groupReply = message(3, from: bob, to: [me, alice], subject: "Re: Lunch?", id: "l3", replyTo: "l1", refs: ["l1"])
        let regrouped = ChatBuilder.build(messages: messages + [groupReply], ownAddresses: [account: ["me@example.com"]])
        #expect(regrouped.count == 1)
        #expect(regrouped.first?.isGroup == true)
        #expect(regrouped.first?.messageIDs.count == 3)
    }

    @Test func threadIDSurvivesMissingRoot() {
        let root = message(1, from: alice, to: [me], subject: "Plan", id: "root")
        let reply = message(2, from: me, to: [alice], subject: "Re: Plan", id: "r1", replyTo: "root", refs: ["root"], folder: "Sent")
        let full = ChatBuilder.build(messages: [root, reply], ownAddresses: [account: ["me@example.com"]])
        let partial = ChatBuilder.build(messages: [reply], ownAddresses: [account: ["me@example.com"]])
        #expect(full.first?.threads.first?.id == partial.first?.threads.first?.id)
        #expect(full.first?.threads.first?.rootID == root.id)
    }

    @Test func mailToYourselfGoesToSelfChat() {
        let note = message(1, from: me, to: [me], subject: "Shopping list", id: "n1", folder: "Sent")
        let chats = ChatBuilder.build(messages: [note], ownAddresses: [account: ["me@example.com"]])
        #expect(chats.count == 1)
        #expect(chats.first?.isSelf == true)
        #expect(chats.first?.id == Chat.makeID(accountID: account, participants: []))
    }

    @Test func repliesToMissingParentStillThreadTogether() {
        let messages = [
            message(1, from: alice, to: [me, bob], subject: "Re: Plan", id: "a", replyTo: "missing", refs: ["missing"]),
            message(2, from: bob, to: [me, alice], subject: "Re: Plan", id: "b", replyTo: "missing", refs: ["missing"]),
        ]
        let chats = ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]])
        #expect(chats.count == 1)
        #expect(chats.first?.participants.count == 2)
    }

    @Test func automatedThreadIncludedOnceIReplied() {
        let support = MailAddress(email: "support@vendor.com")
        let messages = [
            message(1, from: support, to: [me], subject: "Ticket", id: "s1", automated: true),
            message(2, from: me, to: [support], subject: "Re: Ticket", id: "s2", replyTo: "s1", refs: ["s1"]),
        ]
        #expect(ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]]).first?.isAutomated == false)
        #expect(ChatBuilder.build(messages: [messages[0]], ownAddresses: [account: ["me@example.com"]]).first?.isAutomated == true)
        #expect(ChatBuilder.build(messages: [messages[0]], ownAddresses: [account: ["me@example.com"]],
                                  options: .init(includeAutomated: false)).isEmpty)
    }

    @Test func stripsQuotesAndSignatures() {
        let text = """
        Sounds good, see you at 7!

        Bob
        --\u{20}
        Bob Jones | ACME

        On Mon, Feb 3, 2025 at 9:15 AM Alice <alice@example.com> wrote:
        > Dinner tonight?
        """
        #expect(QuoteStripper.strip(text) == "Sounds good, see you at 7!\n\nBob")

        let czech = "Díky!\n\nDne po 3. 2. 2025 v 9:15 odesílatel Alice <alice@example.com> napsal:\n> Ahoj"
        #expect(QuoteStripper.strip(czech) == "Díky!")

        let wrapped = "Yes.\n\nOn Mon, Feb 3, 2025 at 9:15 AM Alice Smith <\nalice@example.com> wrote:\n> Question?"
        #expect(QuoteStripper.strip(wrapped) == "Yes.")

        let outlook = "Agreed.\n\nSent from my iPhone\n\nFrom: Alice <alice@example.com>\nSent: Monday, February 3, 2025 9:15 AM\nTo: Me\nSubject: Plan\n\nOld text"
        #expect(QuoteStripper.strip(outlook) == "Agreed.")

        let onlyQuote = "> everything quoted"
        #expect(QuoteStripper.strip(onlyQuote) == "> everything quoted")
    }

    @Test func cutsHTMLQuotes() {
        let html = #"<div dir="ltr">See below</div><br><div class="gmail_quote"><div>On Mon wrote:</div><blockquote>old</blockquote></div>"#
        #expect(HTMLText.plainText(QuoteStripper.cutHTMLQuote(html)) == "See below")
    }

    @Test func normalizesSubjects() {
        #expect(MessageSummary.normalizeSubject("Re: RE: Fwd: Plan") == "Plan")
        #expect(MessageSummary.normalizeSubject("Odp: AW: Schůzka") == "Schůzka")
        #expect(MessageSummary.normalizeSubject("Re[2]: Status") == "Status")
        #expect(MessageSummary.normalizeSubject("Meeting: Q3 review") == "Meeting: Q3 review")
        #expect(ReplyBuilder.replySubject("RE: Plan") == "Re: Plan")
    }
}

@Suite struct SnippetTests {
    @Test func cleansInlineReplyHeaders() {
        #expect(QuoteStripper.cleanSnippet("Sure thing! On Mon, Feb 3, 2025 at 9:15 AM Alice <a@x.com> wrote: > Can you") == "Sure thing!")
        #expect(QuoteStripper.cleanSnippet("Díky Dne po 3. 2. 2025 v 9:15 Alice napsal(a): > Ahoj") == "Díky")
        #expect(QuoteStripper.cleanSnippet("No quotes here") == "No quotes here")
    }
}
