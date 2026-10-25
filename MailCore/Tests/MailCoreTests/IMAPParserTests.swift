import Foundation
import Testing
@testable import MailCore

@Suite struct IMAPParserTests {
    @Test func parsesFetchWithLiterals() throws {
        let header = "From: \"Doe, Jane\" <jane@example.com>\r\nSubject: =?UTF-8?B?UMWZw61sacWhIMW+bHXFpW91xI1rw70=?=\r\n\r\n"
        let raw = "* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286 "
            + "BODY[HEADER.FIELDS (FROM SUBJECT)] {\(header.utf8.count)}\r\n\(header) BODY[TEXT]<0> {5}\r\nHello X-GM-THRID 1234567890123)"
        let response = try IMAPResponseParser.parse(Data(raw.utf8))
        guard case .untagged(.fetch(let sequence, let attributes)) = response else {
            Issue.record("Expected FETCH, got \(response)")
            return
        }
        #expect(sequence == 12)
        let messages = IMAPClient.fetchedMessages(from: [.fetch(sequence: sequence, attributes: attributes)])
        let message = try #require(messages.first)
        #expect(message.uid == 345)
        #expect(message.flags == ["\\Seen", "\\Flagged"])
        #expect(message.size == 4286)
        #expect(message.gmailThreadID == "1234567890123")
        #expect(message.previewData == Data("Hello".utf8))
        #expect(message.internalDate == Date(timeIntervalSince1970: 837_596_665))

        let summary = MessageSummary(fetched: message, accountID: UUID(), mailboxPath: "INBOX")
        #expect(summary.subject == "Příliš žluťoučký")
        #expect(summary.from.first?.name == "Doe, Jane")
        #expect(summary.isSeen && summary.isFlagged)
    }

    @Test func parsesListResponses() throws {
        let gmail = try IMAPResponseParser.parse(Data(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Odeslan&AOE- po&AWE-ta""#.utf8))
        guard case .untagged(.list(let attributes, let delimiter, let name)) = gmail else {
            Issue.record("Expected LIST")
            return
        }
        #expect(attributes == ["\\HasNoChildren", "\\Sent"])
        #expect(delimiter == "/")
        #expect(ModifiedUTF7.decode(name) == "[Gmail]/Odeslaná pošta")

        let mailboxes = [
            IMAPMailbox(path: name, delimiter: "/", attributes: Set(attributes.map { $0.lowercased() })),
            IMAPMailbox(path: "INBOX", delimiter: "/", attributes: []),
            IMAPMailbox(path: "[Gmail]", delimiter: "/", attributes: ["\\noselect"]),
            IMAPMailbox(path: "Sent", delimiter: "/", attributes: []),
        ]
        let list = Mailbox.makeList(from: mailboxes, accountID: UUID(), provider: .gmail)
        #expect(list.map(\.role) == [.inbox, .sent, .custom])
        #expect(list[1].name == "Odeslaná pošta")

        let nilDelimiter = try IMAPResponseParser.parse(Data(#"* LIST (\Noselect) NIL """#.utf8))
        guard case .untagged(.list(_, let noDelimiter, _)) = nilDelimiter else {
            Issue.record("Expected LIST")
            return
        }
        #expect(noDelimiter == nil)
    }

    @Test func parsesStatusResponses() throws {
        let response = try IMAPResponseParser.parse(Data("* OK [UIDVALIDITY 3857529045] UIDs valid".utf8))
        guard case .untagged(.status(.ok, let code, let text)) = response else {
            Issue.record("Expected status")
            return
        }
        #expect(code == "UIDVALIDITY 3857529045")
        #expect(text == "UIDs valid")

        let tagged = try IMAPResponseParser.parse(Data("Q7 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)".utf8))
        guard case .tagged(let tag, .no, let taggedCode, let taggedText) = tagged else {
            Issue.record("Expected tagged")
            return
        }
        #expect(tag == "Q7")
        #expect(taggedCode == "AUTHENTICATIONFAILED")
        #expect(taggedText == "Invalid credentials (Failure)")
    }

    @Test func literalLengthDetection() {
        #expect(IMAPResponseParser.trailingLiteralLength(Data("* 1 FETCH (BODY[] {1234}".utf8)) == 1234)
        #expect(IMAPResponseParser.trailingLiteralLength(Data("APPEND x {12+}".utf8)) == 12)
        #expect(IMAPResponseParser.trailingLiteralLength(Data("* OK done".utf8)) == nil)
        #expect(IMAPResponseParser.trailingLiteralLength(Data("* OK {abc}".utf8)) == nil)
    }

    @Test func uidSetCompression() {
        #expect(IMAPClient.uidSet([5, 1, 2, 3, 8, 10, 11, 12]) == "1:3,5,8,10:12")
        #expect(IMAPClient.uidSet([7]) == "7")
    }

    @Test func modifiedUTF7RoundTrip() {
        for name in ["Koš", "Odeslaná pošta", "日本語", "A&B", "Plain"] {
            #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name)
        }
        #expect(ModifiedUTF7.encode("A&B") == "A&-B")
    }
}

@Suite struct MailboxListTests {
    @Test func nestsUnderListedParentsAndFoldsHiddenOnes() {
        let raw = [
            IMAPMailbox(path: "INBOX", delimiter: "/", attributes: []),
            IMAPMailbox(path: "Projects", delimiter: "/", attributes: ["\\noselect"]),
            IMAPMailbox(path: "Projects/Ko&AWE-", delimiter: "/", attributes: []),
            IMAPMailbox(path: "Clients", delimiter: "/", attributes: []),
            IMAPMailbox(path: "Clients/ACME", delimiter: "/", attributes: []),
            IMAPMailbox(path: "[Gmail]/All Mail", delimiter: "/", attributes: ["\\all"]),
            IMAPMailbox(path: "[Gmail]/Trash", delimiter: "/", attributes: ["\\trash"]),
        ]
        let list = Mailbox.makeList(from: raw, accountID: UUID(), provider: .gmail)
        let byPath = Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0) })
        #expect(byPath["Projects/Ko&AWE-"]?.name == "Projects / Koš")
        #expect(byPath["Projects/Ko&AWE-"]?.depth == 0)
        #expect(byPath["Clients/ACME"]?.name == "ACME")
        #expect(byPath["Clients/ACME"]?.depth == 1)
        #expect(byPath["[Gmail]/All Mail"]?.role == .all)
        #expect(byPath["[Gmail]/Trash"]?.displayName == "Trash")
    }
}
