import Foundation

/// A conversation with a fixed set of people, built from one or more email threads.
public struct Chat: Identifiable, Hashable, Sendable {
    public var id: String
    public var accountID: UUID
    /// Everyone in the conversation except the account owner.
    public var participants: [MailAddress]
    /// Summary IDs in chronological order.
    public var messageIDs: [String]
    public var lastDate: Date
    public var lastMessageID: String
    public var unreadCount: Int
    public var subjects: [String]

    public var isGroup: Bool { participants.count > 1 }

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

    public static func makeID(accountID: UUID, participants: [String]) -> String {
        "\(accountID.uuidString)|" + participants.sorted().joined(separator: ",")
    }
}

/// Groups email into chats: messages are first threaded (References / In-Reply-To / Gmail
/// thread IDs), then threads that involve exactly the same people are merged into one chat.
public enum ChatBuilder {
    public struct Options: Sendable {
        /// Include threads that only contain newsletters, notifications and other automated mail.
        public var includeAutomated = false
        /// Only show conversations the user has written in.
        public var requireOwnMessage = false

        public init(includeAutomated: Bool = false, requireOwnMessage: Bool = false) {
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

        // 3. Merge threads by participant set.
        struct ChatAccumulator {
            var accountID: UUID
            var participants: [String: MailAddress] = [:]
            var messages: [MessageSummary] = []
        }
        var chats: [String: ChatAccumulator] = [:]

        for (_, threadMessages) in threads {
            guard let accountID = threadMessages.first?.accountID else { continue }
            let mine = ownAddresses[accountID] ?? []
            let isMine: (MessageSummary) -> Bool = { message in
                message.from.contains { mine.contains($0.normalizedEmail) }
            }

            let hasHuman = threadMessages.contains { !$0.isAutomated || isMine($0) }
            if !options.includeAutomated && !hasHuman { continue }
            if options.requireOwnMessage && !threadMessages.contains(where: isMine) { continue }

            var people: [String: MailAddress] = [:]
            for message in threadMessages {
                for address in message.from + message.to + message.cc {
                    let email = address.normalizedEmail
                    guard email.contains("@"), !mine.contains(email) else { continue }
                    // Prefer an address entry that carries a display name.
                    if people[email]?.name == nil { people[email] = address }
                }
            }
            guard !people.isEmpty else { continue }

            let chatID = Chat.makeID(accountID: accountID, participants: Array(people.keys))
            var accumulator = chats[chatID] ?? ChatAccumulator(accountID: accountID)
            accumulator.participants.merge(people) { existing, new in existing.name == nil ? new : existing }
            accumulator.messages.append(contentsOf: threadMessages)
            chats[chatID] = accumulator
        }

        // 4. Finalize.
        var result: [Chat] = []
        for (chatID, accumulator) in chats {
            let mine = ownAddresses[accumulator.accountID] ?? []
            let sorted = accumulator.messages.sorted { $0.date < $1.date }
            guard let last = sorted.last else { continue }
            let unread = sorted.filter { message in
                !message.isSeen && !message.from.contains { mine.contains($0.normalizedEmail) }
            }.count
            var subjects: [String] = []
            for message in sorted.reversed() {
                let subject = message.normalizedSubject
                if !subject.isEmpty, !subjects.contains(subject) { subjects.append(subject) }
            }
            result.append(Chat(
                id: chatID,
                accountID: accumulator.accountID,
                participants: accumulator.participants.values.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                },
                messageIDs: sorted.map(\.id),
                lastDate: last.date,
                lastMessageID: last.id,
                unreadCount: unread,
                subjects: subjects
            ))
        }
        return result.sorted { $0.lastDate > $1.lastDate }
    }
}
