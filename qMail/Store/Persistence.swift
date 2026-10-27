import CryptoKit
import Foundation
import MailCore

struct FolderState: Codable, Sendable {
    var uidValidity: UInt32
    var exists: Int
    var lastSync: Date?
}

/// Everything cached for one account so the app opens instantly and works offline.
struct AccountCache: Codable, Sendable {
    var mailboxes: [Mailbox] = []
    var messages: [String: [MessageSummary]] = [:]
    var folderStates: [String: FolderState] = [:]
}

/// On-disk storage in the app container's Application Support folder.
enum Persistence {
    static let baseURL: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "qMail", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var accountsURL: URL { baseURL.appending(path: "accounts.json") }

    private static func cacheURL(_ accountID: UUID) -> URL {
        baseURL.appending(path: "cache-\(accountID.uuidString).json")
    }

    private static func bodiesURL(_ accountID: UUID) -> URL {
        baseURL.appending(path: "bodies/\(accountID.uuidString)", directoryHint: .isDirectory)
    }

    static func loadAccounts() -> [Account] {
        guard let data = try? Data(contentsOf: accountsURL) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }

    static func loadCache(_ accountID: UUID) -> AccountCache? {
        guard let data = try? Data(contentsOf: cacheURL(accountID)) else { return nil }
        return try? JSONDecoder().decode(AccountCache.self, from: data)
    }

    static func saveCache(_ cache: AccountCache, accountID: UUID) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL(accountID), options: .atomic)
    }

    /// SQLite full-text index of all the account's mail.
    static func searchIndexURL(_ accountID: UUID) -> URL {
        baseURL.appending(path: "search-\(accountID.uuidString).sqlite")
    }

    /// Bytes the search index takes on disk.
    static func searchIndexSize(_ accountID: UUID) -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = searchIndexURL(accountID).path + suffix
            return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    static func deleteData(for accountID: UUID) {
        try? FileManager.default.removeItem(at: cacheURL(accountID))
        try? FileManager.default.removeItem(at: bodiesURL(accountID))
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: searchIndexURL(accountID).path + suffix)
        }
    }

    // MARK: Message bodies

    private static func bodyURL(_ summary: MessageSummary, uidValidity: UInt32) -> URL {
        let folder = SHA256.hash(data: Data(summary.mailboxPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return bodiesURL(summary.accountID).appending(path: "\(folder)/\(uidValidity)-\(summary.uid).eml")
    }

    static func loadBody(_ summary: MessageSummary, uidValidity: UInt32) -> Data? {
        try? Data(contentsOf: bodyURL(summary, uidValidity: uidValidity))
    }

    static func saveBody(_ data: Data, for summary: MessageSummary, uidValidity: UInt32) {
        let url = bodyURL(summary, uidValidity: uidValidity)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Writes an attachment to a temporary file so it can be opened in its default app.
    static func temporaryFile(named filename: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: safeName.isEmpty ? "Attachment" : safeName)
        try data.write(to: url)
        return url
    }
}
