import Foundation
import Testing
@testable import MailCore

@Suite struct MIMETests {
    static let multipart = """
    From: Alice Example <alice@example.com>
    To: Bob <bob@example.com>, "Carol, C." <carol@example.com>
    Subject: =?iso-8859-1?Q?Caf=E9?= =?iso-8859-1?Q?_menu?=
    Date: Mon, 3 Feb 2025 09:15:00 +0100
    Message-ID: <abc@example.com>
    References: <one@x> <two@x>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    preamble
    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Hi Bob,=0A=C5=BElu=C5=A5ou=C4=8Dk=C3=BD k=C5=AF=C5=88 soft=
    break
    --inner
    Content-Type: text/html; charset=utf-8

    <p>Hi <b>Bob</b></p>
    --inner--
    --outer
    Content-Type: application/pdf; name="report.pdf"
    Content-Disposition: attachment; filename*=UTF-8''r%C3%A9port.pdf
    Content-Transfer-Encoding: base64

    SGVsbG8gUERG
    --outer--
    """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test func parsesNestedMultipart() throws {
        let message = ParsedMessage(data: Data(Self.multipart.utf8))
        #expect(message.subject == "Café menu")
        #expect(message.from.first?.email == "alice@example.com")
        #expect(message.to.map(\.email) == ["bob@example.com", "carol@example.com"])
        #expect(message.to.last?.name == "Carol, C.")
        #expect(message.textBody == "Hi Bob,\nžluťoučký kůň softbreak")
        #expect(message.htmlBody == "<p>Hi <b>Bob</b></p>")
        #expect(message.references == ["one@x", "two@x"])
        #expect(message.messageID == "abc@example.com")
        let attachment = try #require(message.attachments.first)
        #expect(attachment.filename == "réport.pdf")
        #expect(attachment.data == Data("Hello PDF".utf8))
        #expect(message.date == MailDate.makeDate(year: 2025, month: 2, day: 3, hour: 8, minute: 15, second: 0, offset: 0))
    }

    @Test func truncatedPreviewStillYieldsSnippet() {
        // Simulates a partial BODY[TEXT]<0.N> fetch cut in the middle of a base64 part.
        let headers = MIMEHeaders.parse(Data("Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n".utf8))
        let body = "--b1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + Data("Ahoj, jak se máš? Tohle je delší zpráva.".utf8).base64EncodedString().prefix(30)
        let parsed = ParsedMessage(root: MIMEParser.parseBody(Data(body.utf8), headers: headers))
        let snippet = MessageSummary.makeSnippet(parsed)
        #expect(snippet.hasPrefix("Ahoj, jak se m"))
    }

    @Test func decodesEncodedWords() {
        #expect(EncodedWords.decode("=?UTF-8?B?w6E=?= =?UTF-8?B?w6k=?=") == "áé")
        // A multi-byte character split across two encoded words.
        #expect(EncodedWords.decode("=?UTF-8?B?xQ==?= =?UTF-8?B?mQ==?=") == "ř")
        #expect(EncodedWords.decode("Re: =?utf-8?q?Hello_World?= again") == "Re: Hello World again")
        #expect(EncodedWords.decode("plain text") == "plain text")
        #expect(EncodedWords.decode(EncodedWords.encodeIfNeeded("Schůzka v pátek – program")) == "Schůzka v pátek – program")
    }

    @Test func parsesAddressLists() {
        let list = MailAddress.parseList(#"Team: "Doe, John" <john@x.com>, jane@y.org (Jane Y);, =?UTF-8?Q?Ji=C5=99=C3=AD?= <jiri@z.cz>, undisclosed-recipients:;"#)
        #expect(list.map(\.email) == ["john@x.com", "jane@y.org", "jiri@z.cz"])
        #expect(list.map(\.name) == ["Doe, John", "Jane Y", "Jiří"])
        #expect(list[0].shortName == "John")
        #expect(list[2].initials == "J")
    }

    @Test func parsesDates() {
        let expected = Date(timeIntervalSince1970: 784_915_951)
        #expect(MailDate.parseRFC5322("Tue, 15 Nov 1994 08:12:31 -0800 (PST)") == expected.addingTimeInterval(0))
        #expect(MailDate.parseRFC5322("15 Nov 1994 16:12:31 GMT") == expected)
        #expect(MailDate.parseRFC5322("Tue, 15 Nov 94 16:12:31 UT") == expected)
        #expect(MailDate.parseRFC5322("garbage") == nil)
    }

    @Test func htmlToText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;<b>world</b> &amp; friends</p><ul><li>One</li><li>Two</li></ul><!-- hidden --><script>alert(1)</script>Bye&#33; &#x1F600;</body></html>"
        #expect(HTMLText.plainText(html) == "Hello world & friends\n\n• One\n• Two\nBye! 😀")
    }

    @Test func buildsAndReparsesOutgoingMessage() {
        let outgoing = OutgoingMessage(
            from: MailAddress(name: "Honza Kubíta", email: "me@example.com"),
            to: [MailAddress(name: "Doe, Jane", email: "jane@example.com")],
            bcc: [MailAddress(email: "hidden@example.com")],
            subject: "Schůzka zítra",
            body: "Ahoj,\n.leading dot\nřádek " + String(repeating: "dlouhý ", count: 30),
            inReplyTo: "parent@x",
            references: ["root@x", "parent@x"],
            attachments: [OutgoingAttachment(filename: "přehled.txt", mimeType: "text/plain", data: Data("data".utf8))]
        )
        let (data, messageID) = outgoing.render()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("hidden@example.com"))
        #expect(text.split(separator: "\r\n").allSatisfy { $0.count <= 998 })

        let parsed = ParsedMessage(data: data)
        #expect(parsed.subject == "Schůzka zítra")
        #expect(parsed.from.first?.name == "Honza Kubíta")
        #expect(parsed.to.first?.name == "Doe, Jane")
        #expect(parsed.messageID == messageID)
        #expect(parsed.references == ["root@x", "parent@x"])
        #expect(parsed.textBody?.replacingOccurrences(of: "\r\n", with: "\n") == outgoing.body)
        #expect(parsed.attachments.first?.filename == "přehled.txt")
        #expect(outgoing.envelopeRecipients == ["jane@example.com", "hidden@example.com"])
    }

    @Test func dotStuffing() {
        let stuffed = String(decoding: SMTPClient.dotStuffed(Data("a\n.b\r\n..c".utf8)), as: UTF8.self)
        #expect(stuffed == "a\r\n..b\r\n...c\r\n.\r\n")
    }

    @Test func autoDiscoveryParsing() throws {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="example.cz">
        <incomingServer type="imap"><hostname>imap.example.cz</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.example.cz</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username></outgoingServer>
        </emailProvider></clientConfig>
        """
        let result = try #require(AutoDiscovery.parse(Data(xml.utf8)))
        #expect(result.imap == ServerEndpoint(host: "imap.example.cz", port: 993, security: .tls))
        #expect(result.smtp == ServerEndpoint(host: "smtp.example.cz", port: 587, security: .startTLS))
        #expect(result.usernameIsEmail)
    }
}
