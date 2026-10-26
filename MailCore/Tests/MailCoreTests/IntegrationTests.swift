import Foundation
import Testing
@testable import MailCore

/// Runs against Tools/fake_mail_server.py. Start it, then: QMAIL_FAKE_SERVER=1 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QMAIL_FAKE_SERVER"] != nil))
struct IntegrationTests {
    let imap = IMAPClient(endpoint: ServerEndpoint(host: "127.0.0.1", port: 1143, security: .none)) {
        .password(username: "me@qmail.test", password: "secret \"quoted\"")
    }

    @Test func syncSearchAndFlags() async throws {
        let mailboxes = try await imap.listMailboxes()
        let list = Mailbox.makeList(from: mailboxes, accountID: UUID(), provider: .other)
        #expect(list.first?.role == .inbox)
        #expect(list.contains { $0.role == .sent && $0.path == "Sent" })
        #expect(list.contains { $0.name == "Projects / Koš" })

        let info = try await imap.select("INBOX")
        #expect(info.exists > 5)
        #expect(info.uidValidity > 0)

        let fetched = try await imap.fetchSummaries(in: "INBOX", sequenceRange: 1...info.exists)
        #expect(fetched.count == info.exists)
        let summaries = fetched.map { MessageSummary(fetched: $0, accountID: UUID(), mailboxPath: "INBOX") }
        let offsite = try #require(summaries.first { $0.subject == "Team offsite planning" })
        #expect(offsite.hasAttachments)
        #expect(offsite.snippet.hasPrefix("Hi team,"))
        #expect(summaries.contains { $0.subject == "Faktura za září" && $0.from.first?.name == "Carol Dvořáková" })
        #expect(summaries.filter(\.isAutomated).count >= 3)

        let raw = try await imap.fetchRawMessages(in: "INBOX", uids: [offsite.uid])
        let parsed = ParsedMessage(data: try #require(raw[offsite.uid]))
        #expect(parsed.attachments.first?.filename == "Offsite agenda.pdf")
        #expect(QuoteStripper.chatText(for: parsed).hasSuffix("Dave"))

        let hits = try await imap.search(in: "INBOX", text: "ramen")
        #expect(!hits.isEmpty)

        let newer = try await imap.fetchSummaries(in: "INBOX", fromUID: (fetched.map(\.uid).max() ?? 0) + 1)
        #expect(newer.isEmpty)

        try await imap.setFlags(["\\Flagged"], add: true, uids: [offsite.uid], in: "INBOX")
        let flags = try await imap.fetchFlags(in: "INBOX", uidRange: offsite.uid...offsite.uid)
        #expect(flags[offsite.uid]?.contains("\\Flagged") == true)
        try await imap.setFlags(["\\Flagged"], add: false, uids: [offsite.uid], in: "INBOX")
        await imap.disconnect()
    }

    @Test func sendsOverSMTP() async throws {
        let smtp = SMTPClient(endpoint: ServerEndpoint(host: "127.0.0.1", port: 1025, security: .none)) {
            .password(username: "me@qmail.test", password: "x")
        }
        let message = OutgoingMessage(
            from: MailAddress(name: "Me", email: "me@qmail.test"),
            to: [MailAddress(email: "alice@example.com")],
            subject: "Integration test",
            body: ".starts with a dot\nsecond line"
        )
        try await smtp.send(message.render().data, from: "me@qmail.test", to: message.envelopeRecipients)
    }
}
