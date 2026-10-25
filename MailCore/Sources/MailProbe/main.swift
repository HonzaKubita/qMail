import Foundation
import MailCore

// Connectivity check against real providers: connects, negotiates TLS (including STARTTLS)
// and prints the greeting/capabilities. Never authenticates.
//
//   swift run MailProbe            probe all built-in providers
//   swift run MailProbe imap host port tls|starttls

@main
struct MailProbe {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.count == 4 {
            let values = Array(arguments)
            let security: ConnectionSecurity = values[3] == "starttls" ? .startTLS : (values[3] == "none" ? .none : .tls)
            let endpoint = ServerEndpoint(host: values[1], port: Int(values[2]) ?? 993, security: security)
            await probe(kind: values[0], endpoint: endpoint)
            return
        }
        for provider in MailProvider.allCases {
            guard let imap = provider.imap, let smtp = provider.smtp else { continue }
            await probe(kind: "imap", endpoint: imap)
            await probe(kind: "smtp", endpoint: smtp)
        }
    }

    static func probe(kind: String, endpoint: ServerEndpoint) async {
        let label = "\(kind.uppercased()) \(endpoint.host):\(endpoint.port) [\(endpoint.security.label)]"
        do {
            let result = try await ServerProbe.probe(kind: kind == "smtp" ? .smtp : .imap, endpoint: endpoint)
            print("✅ \(label)\n   \(result)")
        } catch {
            print("❌ \(label)\n   \(error.localizedDescription)")
        }
    }
}
