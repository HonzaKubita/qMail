import SwiftUI

/// The Software Update window: what's new, then download progress.
struct UpdateView: View {
    @Environment(Updater.self) private var updater
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: updater.state) { _, state in
            if state == .idle { dismissWindow() }
        }
        .onDisappear {
            // Closing the window while an update waits means "Later".
            if case .available = updater.state { updater.later() }
            if case .upToDate = updater.state { updater.later() }
            if case .failed = updater.state { updater.later() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking:
            Text("Checking for updates…")
                .font(.headline)
            ProgressView()
                .progressViewStyle(.linear)
        case .upToDate:
            Text("qMail is up to date")
                .font(.headline)
            Text("Version \(Updater.currentVersion) is the latest.")
                .foregroundStyle(.secondary)
            buttons {
                Button("OK") { updater.later() }
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let release):
            Text("qMail \(release.version) is available")
                .font(.headline)
            Text("You have \(Updater.currentVersion). Installing quits qMail and opens the new version.")
                .foregroundStyle(.secondary)
            if let notes = ReleaseNotes(release.body) {
                ScrollView {
                    Text(notes.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
            buttons {
                Button("Skip This Version") { updater.skip(release) }
                Spacer()
                Button("Later") { updater.later() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let release, let progress):
            Text("Downloading qMail \(release.version)…")
                .font(.headline)
            ProgressView(value: progress)
            buttons {
                Button("Cancel") { updater.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .installing(let release):
            Text("Installing qMail \(release.version)…")
                .font(.headline)
            Text("qMail quits and opens again in a moment.")
                .foregroundStyle(.secondary)
            ProgressView()
                .progressViewStyle(.linear)
        case .failed(let message, let release):
            Label("The update couldn't be installed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            buttons {
                if let release {
                    Button("Download from GitHub…") {
                        NSWorkspace.shared.open(release.html_url)
                        updater.later()
                    }
                }
                Spacer()
                Button("OK") { updater.later() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }
}

/// A release's Markdown notes as plain text with inline styling: headings lose their #, list items get bullets.
private struct ReleaseNotes {
    let text: AttributedString

    init?(_ markdown: String?) {
        guard let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty else { return nil }
        let lines = markdown.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return "**" + trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**" }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "• " + trimmed.dropFirst(2) }
            return line
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        text = (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options)) ?? AttributedString(markdown)
    }
}
