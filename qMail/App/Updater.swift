import AppKit
import Foundation
import Observation
import Security

/// Updates from GitHub Releases. Once a day qMail looks at the latest release; when it's newer,
/// the Software Update window shows its notes with Install and Relaunch, Later and Skip This Version.
/// Installing downloads the release's `qMail-<version>.zip`, unpacks it and checks that it's qMail
/// signed by the same team as this copy. qMail is sandboxed and can't replace itself, so it then
/// opens qMail Updater (a helper inside the app that isn't sandboxed) and quits; the helper checks
/// the new copy again, swaps it in and opens it.
@MainActor @Observable
final class Updater {
    struct Release: Decodable, Equatable, Sendable {
        struct Asset: Decodable, Equatable, Sendable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String, release: Release?)
    }

    private(set) var state = State.idle
    /// Bumped when the Software Update window should come forward.
    private(set) var presentation = 0

    var automaticChecks: Bool {
        get {
            access(keyPath: \.automaticChecks)
            return UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.automaticChecks) { UserDefaults.standard.set(newValue, forKey: Keys.automatic) }
        }
    }

    var lastCheck: Date? {
        access(keyPath: \.lastCheck)
        return UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private enum Keys {
        static let automatic = "AutomaticallyCheckForUpdates"
        static let lastCheck = "LastUpdateCheck"
        static let skipped = "SkippedUpdateVersion"
    }

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Unpacked updates wait in folders named like this in the temporary directory.
    nonisolated private static let stagingPrefix = "Update-"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private static var feed: URL {
        #if DEBUG
        // QMAIL_UPDATE_FEED points a Debug build at another release JSON, to try updating.
        if let custom = ProcessInfo.processInfo.environment["QMAIL_UPDATE_FEED"].flatMap(URL.init(string:)) { return custom }
        #endif
        return URL(string: "https://api.github.com/repos/HonzaKubita/qMail/releases/latest")!
    }

    // MARK: - Checking

    /// At launch and then every few hours: at most once a day, quietly unless there's an update.
    func start() {
        guard !started else { return }
        started = true
        Self.removeLeftovers()
        #if DEBUG
        // Debug builds aren't released, so they only check when pointed at a test feed.
        guard ProcessInfo.processInfo.environment["QMAIL_UPDATE_FEED"] != nil else { return }
        #endif
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAutomatically()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Deletes unpacked updates that were never installed (refused, cancelled, or a crash in between),
    /// so no stray copies of qMail stay behind, e.g. in Spotlight.
    nonisolated private static func removeLeftovers() {
        let temporary = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func checkAutomatically() async {
        guard automaticChecks, case .idle = state else { return }
        var due = lastCheck.map { Date().timeIntervalSince($0) >= Self.checkInterval } ?? true
        #if DEBUG
        if ProcessInfo.processInfo.environment["QMAIL_UPDATE_FEED"] != nil { due = true } // every launch while testing
        #endif
        guard due else { return }
        await check(interactive: false)
    }

    /// "Check for Updates…": always says what it found.
    func checkNow() {
        switch state {
        case .checking, .downloading, .installing: presentation += 1
        default: Task { await check(interactive: true) }
        }
    }

    private func check(interactive: Bool) async {
        state = .checking
        if interactive { presentation += 1 }
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            withMutation(keyPath: \.lastCheck) { UserDefaults.standard.set(Date(), forKey: Keys.lastCheck) }
            if Self.isNewer(release.version, than: Self.currentVersion),
               interactive || UserDefaults.standard.string(forKey: Keys.skipped) != release.version {
                state = .available(release)
                presentation += 1
                #if DEBUG
                // QMAIL_UPDATE_INSTALL=1 presses Install and Relaunch, to try the whole update.
                if ProcessInfo.processInfo.environment["QMAIL_UPDATE_INSTALL"] != nil { install(release) }
                #endif
            } else {
                state = interactive ? .upToDate : .idle
            }
        } catch {
            state = interactive ? .failed("Couldn't check for updates: \(error.localizedDescription)", release: nil) : .idle
        }
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }

    // MARK: - Choices

    func later() {
        state = .idle
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        state = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    // MARK: - Installing

    func install(_ release: Release) {
        task?.cancel()
        task = Task { await performInstall(release) }
    }

    private func performInstall(_ release: Release) async {
        let installed = Bundle.main.bundleURL
        if installed.path.contains("/AppTranslocation/") || installed.path.hasPrefix("/Volumes/") {
            state = .failed("qMail can't update itself while it runs from the disk image. Drag it to Applications first.", release: release)
            return
        }
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("qMail") && $0.name.hasSuffix(".zip") }) else {
            state = .failed("Release \(release.tag_name) has no app to install.", release: release)
            return
        }
        state = .downloading(release, progress: 0)
        var staged: URL?
        do {
            let progress = DownloadProgress { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading(let current, _) = self.state, current == release else { return }
                    self.state = .downloading(release, progress: fraction)
                }
            }
            let (file, response) = try await URLSession.shared.download(from: asset.browser_download_url, delegate: progress)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError("The download failed (HTTP \(http.statusCode)).")
            }
            try Task.checkCancellation()
            state = .installing(release)
            let app = try await Self.unpack(file, version: release.version)
            staged = app.deletingLastPathComponent()
            try Task.checkCancellation()
            try handOff(app, replacing: installed)
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .idle
            } else {
                state = .failed(error.localizedDescription, release: release)
            }
        }
    }

    /// Unpacks the zip next to it and checks it holds this app, at that version, signed by this app's team.
    nonisolated private static func unpack(_ zip: URL, version: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory.appending(path: stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: zip) }
            do {
                return try unpack(zip, into: folder, version: version)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    nonisolated private static func unpack(_ zip: URL, into folder: URL, version: String) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError("The download couldn't be unpacked.") }

        let bundleName = Bundle.main.bundleURL.lastPathComponent
        let app = (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            .first { $0.pathExtension == "app" }
        guard let app, let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("The download isn't qMail \(version).") }
        guard let team = CodeSignature.ownTeam(),
              CodeSignature.isSigned(app, bundleID: bundle.bundleIdentifier ?? "", team: team)
        else { throw UpdateError("The download's signature doesn't match this copy of qMail.") }
        // Keep the installed name, e.g. a dev copy called qMailDev.app.
        let renamed = folder.appending(path: bundleName)
        if renamed != app { try FileManager.default.moveItem(at: app, to: renamed) }
        return renamed
    }

    /// Opens qMail Updater to swap in `app` after qMail quits, then quits.
    private func handOff(_ app: URL, replacing installed: URL) throws {
        let helper = installed.appending(path: "Contents/Helpers/qMail Updater.app")
        guard FileManager.default.fileExists(atPath: helper.path) else { throw UpdateError("qMail Updater is missing from this copy of qMail.") }
        // Sandboxed apps can't pass launch arguments, so the helper gets a request file to open.
        let request = app.deletingLastPathComponent().appending(path: "request.qmailupdate")
        let fields: [String: Any] = ["update": app.path, "installed": installed.path, "pid": ProcessInfo.processInfo.processIdentifier]
        try JSONSerialization.data(withJSONObject: fields).write(to: request)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.open([request], withApplicationAt: helper, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                    self.state = .failed("qMail Updater couldn't be opened: \(error.localizedDescription)", release: nil)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Reports a download's progress.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// Code-signature checks, the same ones qMail Updater makes before swapping.
enum CodeSignature {
    /// The team that signed this app; nil for an unsigned or ad-hoc build.
    static func ownTeam() -> String? {
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
    static func isSigned(_ app: URL, bundleID: String, team: String) -> Bool {
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
