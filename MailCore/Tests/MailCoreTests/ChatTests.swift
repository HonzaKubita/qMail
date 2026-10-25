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
            // Thread 1 with Alice + Bob, where Bob is only CC'd on the reply.
            message(1, from: alice, to: [me, bob], subject: "Trip", id: "t1"),
            message(2, from: me, to: [alice], cc: [bob], subject: "Re: Trip", id: "t1r", replyTo: "t1", refs: ["t1"], folder: "Sent"),
            // Thread 2, same people, new subject: lands in the same chat.
            message(3, from: bob, to: [alice, me], subject: "Dinner", id: "t2", seen: false),
            // Same message also present in another folder; must not be duplicated.
            message(30, from: bob, to: [alice, me], subject: "Dinner", id: "t2", seen: false, folder: "Archive"),
            // 1:1 with Alice.
            message(4, from: alice, to: [me], subject: "Quick question", id: "t3"),
            // Group with Carol added.
            message(5, from: carol, to: [me, alice, bob], subject: "Party", id: "t4"),
            // Newsletter.
            message(6, from: MailAddress(email: "news@shop.com"), to: [me], subject: "Sale", id: "n1", automated: true),
        ]
        let chats = ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]])
        #expect(chats.count == 3)

        let group = chats.first { Set($0.participants.map(\.email)) == ["alice@example.com", "bob@example.com"] }
        #expect(group?.messageIDs.count == 3)
        #expect(group?.unreadCount == 1)
        #expect(group?.subjects == ["Dinner", "Trip"])
        #expect(group?.defaultTitle == "Alice & Bob")
        #expect(group?.isGroup == true)

        #expect(chats.first?.participants.count == 3)
        #expect(chats.contains { $0.participants.map(\.email) == ["alice@example.com"] && !$0.isGroup })
        #expect(!chats.contains { $0.participants.contains { $0.email == "news@shop.com" } })
    }

    @Test func repliesToMissingParentStillThreadTogether() {
        let messages = [
            message(1, from: alice, to: [me, bob], subject: "Re: Plan", id: "a", replyTo: "missing", refs: ["missing"]),
            message(2, from: bob, to: [me], subject: "Re: Plan", id: "b", replyTo: "missing", refs: ["missing"]),
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
        #expect(ChatBuilder.build(messages: messages, ownAddresses: [account: ["me@example.com"]]).count == 1)
        #expect(ChatBuilder.build(messages: [messages[0]], ownAddresses: [account: ["me@example.com"]]).isEmpty)
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
