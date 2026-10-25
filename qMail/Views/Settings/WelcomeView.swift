import MailCore
import SwiftUI

struct WelcomeView: View {
    @Binding var showingAddAccount: Bool

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: 26) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 120, height: 120)
                VStack(spacing: 8) {
                    Text("Welcome to qMail")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Simple, native mail for Gmail, Outlook, iCloud and more —\nwith your conversations organized as chats.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        FeatureCard(
                            systemImage: "bubble.left.and.bubble.right.fill",
                            title: "Chats",
                            text: "Email threads with the same people become one easy-to-find conversation."
                        )
                        FeatureCard(
                            systemImage: "tray.2.fill",
                            title: "All Your Accounts",
                            text: "Gmail, Outlook, iCloud, Yahoo, Fastmail and any IMAP server."
                        )
                        FeatureCard(
                            systemImage: "lock.shield.fill",
                            title: "Private by Default",
                            text: "Remote images are blocked and passwords stay in your Keychain."
                        )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 760)
                Button {
                    showingAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
            }
            .padding(40)
        }
    }
}

private struct FeatureCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(height: 28)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Soft color fields behind the welcome glass so the material has something to refract.
private struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Circle()
                .fill(Color.blue.opacity(0.35))
                .frame(width: 520)
                .blur(radius: 120)
                .offset(x: -260, y: -180)
            Circle()
                .fill(Color.purple.opacity(0.30))
                .frame(width: 460)
                .blur(radius: 120)
                .offset(x: 300, y: 160)
            Circle()
                .fill(Color.cyan.opacity(0.25))
                .frame(width: 360)
                .blur(radius: 110)
                .offset(x: 120, y: -260)
        }
        .ignoresSafeArea()
    }
}
