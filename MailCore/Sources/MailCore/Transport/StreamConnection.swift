import Foundation

/// A buffered byte stream to a mail server.
///
/// Built on `URLSessionStreamTask` rather than Network.framework because it can upgrade an
/// established plaintext connection to TLS, which STARTTLS (iCloud and Outlook SMTP) requires.
actor StreamConnection {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private var head = 0
    private var reachedEOF = false

    init(host: String, port: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Starts TLS once all pending reads and writes have completed.
    func startTLS() {
        task.startSecureConnection()
    }

    func write(_ data: Data, timeout: TimeInterval = 60) async throws {
        do {
            try await task.write(data, timeout: timeout)
        } catch {
            throw Self.map(error)
        }
    }

    func write(_ string: String, timeout: TimeInterval = 60) async throws {
        try await write(Data(string.utf8), timeout: timeout)
    }

    /// Reads one line, returning it without the trailing CRLF (or bare LF).
    func readLine(timeout: TimeInterval = 60) async throws -> Data {
        var scanFrom = head
        while true {
            if let lf = buffer[scanFrom..<buffer.endIndex].firstIndex(of: 0x0A) {
                var end = lf
                if end > head, buffer[end - 1] == 0x0D { end -= 1 }
                let line = buffer.subdata(in: head..<end)
                head = lf + 1
                compactIfNeeded()
                return line
            }
            scanFrom = buffer.endIndex
            try await fill(timeout: timeout)
        }
    }

    func readBytes(_ count: Int, timeout: TimeInterval = 60) async throws -> Data {
        while buffer.count - head < count {
            try await fill(timeout: timeout)
        }
        let data = buffer.subdata(in: head..<(head + count))
        head += count
        compactIfNeeded()
        return data
    }

    func close() {
        task.cancel()
        session.invalidateAndCancel()
    }

    private func compactIfNeeded() {
        guard head > 0 else { return }
        if head == buffer.count {
            buffer = Data()
            head = 0
        } else if head > 1 << 16 {
            buffer = buffer.subdata(in: head..<buffer.count)
            head = 0
        }
    }

    private func fill(timeout: TimeInterval) async throws {
        if reachedEOF { throw MailError.connectionClosed }
        let result: (Data?, Bool)
        do {
            result = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout)
        } catch {
            throw Self.map(error)
        }
        let (data, eof) = result
        if let data { buffer.append(data) }
        if eof {
            reachedEOF = true
            if data?.isEmpty ?? true { throw MailError.connectionClosed }
        }
    }

    private static func map(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return MailError.timeout
        }
        return error
    }
}
