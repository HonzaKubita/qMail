import AppKit
import Security

// qMail Updater swaps a downloaded copy of qMail into place once qMail has quit, then opens it.
// qMail is sandboxed and can't replace its own app, so after downloading and checking an update
// it opens this helper (which isn't sandboxed, and lives in qMail.app/Contents/Helpers) with a
// request file. Sandboxed apps can't pass launch arguments, so the request is a JSON file
// (request.qmailupdate, a type only this helper opens):
//
//   {"update": "<new qMail.app>", "installed": "<installed qMail.app>", "pid": <qMail's process ID>}
//
// For testing it also takes the same three values as arguments. The new copy is checked again
// here: it must be the same app, signed by the same team as this helper.

struct Request: Decodable {
    let update: String
    let installed: String
    let pid: Int32
}

@MainActor
final class Installer: NSObject, NSApplicationDelegate {
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.count == 4, let pid = Int32(arguments[3]) {
            start(Request(update: arguments[1], installed: arguments[2], pid: pid))
            return
        }
        // The request file arrives as an "open" event; give up if it never comes.
        Task {
            try? await Task.sleep(for: .seconds(15))
            if !started { exit(2) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(2) }
        start(request)
    }

    private func start(_ request: Request) {
        guard !started else { return }
        started = true
        Task { await install(request) }
    }

    private func install(_ request: Request) async {
        let update = URL(filePath: request.update)
        let installed = URL(filePath: request.installed)
        let fileManager = FileManager.default

        // Wait for qMail to quit.
        let deadline = Date().addingTimeInterval(60)
        while kill(request.pid, 0) == 0 {
            if Date() > deadline { fail("qMail didn't quit.", update: update, installed: installed) }
            try? await Task.sleep(for: .milliseconds(200))
        }

        guard let bundleID = Bundle(url: installed)?.bundleIdentifier, Bundle(url: update)?.bundleIdentifier == bundleID else {
            fail("The download isn't qMail.", update: update, installed: installed)
        }
        guard let team = Self.ownTeam(), Self.isSigned(update, bundleID: bundleID, team: team) else {
            fail("The download's signature doesn't match this copy of qMail.", update: update, installed: installed)
        }

        // Swap: keep the old copy until the new one is in place.
        let backup = installed.deletingLastPathComponent().appending(path: installed.lastPathComponent + ".updating")
        try? fileManager.removeItem(at: backup)
        do {
            try fileManager.moveItem(at: installed, to: backup)
        } catch {
            fail("The installed copy couldn't be moved: \(error.localizedDescription)", update: update, installed: installed)
        }
        do {
            try fileManager.moveItem(at: update, to: installed)
        } catch {
            try? fileManager.moveItem(at: backup, to: installed)
            fail("The new version couldn't be moved into place: \(error.localizedDescription)", update: update, installed: installed)
        }
        try? fileManager.removeItem(at: backup)
        try? fileManager.removeItem(at: update.deletingLastPathComponent())

        // The download was checked above, so macOS doesn't need to ask before its first launch.
        let xattr = Process()
        xattr.executableURL = URL(filePath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", installed.path]
        try? xattr.run()
        xattr.waitUntilExit()
        LSRegisterURL(installed as CFURL, true)

        _ = try? await NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration())
        exit(0)
    }

    /// Says what went wrong, opens the copy that's still installed and quits.
    private func fail(_ reason: String, update: URL, installed: URL) -> Never {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "qMail couldn't be updated"
        alert.informativeText = reason + "\n\nYou can download the new version from github.com/HonzaKubita/qMail/releases."
        alert.alertStyle = .warning
        alert.runModal()
        try? FileManager.default.removeItem(at: update.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: installed.path) { NSWorkspace.shared.open(installed) }
        exit(1)
    }

    /// The team that signed this helper; the update must be signed by it too.
    private static func ownTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether `app` has an intact signature from `team` for `bundleID`, including everything inside it.
    private static func isSigned(_ app: URL, bundleID: String, team: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

let installer = Installer()
NSApplication.shared.delegate = installer
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
