import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// "To:" field with recipient chips and completion from people you've emailed.
struct RecipientTokenField: View {
    @Binding var recipients: [MailAddress]
    let contacts: [MailAddress]
    @State private var input = ""
    @FocusState private var focused: Bool

    private var suggestions: [MailAddress] {
        let token = input.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return [] }
        let chosen = Set(recipients.map(\.normalizedEmail))
        return contacts.filter { contact in
            !chosen.contains(contact.normalizedEmail)
                && (contact.email.localizedCaseInsensitiveContains(token) || (contact.name?.localizedCaseInsensitiveContains(token) ?? false))
        }
        .prefix(8)
        .map { $0 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(recipients) { person in
                    HStack(spacing: 5) {
                        AvatarView(address: person, size: 18)
                        Text(person.displayName)
                            .lineLimit(1)
                        Button {
                            recipients.removeAll { $0.normalizedEmail == person.normalizedEmail }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 3)
                    .padding(.trailing, 7)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: .capsule)
                    .help(person.email)
                }
                TextField(recipients.isEmpty ? "Name or email address" : "Add someone", text: $input)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 200)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: input) {
                        if input.contains(",") || input.contains(";") { commit() }
                    }
                    .onKeyPress(.delete) {
                        guard input.isEmpty, !recipients.isEmpty else { return .ignored }
                        recipients.removeLast()
                        return .handled
                    }
                    .textInputSuggestions {
                        ForEach(suggestions) { contact in
                            VStack(alignment: .leading) {
                                Text(contact.displayName)
                                if contact.name != nil {
                                    Text(contact.email).foregroundStyle(.secondary)
                                }
                            }
                            .textInputCompletion(contact.headerValueForEditing + ",")
                        }
                    }
            }
        }
        .onAppear { focused = recipients.isEmpty }
    }

    private func commit() {
        let parsed = MailAddress.parseList(input.replacingOccurrences(of: ";", with: ","))
        for address in parsed where !recipients.contains(where: { $0.normalizedEmail == address.normalizedEmail }) {
            recipients.append(address)
        }
        if !parsed.isEmpty || input.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")).isEmpty {
            input = ""
        }
    }
}

/// Lays out children left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Probes can propose zero, nil or infinity; never report an infinite size back.
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let maxWidth = proposed ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposed ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension MailAddress {
    /// `Name <email>` without MIME encoding, for editable text fields.
    var headerValueForEditing: String {
        guard let name, !name.isEmpty else { return email }
        let needsQuotes = name.contains(",") || name.contains("\"") || name.contains("<")
        return needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\" <\(email)>" : "\(name) <\(email)>"
    }
}

extension OutgoingAttachment {
    static func load(_ url: URL) -> OutgoingAttachment? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
    }

    static func loadDropped(_ providers: [NSItemProvider], completion: @escaping @MainActor ([OutgoingAttachment]) -> Void) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let attachment = load(url) else { return }
                Task { @MainActor in completion([attachment]) }
            }
        }
    }
}
