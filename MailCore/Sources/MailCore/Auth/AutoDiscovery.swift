import Foundation

/// Looks up server settings for custom domains in Mozilla's public ISP database
/// (the same source Thunderbird uses). Only the domain is sent, never the full address.
public enum AutoDiscovery {
    public struct Result: Sendable {
        public var imap: ServerEndpoint
        public var smtp: ServerEndpoint
        /// Whether the username is the full email address (vs. the local part).
        public var usernameIsEmail: Bool
    }

    public static func discover(email: String) async -> Result? {
        guard let domain = email.split(separator: "@").last.map(String.init)?.lowercased(), !domain.isEmpty,
              let url = URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Result? {
        let delegate = ConfigParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let imap = delegate.servers.first(where: { $0.type == "imap" }),
              let smtp = delegate.servers.first(where: { $0.type == "smtp" }),
              let imapEndpoint = imap.endpoint, let smtpEndpoint = smtp.endpoint else { return nil }
        return Result(imap: imapEndpoint, smtp: smtpEndpoint, usernameIsEmail: imap.username != "%EMAILLOCALPART%")
    }

    private final class ConfigParser: NSObject, XMLParserDelegate {
        struct Server {
            var type = ""
            var hostname = ""
            var port = 0
            var socketType = ""
            var username = ""

            var endpoint: ServerEndpoint? {
                guard !hostname.isEmpty, port > 0 else { return nil }
                let security: ConnectionSecurity = switch socketType.uppercased() {
                case "SSL": .tls
                case "STARTTLS": .startTLS
                default: .none
                }
                return ServerEndpoint(host: hostname, port: port, security: security)
            }
        }

        var servers: [Server] = []
        private var current: Server?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "incomingServer" || elementName == "outgoingServer" {
                current = Server(type: attributeDict["type"] ?? "")
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "hostname": current?.hostname = value
            case "port": current?.port = Int(value) ?? 0
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "incomingServer", "outgoingServer":
                if let current { servers.append(current) }
                current = nil
            default: break
            }
        }
    }
}
