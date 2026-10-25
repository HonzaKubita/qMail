import MailCore
import SwiftUI

/// Initials on a color derived from the address, so a person keeps the same color everywhere.
struct AvatarView: View {
    let address: MailAddress?
    var size: CGFloat = 32

    var body: some View {
        let palette = Self.palette(for: address?.normalizedEmail ?? "")
        Circle()
            .fill(LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom))
            .overlay {
                Text(address?.initials ?? "?")
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static let palettes: [[Color]] = [
        [Color(red: 0.98, green: 0.55, blue: 0.40), Color(red: 0.93, green: 0.33, blue: 0.30)],
        [Color(red: 0.99, green: 0.74, blue: 0.30), Color(red: 0.96, green: 0.55, blue: 0.16)],
        [Color(red: 0.45, green: 0.85, blue: 0.50), Color(red: 0.20, green: 0.68, blue: 0.38)],
        [Color(red: 0.40, green: 0.80, blue: 0.90), Color(red: 0.16, green: 0.60, blue: 0.80)],
        [Color(red: 0.45, green: 0.62, blue: 1.00), Color(red: 0.25, green: 0.42, blue: 0.95)],
        [Color(red: 0.70, green: 0.55, blue: 1.00), Color(red: 0.50, green: 0.33, blue: 0.92)],
        [Color(red: 0.98, green: 0.55, blue: 0.80), Color(red: 0.88, green: 0.30, blue: 0.60)],
        [Color(red: 0.62, green: 0.66, blue: 0.72), Color(red: 0.45, green: 0.49, blue: 0.56)],
    ]

    static func palette(for key: String) -> [Color] {
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }
}

/// One avatar for 1:1 chats, two overlapping ones for groups.
struct GroupAvatarView: View {
    let participants: [MailAddress]
    var size: CGFloat = 40

    var body: some View {
        if participants.count <= 1 {
            AvatarView(address: participants.first, size: size)
        } else {
            ZStack(alignment: .topLeading) {
                AvatarView(address: participants[0], size: size * 0.68)
                AvatarView(address: participants[1], size: size * 0.68)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .offset(x: size * 0.32, y: size * 0.32)
                if participants.count > 2 {
                    Text("+\(participants.count - 2)")
                        .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                        .padding(.horizontal, 3)
                        .background(.thinMaterial, in: Capsule())
                        .offset(x: size * 0.02, y: size * 0.66)
                }
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
    }
}

enum DateText {
    /// Compact list timestamp: time today, weekday this week, otherwise a short date.
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func divider(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
