import Foundation

/// One email conversation (a message and its replies) inside a chat — a Slack-style thread.
public struct ChatThread: Identifiable, Hashable, Sendable {
    /// Stable across syncs: derived from the thread's root Message-ID, even if the root itself isn't loaded.
    public var id: String
    /// Summary IDs in chronological order; the first one is shown in the chat, the rest as replies.
    public var messageIDs: [String]
    public var subject: String
    public var startDate: Date
    public var lastDate: Date
    public var unreadCount: Int

    public var rootID: String { messageIDs[0] }
    public var replyIDs: ArraySlice<String> { messageIDs.dropFirst() }
    public var replyCount: Int { messageIDs.count - 1 }
}

/// A conversation with a fixed set of people, built from one or more email threads.
public struct Chat: Identifiable, Hashable, Sendable {
    public var id: String
    public var accountID: UUID
    /// Everyone in the conversation except the account owner. Empty for mail to yourself.
    public var participants: [MailAddress]
    /// Summary IDs in chronological order.
    public var messageIDs: [String]
    /// Threads ordered by when they started, like messages in a Slack channel.
    public var threads: [ChatThread]
    public var lastDate: Date
    public var lastMessageID: String
    public var unreadCount: Int
    public var subjects: [String]
    /// Only newsletters, notifications and other automated mail.
    public var isAutomated: Bool

    public var isGroup: Bool { participants.count > 1 }
    public var isSelf: Bool { participants.isEmpty }

    public var defaultTitle: String {
        let names = participants.map(\.shortName)
        switch names.count {
        case 0: return "Me"
        case 1: return participants[0].displayName
        case 2: return "\(names[0]) & \(names[1])"
        case 3: return "\(names[0]), \(names[1]) & \(names[2])"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) others"
        }
    }

    public func thread(containing messageID: String) -> ChatThread? {
        threads.first { $0.messageIDs.contains(messageID) }
    }

    public static func makeID(accountID: UUID, participants: [String]) -> String {
        "\(accountID.uuidString)|" + (participants.isEmpty ? "self" : participants.sorted().joined(separator: ","))
    }
}

/// Groups email into chats: messages are first threaded (References / In-Reply-To / Gmail
/// thread IDs). A thread where someone replied to the group goes to the group chat for exactly
/// those people; any other message goes to the 1:1 chat with its sender (or with each recipient,
/// for mail you sent), so a one-off email to several people doesn't create a group chat.
public enum ChatBuilder {
    public struct Options: Sendable {
        /// Include threads that only contain newsletters, notifications and other automated mail.
        public var includeAutomated = true
        /// Only show conversations the user has written in.
        public var requireOwnMessage = false

        public init(includeAutomated: Bool = true, requireOwnMessage: Bool = false) {
            self.includeAutomated = includeAutomated
            self.requireOwnMessage = requireOwnMessage
        }
    }

    public static func build(messages: [MessageSummary], ownAddresses: [UUID: Set<String>], options: Options = Options()) -> [Chat] {
        // 1. Dedupe copies of the same message across folders (e.g. Inbox and All Mail).
        var unique: [MessageSummary] = []
        var indexByKey: [String: Int] = [:]
        for message in messages.sorted(by: { $0.date < $1.date }) {
            let key = "\(message.accountID.uuidString)|\(message.messageID ?? message.id)"
            if let existing = indexByKey[key] {
                // A copy marked unread anywhere stays unread only if every copy is unread.
                unique[existing].isSeen = unique[existing].isSeen || message.isSeen
                continue
            }
            indexByKey[key] = unique.count
            unique.append(message)
        }

        // 2. Thread with union-find over message IDs.
        var parent: [String: String] = [:]
        func find(_ key: String) -> String {
            var root = key
            while let next = parent[root], next != root { root = next }
            var node = key
            while let next = parent[node], next != root {
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        func nodeKey(_ message: MessageSummary) -> String {
            "\(message.accountID.uuidString)|m:\(message.messageID ?? "local:" + message.id)"
        }

        for message in unique {
            let key = nodeKey(message)
            if parent[key] == nil { parent[key] = key }
            let prefix = "\(message.accountID.uuidString)|"
            for reference in message.references + [message.inReplyTo].compactMap({ $0 }) {
                union(key, prefix + "m:" + reference)
            }
            if let thread = message.gmailThreadID {
                union(key, prefix + "g:" + thread)
            }
        }

        var threads: [String: [MessageSummary]] = [:]
        for message in unique {
            threads[find(nodeKey(message)), default: []].append(message)
        }

        // 3. Place threads into chats. A thread is a group conversation only once someone has
        //    replied to the group; until then each message lives in the 1:1 chat with its sender
        //    (or, for your own messages, with each recipient) and shows who else it went to.
        struct ChatAccumulator {
            var accountID: UUID
            var participants: [String: MailAddress] = [:]
            /// Messages per thread, keyed by the thread's stable root key.
            var threads: [String: [MessageSummary]] = [:]
        }
        var chats: [String: ChatAccumulator] = [:]

        func place(_ messages: [MessageSummary], threadKey: String, with people: [MailAddress], accountID: UUID) {
            var unique: [String: MailAddress] = [:]
            for person in people where unique[person.normalizedEmail]?.name == nil { unique[person.normalizedEmail] = person }
            let chatID = Chat.makeID(accountID: accountID, participants: Array(unique.keys))
            var accumulator = chats[chatID] ?? ChatAccumulator(accountID: accountID)
            accumulator.participants.merge(unique) { existing, new in existing.name == nil ? new : existing }
            accumulator.threads[threadKey, default: []].append(contentsOf: messages)
            chats[chatID] = accumulator
        }

        for (_, threadMessages) in threads {
            guard let accountID = threadMessages.first?.accountID else { continue }
            let mine = ownAddresses[accountID] ?? []
            let isMine: (MessageSummary) -> Bool = { message in
                message.from.contains { mine.contains($0.normalizedEmail) }
            }
            /// Everyone on a message except you, deduplicated.
            let others: (MessageSummary) -> [MailAddress] = { message in
                var seen = Set<String>()
                return (message.from + message.to + message.cc).filter { address in
                    let email = address.normalizedEmail
                    return email.contains("@") && !mine.contains(email) && seen.insert(email).inserted
                }
            }

            let hasHuman = threadMessages.contains { !$0.isAutomated || isMine($0) }
            if !options.includeAutomated && !hasHuman { continue }
            if options.requireOwnMessage && !threadMessages.contains(where: isMine) { continue }

            let sorted = threadMessages.sorted { $0.date < $1.date }
            let root = sorted[0]
            // Replies reference the root's Message-ID first, so this survives loading older mail.
            let threadKey = root.references.first ?? root.inReplyTo ?? root.messageID ?? root.id
            let hasGroupReply = sorted.dropFirst().contains { others($0).count >= 2 }

            if hasGroupReply {
                place(sorted, threadKey: threadKey, with: sorted.flatMap(others), accountID: accountID)
                continue
            }
            for message in sorted {
                let people: [MailAddress]
                if isMine(message) {
                    // Sent by you: shows up in the chat with each recipient.
                    people = others(message)
                } else {
                    people = Array((message.from.first.map { [$0] } ?? others(message)).prefix(1))
                }
                if people.isEmpty {
                    // Mail to yourself goes to your own "(you)" chat.
                    place([message], threadKey: threadKey, with: [], accountID: accountID)
                }
                for person in people {
                    place([message], threadKey: threadKey, with: [person], accountID: accountID)
                }
            }
        }

        // 4. Finalize.
        var result: [Chat] = []
        for (chatID, accumulator) in chats {
            let mine = ownAddresses[accumulator.accountID] ?? []
            let isUnread: (MessageSummary) -> Bool = { message in
                !message.isSeen && !message.from.contains { mine.contains($0.normalizedEmail) }
            }

            let chatThreads: [ChatThread] = accumulator.threads.map { threadKey, messages in
                let sorted = messages.sorted { $0.date < $1.date }
                let root = sorted[0]
                let subject = sorted.lazy.map(\.normalizedSubject).first { !$0.isEmpty } ?? ""
                return ChatThread(
                    id: "\(accumulator.accountID.uuidString)|t:\(threadKey)",
                    messageIDs: sorted.map(\.id),
                    subject: subject,
                    startDate: root.date,
                    lastDate: sorted.last?.date ?? root.date,
                    unreadCount: sorted.filter(isUnread).count
                )
            }
            .sorted { $0.startDate < $1.startDate }

            let all = accumulator.threads.values.joined().sorted { $0.date < $1.date }
            guard let last = all.last else { continue }
            var subjects: [String] = []
            for message in all.reversed() {
                let subject = message.normalizedSubject
                if !subject.isEmpty, !subjects.contains(subject) { subjects.append(subject) }
            }
            let isAutomated = all.allSatisfy { $0.isAutomated && !$0.from.contains { mine.contains($0.normalizedEmail) } }

            result.append(Chat(
                id: chatID,
                accountID: accumulator.accountID,
                participants: accumulator.participants.values.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                },
                messageIDs: all.map(\.id),
                threads: chatThreads,
                lastDate: last.date,
                lastMessageID: last.id,
                unreadCount: all.filter(isUnread).count,
                subjects: subjects,
                isAutomated: isAutomated
            ))
        }
        return result.sorted { $0.lastDate > $1.lastDate }
    }
}
