import MailCore
import SwiftUI

/// Colors an account can be shown in. System colors, so they adapt to light and dark mode.
enum AccountTint: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .mint: "Mint"
        case .teal: "Teal"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .brown: "Brown"
        case .gray: "Graphite"
        }
    }

    /// The color an account at this provider gets first.
    static func brand(of provider: MailProvider) -> AccountTint {
        switch provider {
        case .gmail: .red
        case .outlook: .blue
        case .icloud: .cyan
        case .yahoo: .purple
        case .fastmail: .indigo
        case .aol: .gray
        case .other: .teal
        }
    }
}

/// Symbols offered for account icons.
@MainActor
enum AccountSymbol {
    static let all: [(symbol: String, name: LocalizedStringKey)] = [
        ("envelope.fill", "Envelope"),
        ("tray.fill", "Tray"),
        ("at", "At Sign"),
        ("person.fill", "Person"),
        ("house.fill", "Home"),
        ("briefcase.fill", "Work"),
        ("building.2.fill", "Office"),
        ("graduationcap.fill", "School"),
        ("book.fill", "Book"),
        ("star.fill", "Star"),
        ("heart.fill", "Heart"),
        ("bolt.fill", "Bolt"),
        ("leaf.fill", "Leaf"),
        ("globe", "Globe"),
        ("cart.fill", "Shopping"),
        ("airplane", "Travel"),
        ("gamecontroller.fill", "Games"),
        ("hammer.fill", "Tools"),
        ("paintbrush.fill", "Art"),
        ("icloud.fill", "Cloud"),
    ]

    static func provider(_ provider: MailProvider) -> String {
        switch provider {
        case .gmail, .yahoo, .aol: "envelope.fill"
        case .outlook: "envelope.open.fill"
        case .icloud: "icloud.fill"
        case .fastmail: "bolt.fill"
        case .other: "server.rack"
        }
    }
}

@MainActor
extension Account {
    var tintColor: Color { (tint.flatMap(AccountTint.init) ?? .brand(of: provider)).color }
    var symbolName: String { symbol ?? AccountSymbol.provider(provider) }
}

/// The account's icon in the style of System Settings: a white symbol on a colored rounded square.
struct AccountIcon: View {
    let account: Account
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(account.tintColor.gradient)
            .overlay {
                Image(systemName: account.symbolName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Color and icon pickers for an account, for context menus and Settings.
struct AccountAppearancePickers: View {
    @Environment(MailStore.self) private var store
    let account: Account
    /// In a Form, colors are a row of swatches like System Settings' accent color; in menus, a palette.
    var inForm = false

    var body: some View {
        if inForm {
            LabeledContent("Color") {
                HStack(spacing: 5) {
                    ForEach(AccountTint.allCases) { option in
                        ColorSwatch(tint: option, isSelected: tint.wrappedValue == option.rawValue) {
                            tint.wrappedValue = option.rawValue
                        }
                    }
                }
            }
        } else {
            Picker("Color", selection: tint) {
                ForEach(AccountTint.allCases) { tint in
                    Label(tint.name, systemImage: "circle.fill")
                        .tint(tint.color)
                        .tag(tint.rawValue)
                }
            }
            .pickerStyle(.palette)
        }
        Picker("Icon", selection: symbol) {
            ForEach(AccountSymbol.all, id: \.symbol) { item in
                Label(item.name, systemImage: item.symbol).tag(item.symbol)
            }
            if !AccountSymbol.all.contains(where: { $0.symbol == AccountSymbol.provider(account.provider) }) {
                Label(account.provider.displayName, systemImage: AccountSymbol.provider(account.provider))
                    .tag(AccountSymbol.provider(account.provider))
            }
        }
    }

    private var tint: Binding<String> {
        Binding(
            get: { store.account(account.id)?.tint ?? AccountTint.brand(of: account.provider).rawValue },
            set: { store.setAppearance(of: account.id, tint: $0) }
        )
    }

    private var symbol: Binding<String> {
        Binding(
            get: { store.account(account.id)?.symbolName ?? account.symbolName },
            set: { store.setAppearance(of: account.id, symbol: $0) }
        )
    }
}

private struct ColorSwatch: View {
    let tint: AccountTint
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(tint.color.gradient)
                .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                .overlay {
                    if isSelected { Circle().fill(.white).frame(width: 6, height: 6) }
                }
                .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
        .help(Text(tint.name))
        .accessibilityLabel(Text(tint.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
