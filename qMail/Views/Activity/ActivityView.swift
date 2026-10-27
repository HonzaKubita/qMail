import MailCore
import SwiftUI

/// Every email in a workspace in one list, newest first, grouped by day.
/// Clicking one opens it in its chat.
struct ActivityView: View {
    @Environment(MailStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    let account: Account
    @State private var filter = Filter.all
    /// Days are long lists; only the newest part is drawn until you ask for more.
    @State private var limit = 300

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", people = "People", unread = "Unread"
        var id: Self { self }
    }

    var body: some View {
        let all = store.activity(for: account.id)
        let items = all.filter { item in
            switch filter {
            case .all: true
            case .people: !item.chat.isAutomated
            case .unread: !item.summary.isSeen && !store.isFromMe(item.summary)
            }
        }
        let shown = Array(items.prefix(limit))
        List {
            ForEach(Self.days(shown), id: \.date) { day in
                Section {
                    ForEach(day.items) { item in
                        Button {
                            navigator.showChat(item.chat.id, accountID: item.chat.accountID, thread: item.threadID)
                        } label: {
                            EmailRow(summary: item.summary, account: account, chatTitle: store.title(for: item.chat))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(DateText.divider(day.date))
                }
            }
            if items.count > shown.count {
                Button("Show Older") { limit += 300 }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 8)
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty {
                switch filter {
                case .unread:
                    ContentUnavailableView("No Unread Messages", systemImage: "envelope.open", description: Text("You're all caught up."))
                case .all, .people:
                    ContentUnavailableView("No Messages", systemImage: "tray")
                }
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(account.email)
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Which emails to show")
            }
        }
        .onChange(of: filter) { limit = 300 }
    }

    private static func days(_ items: [ActivityItem]) -> [(date: Date, items: [ActivityItem])] {
        let calendar = Calendar.current
        var days: [(date: Date, items: [ActivityItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.summary.date)
            if days.last?.date == day {
                days[days.count - 1].items.append(item)
            } else {
                days.append((day, [item]))
            }
        }
        return days
    }
}

/// One email in a list: who, which chat, when, the subject and the start of the text.
struct EmailRow: View {
    @Environment(MailStore.self) private var store
    let summary: MessageSummary
    let account: Account
    var chatTitle: String?

    var body: some View {
        let fromMe = store.isOwn(summary.sender, accountID: account.id)
        let isUnread = !summary.isSeen && !fromMe
        HStack(alignment: .top, spacing: 10) {
            AvatarView(address: fromMe ? account.address : summary.sender, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isUnread {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                    Text(fromMe ? "You" : summary.sender?.displayName ?? "Unknown")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let context = context(fromMe: fromMe) {
                        Text(context)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(DateText.short(summary.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(summary.date.formatted(date: .complete, time: .shortened))
                }
                Text(summary.subject.isEmpty ? "(No Subject)" : summary.subject)
                    .fontWeight(isUnread ? .semibold : .regular)
                    .lineLimit(1)
                let preview = QuoteStripper.cleanSnippet(summary.snippet)
                if preview.contains(where: { $0.isLetter || $0.isNumber }) {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Which conversation it's in; a direct message from someone needs no label.
    private func context(fromMe: Bool) -> String? {
        let recipient = summary.to.first?.displayName
        if let chatTitle {
            if chatTitle == summary.sender?.displayName { return nil }
            return fromMe && chatTitle == recipient ? "to \(chatTitle)" : "in \(chatTitle)"
        }
        return fromMe ? recipient.map { "to \($0)" } : nil
    }
}
