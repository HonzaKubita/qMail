import Foundation

public struct IMAPMailbox: Sendable, Hashable {
    /// Raw (modified UTF-7) name used in commands.
    public var path: String
    public var delimiter: String?
    /// Lowercased attributes, e.g. `\sent`, `\noselect`.
    public var attributes: Set<String>

    public var isSelectable: Bool {
        !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
    }

    public var decodedPath: String { ModifiedUTF7.decode(path) }

    public var displayName: String {
        let decoded = decodedPath
        guard let delimiter, !delimiter.isEmpty else { return decoded }
        return decoded.components(separatedBy: delimiter).last ?? decoded
    }
}

public struct SelectInfo: Sendable, Equatable {
    public var exists: Int = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32?
}

/// A single IMAP connection. Commands are serialized; the connection is opened lazily and
/// re-established automatically if the server dropped it.
public actor IMAPClient {
    public static let previewBytes = 2048
    static let summaryHeaderFields = [
        "DATE", "FROM", "TO", "CC", "REPLY-TO", "SUBJECT", "MESSAGE-ID", "IN-REPLY-TO", "REFERENCES",
        "CONTENT-TYPE", "CONTENT-TRANSFER-ENCODING", "LIST-ID", "LIST-UNSUBSCRIBE", "PRECEDENCE",
        "AUTO-SUBMITTED", "X-AUTOREPLY",
    ]

    private let endpoint: ServerEndpoint
    private let authProvider: MailAuthProvider
    private var connection: StreamConnection?
    private var tagCounter = 0
    private var selectedPath: String?
    public private(set) var capabilities: Set<String> = []

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(endpoint: ServerEndpoint, authProvider: @escaping MailAuthProvider) {
        self.endpoint = endpoint
        self.authProvider = authProvider
    }

    // MARK: - Public API

    /// Connects and authenticates; useful to validate account settings.
    public func connect() async throws {
        try await serialized(retry: false) {}
    }

    public func disconnect() async {
        await lock()
        defer { unlock() }
        if connection != nil {
            _ = try? await execute("LOGOUT")
        }
        dropConnection()
    }

    public func listMailboxes() async throws -> [IMAPMailbox] {
        try await serialized {
            let result = try await self.execute(#"LIST "" "*""#)
            return result.untagged.compactMap { response -> IMAPMailbox? in
                guard case .list(let attributes, let delimiter, let name) = response, !name.isEmpty else { return nil }
                return IMAPMailbox(path: name, delimiter: delimiter, attributes: Set(attributes.map { $0.lowercased() }))
            }
        }
    }

    /// Selects a mailbox, returning fresh counts.
    public func select(_ path: String) async throws -> SelectInfo {
        try await serialized { try await self.selectNow(path) }
    }

    /// Summaries for a range of sequence numbers (used for the initial window of newest mail).
    public func fetchSummaries(in path: String, sequenceRange: ClosedRange<Int>) async throws -> [FetchedMessage] {
        try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("FETCH \(sequenceRange.lowerBound):\(sequenceRange.upperBound) \(self.summaryItems())")
            return Self.fetchedMessages(from: result.untagged)
        }
    }

    /// Summaries for all messages with UID >= `firstUID`.
    public func fetchSummaries(in path: String, fromUID firstUID: UInt32) async throws -> [FetchedMessage] {
        try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID FETCH \(firstUID):* \(self.summaryItems())")
            // "n:*" always matches the last message, even if its UID is lower than n.
            return Self.fetchedMessages(from: result.untagged).filter { $0.uid >= firstUID }
        }
    }

    public func fetchSummaries(in path: String, uids: [UInt32]) async throws -> [FetchedMessage] {
        guard !uids.isEmpty else { return [] }
        return try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID FETCH \(Self.uidSet(uids)) \(self.summaryItems())")
            return Self.fetchedMessages(from: result.untagged)
        }
    }

    /// Current flags for a UID range; messages missing from the result have been deleted.
    public func fetchFlags(in path: String, uidRange: ClosedRange<UInt32>) async throws -> [UInt32: [String]] {
        try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID FETCH \(uidRange.lowerBound):\(uidRange.upperBound) (UID FLAGS)")
            var flags: [UInt32: [String]] = [:]
            for message in Self.fetchedMessages(from: result.untagged) where uidRange.contains(message.uid) {
                flags[message.uid] = message.flags
            }
            return flags
        }
    }

    /// Full RFC 822 source of messages, without setting `\Seen`.
    public func fetchRawMessages(in path: String, uids: [UInt32]) async throws -> [UInt32: Data] {
        guard !uids.isEmpty else { return [:] }
        return try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID FETCH \(Self.uidSet(uids)) (UID BODY.PEEK[])")
            var messages: [UInt32: Data] = [:]
            for message in Self.fetchedMessages(from: result.untagged) {
                if let data = message.rawData { messages[message.uid] = data }
            }
            return messages
        }
    }

    public func setFlags(_ flags: [String], add: Bool, uids: [UInt32], in path: String) async throws {
        guard !uids.isEmpty else { return }
        try await serialized {
            try await self.selectIfNeeded(path)
            let operation = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
            try await self.execute("UID STORE \(Self.uidSet(uids)) \(operation) (\(flags.joined(separator: " ")))")
        }
    }

    public func move(uids: [UInt32], from path: String, to destination: String) async throws {
        guard !uids.isEmpty else { return }
        try await serialized(retry: false) {
            try await self.selectIfNeeded(path)
            let set = Self.uidSet(uids)
            if self.capabilities.contains("MOVE") {
                try await self.execute("UID MOVE \(set) \(Self.quote(destination))")
            } else {
                try await self.execute("UID COPY \(set) \(Self.quote(destination))")
                try await self.execute("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
                if self.capabilities.contains("UIDPLUS") {
                    try await self.execute("UID EXPUNGE \(set)")
                } else {
                    try await self.execute("EXPUNGE")
                }
            }
        }
    }

    /// Permanently removes messages (used inside Trash).
    public func expunge(uids: [UInt32], in path: String) async throws {
        guard !uids.isEmpty else { return }
        try await serialized(retry: false) {
            try await self.selectIfNeeded(path)
            let set = Self.uidSet(uids)
            try await self.execute("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if self.capabilities.contains("UIDPLUS") {
                try await self.execute("UID EXPUNGE \(set)")
            } else {
                try await self.execute("EXPUNGE")
            }
        }
    }

    public func append(_ message: Data, to path: String, flags: [String] = ["\\Seen"]) async throws {
        try await serialized(retry: false) {
            let command = "APPEND \(Self.quote(path)) (\(flags.joined(separator: " "))) {\(message.count)}"
            try await self.execute(command) { index, _ in index == 0 ? message : Data() }
        }
    }

    /// Every UID in a mailbox, for finding which messages a local index is missing.
    public func allUIDs(in path: String) async throws -> [UInt32] {
        try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID SEARCH ALL")
            return result.untagged.flatMap { response -> [UInt32] in
                if case .search(let uids) = response { return uids }
                return []
            }
        }
    }

    /// Headers plus the first `maxBytes` of each body: the text of nearly any email, usually without its attachments.
    public func fetchTextPreviews(in path: String, uids: [UInt32], maxBytes: Int) async throws -> [FetchedMessage] {
        guard !uids.isEmpty else { return [] }
        return try await serialized {
            try await self.selectIfNeeded(path)
            let result = try await self.execute("UID FETCH \(Self.uidSet(uids)) (UID BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.\(maxBytes)>)")
            return Self.fetchedMessages(from: result.untagged)
        }
    }

    /// Server-side search; returns matching UIDs.
    public func search(in path: String, text: String) async throws -> [UInt32] {
        try await serialized {
            try await self.selectIfNeeded(path)
            let escaped = Self.quote(text)
            let command: String
            if self.capabilities.contains("X-GM-EXT-1") {
                command = "UID SEARCH X-GM-RAW \(escaped)"
            } else {
                command = "UID SEARCH CHARSET UTF-8 OR OR SUBJECT \(escaped) FROM \(escaped) BODY \(escaped)"
            }
            let result = try await self.execute(command)
            return result.untagged.flatMap { response -> [UInt32] in
                if case .search(let uids) = response { return uids }
                return []
            }
        }
    }

    /// Waits with IMAP IDLE until the mailbox changes or `timeout` passes. Returns true on a change.
    /// Throws `commandFailed` if the server doesn't support IDLE.
    public func idle(in path: String, timeout: TimeInterval) async throws -> Bool {
        try await serialized(retry: false) {
            guard self.capabilities.contains("IDLE") else { throw MailError.commandFailed("IDLE is not supported.") }
            try await self.selectIfNeeded(path)
            guard let conn = self.connection else { throw MailError.connectionClosed }
            self.tagCounter += 1
            let tag = "Q\(self.tagCounter)"
            var changed = false
            do {
                try await conn.write("\(tag) IDLE\r\n")
                waitForContinuation: while true {
                    switch try IMAPResponseParser.parse(try await self.readResponse(conn)) {
                    case .continuation: break waitForContinuation
                    case .tagged(let responseTag, _, _, let text) where responseTag == tag: throw MailError.commandFailed(text)
                    default: continue
                    }
                }
                let deadline = Date().addingTimeInterval(timeout)
                while !changed, deadline.timeIntervalSinceNow > 0 {
                    let response = try IMAPResponseParser.parse(try await conn.readLine(timeout: deadline.timeIntervalSinceNow))
                    if case .untagged(let item) = response {
                        switch item {
                        case .exists, .expunge, .fetch, .recent: changed = true
                        default: break
                        }
                    }
                }
                try await conn.write("DONE\r\n")
                while true {
                    if case .tagged(let responseTag, _, _, _) = try IMAPResponseParser.parse(try await self.readResponse(conn)),
                       responseTag == tag { break }
                }
            } catch MailError.timeout {
                // A timed-out read leaves the stream in an unknown state; start fresh next time.
                self.dropConnection()
            } catch let error as MailError {
                if case .commandFailed = error {} else { self.dropConnection() }
                throw error
            } catch {
                self.dropConnection()
                throw error
            }
            return changed
        }
    }

    /// Closes the connection immediately, interrupting a pending IDLE.
    public func abort() {
        dropConnection()
    }

    // MARK: - Serialization

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func serialized<T: Sendable>(retry: Bool = true, _ body: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        do {
            try await ensureConnected()
            return try await body()
        } catch let error where retry && MailError.isConnectionLevel(error) {
            _ = error
            // Servers drop idle connections; try once more on a fresh one.
            dropConnection()
            try await ensureConnected()
            return try await body()
        }
    }

    // MARK: - Connection

    private func ensureConnected() async throws {
        guard connection == nil else { return }
        let conn = StreamConnection(host: endpoint.host, port: endpoint.port)
        connection = conn
        selectedPath = nil
        capabilities = []
        do {
            if endpoint.security == .tls { await conn.startTLS() }
            let greeting = try IMAPResponseParser.parse(try await conn.readLine(timeout: 30))
            guard case .untagged(.status(let status, let code, _)) = greeting, status == .ok || status == .preauth else {
                throw MailError.protocolError("Unexpected greeting")
            }
            if let code { applyCapabilityCode(code) }

            if endpoint.security == .startTLS {
                try await execute("STARTTLS")
                await conn.startTLS()
                capabilities = []
            }
            if capabilities.isEmpty { try await refreshCapabilities() }
            if status != .preauth {
                try await authenticate()
                try await refreshCapabilities()
            }
        } catch {
            dropConnection()
            throw error
        }
    }

    private func authenticate() async throws {
        let auth = try await authProvider()
        var serverDetail: String?
        do {
            switch auth {
            case .oauth2:
                let payload = auth.xoauth2Payload ?? ""
                if capabilities.contains("SASL-IR") {
                    // On failure the server sends a JSON error as a continuation; answer with an empty line.
                    try await execute("AUTHENTICATE XOAUTH2 \(payload)", redact: true) { _, text in
                        serverDetail = Self.xoauth2ErrorDetail(text)
                        return Data()
                    }
                } else {
                    try await execute("AUTHENTICATE XOAUTH2", redact: true) { index, text in
                        if index == 0 { return Data(payload.utf8) }
                        serverDetail = Self.xoauth2ErrorDetail(text)
                        return Data()
                    }
                }
            case .password(let username, let password):
                if !capabilities.contains("LOGINDISABLED"), Self.isQuotable(username), Self.isQuotable(password) {
                    try await execute("LOGIN \(Self.quote(username)) \(Self.quote(password))", redact: true)
                } else {
                    let payload = auth.plainPayload ?? ""
                    try await execute("AUTHENTICATE PLAIN", redact: true) { index, _ in index == 0 ? Data(payload.utf8) : Data() }
                }
            }
        } catch MailError.commandFailed(let message) {
            throw MailError.authenticationFailed(serverDetail.map { "\(message) — \($0)" } ?? message)
        }
    }

    /// Decodes the base64 JSON a server sends when an XOAUTH2 token is refused,
    /// e.g. `{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}`.
    static func xoauth2ErrorDetail(_ text: String) -> String? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespaces)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts: [String] = []
        if let status = json["status"] { parts.append("status \(status)") }
        if let scope = json["scope"] { parts.append("requires scope \(scope)") }
        return parts.isEmpty ? nil : "server says: " + parts.joined(separator: ", ")
    }

    private func refreshCapabilities() async throws {
        let result = try await execute("CAPABILITY")
        for response in result.untagged {
            if case .capability(let caps) = response { capabilities = Set(caps) }
        }
    }

    private func applyCapabilityCode(_ code: String) {
        let parts = code.split(separator: " ").map { $0.uppercased() }
        if parts.first == "CAPABILITY" { capabilities = Set(parts.dropFirst()) }
    }

    private func dropConnection() {
        if let connection {
            Task { await connection.close() }
        }
        connection = nil
        selectedPath = nil
    }

    // MARK: - Commands

    private struct CommandResult {
        var untagged: [IMAPUntagged]
        var code: String?
        var text: String
    }

    @discardableResult
    private func execute(
        _ command: String,
        redact: Bool = false,
        continuation: ((Int, String) throws -> Data)? = nil
    ) async throws -> CommandResult {
        guard let conn = connection else { throw MailError.connectionClosed }
        tagCounter += 1
        let tag = "Q\(tagCounter)"
        do {
            try await conn.write("\(tag) \(command)\r\n")
            var untagged: [IMAPUntagged] = []
            var continuationIndex = 0
            while true {
                let response = try IMAPResponseParser.parse(try await readResponse(conn))
                switch response {
                case .untagged(let item):
                    if case .capability(let caps) = item { capabilities = Set(caps) }
                    untagged.append(item)
                case .continuation(let text):
                    guard let continuation else { throw MailError.protocolError("Unexpected continuation") }
                    var payload = try continuation(continuationIndex, text)
                    continuationIndex += 1
                    payload.append(contentsOf: [13, 10])
                    try await conn.write(payload, timeout: max(60, Double(payload.count) / 20_000))
                case .tagged(let responseTag, let status, let code, let text):
                    guard responseTag == tag else { continue }
                    if let code { applyCapabilityCode(code) }
                    if status == .ok { return CommandResult(untagged: untagged, code: code, text: text) }
                    let verb = redact ? String(command.split(separator: " ").first ?? "") : command
                    throw MailError.commandFailed(text.isEmpty ? "\(verb) failed (\(status.rawValue))" : text)
                }
            }
        } catch let error as MailError {
            if case .commandFailed = error {} else { dropConnection() }
            throw error
        } catch {
            dropConnection()
            throw error
        }
    }

    /// Reads one complete response, including any literals it contains.
    private func readResponse(_ conn: StreamConnection) async throws -> Data {
        var result = Data()
        while true {
            let line = try await conn.readLine()
            result.append(line)
            guard let length = IMAPResponseParser.trailingLiteralLength(line) else { return result }
            result.append(contentsOf: [13, 10])
            result.append(try await conn.readBytes(length))
        }
    }

    @discardableResult
    private func selectNow(_ path: String) async throws -> SelectInfo {
        selectedPath = nil
        let result = try await execute("SELECT \(Self.quote(path))")
        var info = SelectInfo()
        for response in result.untagged {
            switch response {
            case .exists(let count):
                info.exists = count
            case .status(_, let code?, _):
                let parts = code.split(separator: " ")
                if parts.count == 2, let value = UInt32(parts[1]) {
                    if parts[0].uppercased() == "UIDVALIDITY" { info.uidValidity = value }
                    if parts[0].uppercased() == "UIDNEXT" { info.uidNext = value }
                }
            default:
                break
            }
        }
        selectedPath = path
        return info
    }

    private func selectIfNeeded(_ path: String) async throws {
        if selectedPath != path { try await selectNow(path) }
    }

    private func summaryItems() -> String {
        var items = "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(Self.summaryHeaderFields.joined(separator: " ")))] BODY.PEEK[TEXT]<0.\(Self.previewBytes)>"
        if capabilities.contains("X-GM-EXT-1") { items += " X-GM-THRID" }
        return "(\(items))"
    }

    static func fetchedMessages(from responses: [IMAPUntagged]) -> [FetchedMessage] {
        var byUID: [UInt32: FetchedMessage] = [:]
        var order: [UInt32] = []
        for response in responses {
            guard case .fetch(let sequence, let attributes) = response,
                  let uid = attributes["UID"]?.string.flatMap({ UInt32($0) }) else { continue }
            var message = byUID[uid] ?? FetchedMessage(uid: uid, sequence: sequence)
            if byUID[uid] == nil { order.append(uid) }
            if let flags = attributes["FLAGS"]?.list { message.flags = flags.compactMap(\.string) }
            if let date = attributes["INTERNALDATE"]?.string { message.internalDate = MailDate.parseInternalDate(date) }
            if let size = attributes["RFC822.SIZE"]?.int { message.size = size }
            if let thread = attributes["X-GM-THRID"]?.string { message.gmailThreadID = thread }
            for (key, value) in attributes where key.hasPrefix("BODY[") {
                let section = Self.section(of: key)
                if section.hasPrefix("HEADER") {
                    message.headerData = value.data
                } else if section == "TEXT" {
                    message.previewData = value.data
                } else if section.isEmpty {
                    message.rawData = value.data
                }
            }
            byUID[uid] = message
        }
        return order.compactMap { byUID[$0] }
    }

    private static func section(of key: String) -> String {
        guard let open = key.firstIndex(of: "["), let close = key.lastIndex(of: "]"), open < close else { return "" }
        return String(key[key.index(after: open)..<close])
    }

    // MARK: - Formatting helpers

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func isQuotable(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// Compresses UIDs into an IMAP sequence set such as `1:5,8,10:12`.
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        guard var start = sorted.first else { return "" }
        var previous = start
        var ranges: [String] = []
        for uid in sorted.dropFirst() {
            if uid == previous + 1 {
                previous = uid
                continue
            }
            ranges.append(start == previous ? "\(start)" : "\(start):\(previous)")
            start = uid
            previous = uid
        }
        ranges.append(start == previous ? "\(start)" : "\(start):\(previous)")
        return ranges.joined(separator: ",")
    }
}
