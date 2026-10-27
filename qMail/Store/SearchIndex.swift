import Foundation
import MailCore
import SQLite3

/// How far an account's mail has been downloaded for search.
struct IndexStatus: Equatable, Sendable {
    /// Messages on the server in the indexed folders.
    var total = 0
    /// Messages whose headers are indexed (searchable by subject and people).
    var indexed = 0
    /// Messages whose text is indexed too.
    var withText = 0
    var isRunning = false

    var isComplete: Bool { total > 0 && withText >= total }
}

/// A full-text index of every message in an account, in SQLite with FTS5.
/// Search ignores case and diacritics, so "zamestnanec" finds "zaměstnanec".
actor SearchIndex {
    private var db: OpaquePointer?

    init(url: URL) {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
        }
        for statement in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            """
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY, path TEXT NOT NULL, uid INTEGER NOT NULL, message_id TEXT,
                date REAL NOT NULL, has_text INTEGER NOT NULL DEFAULT 0, summary BLOB NOT NULL)
            """,
            "CREATE INDEX IF NOT EXISTS messages_path ON messages(path, uid)",
            "CREATE INDEX IF NOT EXISTS messages_pending ON messages(has_text, date)",
            "CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, validity INTEGER NOT NULL, total INTEGER NOT NULL)",
            "CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(subject, people, body, tokenize='unicode61 remove_diacritics 2')",
        ] {
            sqlite3_exec(handle, statement, nil, nil, nil)
        }
    }

    isolated deinit { sqlite3_close(db) }

    // MARK: Folders

    /// Starts tracking a folder. A changed UIDVALIDITY means the server renumbered it, so its rows are dropped.
    func prepareFolder(_ path: String, validity: UInt32, total: Int) {
        let known = query("SELECT validity FROM folders WHERE path = ?", [.text(path)]) { sqlite3_column_int64($0, 0) }.first
        if let known, UInt32(truncatingIfNeeded: known) != validity {
            removeMessages(where: "path = ?", [.text(path)])
        }
        run("INSERT INTO folders(path, validity, total) VALUES(?, ?, ?) ON CONFLICT(path) DO UPDATE SET validity = excluded.validity, total = excluded.total",
            [.text(path), .int(Int64(validity)), .int(Int64(total))])
    }

    /// Stops indexing folders that are no longer indexed (e.g. deleted on the server).
    func keepFolders(_ paths: Set<String>) {
        let known = query("SELECT path FROM folders", []) { String(cString: sqlite3_column_text($0, 0)) }
        for path in known where !paths.contains(path) {
            removeMessages(where: "path = ?", [.text(path)])
            run("DELETE FROM folders WHERE path = ?", [.text(path)])
        }
    }

    func indexedUIDs(in path: String) -> Set<UInt32> {
        Set(query("SELECT uid FROM messages WHERE path = ?", [.text(path)]) { UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 0)) })
    }

    /// Drops messages that were deleted on the server.
    func removeUIDs(_ uids: [UInt32], in path: String) {
        for batch in uids.chunked(into: 500) {
            let list = batch.map(String.init).joined(separator: ",")
            removeMessages(where: "path = ? AND uid IN (\(list))", [.text(path)])
        }
    }

    // MARK: Writing

    /// Adds message headers (subject, people and the short preview are searchable right away).
    func add(_ summaries: [MessageSummary]) {
        let encoder = JSONEncoder()
        transaction {
            for summary in summaries {
                guard let blob = try? encoder.encode(summary) else { continue }
                let exists = !query("SELECT 1 FROM messages WHERE id = ?", [.text(summary.id)]) { _ in true }.isEmpty
                run("""
                    INSERT INTO messages(id, path, uid, message_id, date, summary) VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET summary = excluded.summary
                    """,
                    [.text(summary.id), .text(summary.mailboxPath), .int(Int64(summary.uid)),
                     summary.messageID.map { .text($0) } ?? .null, .real(summary.date.timeIntervalSince1970), .blob(blob)])
                guard !exists else { continue }
                let people = (summary.from + summary.to + summary.cc).map { "\($0.name ?? "") \($0.email)" }.joined(separator: " ")
                run("INSERT INTO search(rowid, subject, people, body) SELECT rowid, ?, ?, ? FROM messages WHERE id = ?",
                    [.text(summary.subject), .text(people), .text(summary.snippet), .text(summary.id)])
            }
        }
    }

    /// Messages whose text hasn't been downloaded yet, newest first.
    func messagesNeedingText(limit: Int) -> [(path: String, uid: UInt32)] {
        query("SELECT path, uid FROM messages WHERE has_text = 0 ORDER BY date DESC LIMIT ?", [.int(Int64(limit))]) {
            (String(cString: sqlite3_column_text($0, 0)), UInt32(truncatingIfNeeded: sqlite3_column_int64($0, 1)))
        }
    }

    /// Stores the full text of messages, replacing their short previews.
    func setText(_ texts: [UInt32: String], in path: String, missing: [UInt32]) {
        transaction {
            for (uid, text) in texts {
                run("UPDATE search SET body = ? WHERE rowid = (SELECT rowid FROM messages WHERE path = ? AND uid = ?)",
                    [.text(text), .text(path), .int(Int64(uid))])
                run("UPDATE messages SET has_text = 1 WHERE path = ? AND uid = ?", [.text(path), .int(Int64(uid))])
            }
            // Gone from the server, or unreadable: don't retry forever.
            for uid in missing {
                run("UPDATE messages SET has_text = 1 WHERE path = ? AND uid = ?", [.text(path), .int(Int64(uid))])
            }
        }
    }

    // MARK: Reading

    func status() -> IndexStatus {
        let total = query("SELECT COALESCE(SUM(total), 0) FROM folders", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        let counts = query("SELECT COUNT(*), COALESCE(SUM(has_text), 0) FROM messages", []) {
            (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)))
        }.first ?? (0, 0)
        return IndexStatus(total: total, indexed: counts.0, withText: counts.1)
    }

    /// Newest messages matching every word of `text` (each word also matches as a prefix).
    func search(_ text: String, limit: Int) -> [MessageSummary] {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        let decoder = JSONDecoder()
        return query("""
            SELECT m.summary FROM search JOIN messages m ON m.rowid = search.rowid
            WHERE search MATCH ? ORDER BY m.date DESC LIMIT ?
            """, [.text(match), .int(Int64(limit))]) { statement -> MessageSummary? in
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return try? decoder.decode(MessageSummary.self, from: data)
        }.compactMap { $0 }
    }

    // MARK: SQLite

    private enum Value {
        case text(String), int(Int64), real(Double), blob(Data), null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func removeMessages(where condition: String, _ values: [Value]) {
        run("DELETE FROM search WHERE rowid IN (SELECT rowid FROM messages WHERE \(condition))", values)
        run("DELETE FROM messages WHERE \(condition)", values)
    }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func run(_ sql: String, _ values: [Value]) {
        _ = query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value], row: (OpaquePointer) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }
}
