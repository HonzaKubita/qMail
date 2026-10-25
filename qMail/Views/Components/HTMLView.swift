import AppKit
import MailCore
import SwiftUI
import WebKit

/// Renders a message body in a locked-down WKWebView: no JavaScript, remote content blocked
/// by a Content-Security-Policy unless allowed, and links open in the default browser.
struct HTMLView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = Self.document(html: html, allowRemote: allowRemoteContent)
        guard context.coordinator.loadedDocument != document else { return }
        context.coordinator.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func document(html: String, allowRemote: Bool) -> String {
        let policy = allowRemote
            ? "default-src 'none'; img-src * data: cid:; style-src * 'unsafe-inline'; font-src * data:; media-src *;"
            : "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:;"
        return """
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html { -webkit-text-size-adjust: none; background: #fff; color: #1d1d1f; }
          body { margin: 16px 20px; font: 14px -apple-system, system-ui, sans-serif; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          pre, code { white-space: pre-wrap; }
          blockquote { margin-left: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,.35); color: rgba(127,127,127,1); }
        </style>
        \(html)
        """
    }

    /// Wraps plain text so it follows the system appearance and makes links clickable.
    static func document(forPlainText text: String) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(escaped.startIndex..., in: escaped)
            for match in detector.matches(in: escaped, range: range).reversed() {
                guard let url = match.url, let swiftRange = Range(match.range, in: escaped) else { continue }
                let label = String(escaped[swiftRange])
                escaped.replaceSubrange(swiftRange, with: "<a href=\"\(url.absoluteString)\">\(label)</a>")
            }
        }
        return """
        <meta name="color-scheme" content="light dark">
        <style>
          :root { color-scheme: light dark; }
          body { background: transparent; color: CanvasText; }
          a { color: LinkText; }
          .text { white-space: pre-wrap; font: 14px/1.45 -apple-system, system-ui, sans-serif; }
        </style>
        <div class="text">\(escaped)</div>
        """
    }

    /// True if the HTML references images or styles on the network.
    static func hasRemoteContent(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("src=\"http") || lower.contains("src='http") || lower.contains("url(http")
            || lower.contains("src=http") || lower.contains("background=\"http")
    }

    /// Replaces `cid:` references with inline data URLs for embedded images.
    static func inlineImages(_ html: String, attachments: [MailAttachment]) -> String {
        var result = html
        for attachment in attachments where attachment.contentID != nil && attachment.data.count < 8_000_000 {
            let cid = attachment.contentID!
            guard result.contains("cid:\(cid)") else { continue }
            let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            result = result.replacingOccurrences(of: "cid:\(cid)", with: dataURL)
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedDocument: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // Only the document we loaded ourselves; blocks meta-refresh redirects and the like.
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
            decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
        }
    }
}
