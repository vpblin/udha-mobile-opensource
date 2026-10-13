import SwiftUI

/// The app's one settings screen: how it looks, and the key that lets the phone
/// stand in for the Mac.
///
/// It used to be the meetings key alone, reachable only from the Meetings tab.
/// The accent needed a home, and a second settings surface for one swatch would
/// have been worse than a shared one — so both live here, appearance first
/// because it is the only thing on the screen anyone will open twice.
struct UdhaSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = UdhaAppearance.shared

    @State private var key: String = ""
    @State private var checking = false
    /// Not `Result<Void, Error>`: the only thing this shows is a message, and
    /// the two cases are exactly "it worked" and "here is why it did not".
    @State private var status: CheckStatus?
    @State private var loaded = false

    enum CheckStatus: Equatable {
        case ok
        case problem(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    accentSection
                    apiKeySection
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(UdhaTheme.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(UdhaFont.semibold(16))
                }
            }
        }
        .tint(UdhaTheme.accent)
        .task {
            guard !loaded else { return }
            loaded = true
            key = SecureStorage.getAnthropicKey() ?? ""
        }
    }

    // MARK: - Accent

    /// Light and dark follow the system, so the only thing to choose is the
    /// colour the app acts in. Swatches rather than a menu: there are four, and
    /// seeing them beside each other is the whole decision.
    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Accent")
            UdhaCard {
                HStack(spacing: 12) {
                    ForEach(UdhaAccent.allCases) { option in
                        Button { appearance.accent = option } label: {
                            VStack(spacing: 7) {
                                ZStack {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 38, height: 38)
                                    if option == appearance.accent {
                                        Circle()
                                            .strokeBorder(UdhaTheme.label, lineWidth: 2)
                                            .frame(width: 48, height: 48)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(option.onAccent)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                Text(option.label)
                                    .font(UdhaFont.regular(12))
                                    .foregroundStyle(UdhaTheme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressDim())
                        .accessibilityLabel(option.label)
                        .accessibilityAddTraits(option == appearance.accent ? [.isSelected] : [])
                    }
                }

                Text("Light and dark follow your system setting.")
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - API key

    /// Optional by design: with a Mac in reach nothing here is needed, and the
    /// app says so rather than demanding a key up front. It matters for the two
    /// things that cannot wait for a Mac — summarising a call that just ended
    /// somewhere else, and answering a question mid-meeting.
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Anthropic API key")
            UdhaCard {
                Text("Used only when your Mac is unreachable — to summarise a recording that just ended, and to answer questions during a call. Your Mac uses its own key when it is available. Stored in this device's Keychain and never sent over the relay.")
                    .font(UdhaFont.regular(14.5))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.plain)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(UdhaFont.mono(14))
                    .foregroundStyle(UdhaTheme.label)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(UdhaTheme.fill,
                                in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                     style: .continuous))

                if let status {
                    statusRow(status).padding(.top, 12)
                }

                HStack(spacing: 10) {
                    PrimaryButton(title: checking ? "Checking…" : "Save and test",
                                  systemImage: "checkmark") {
                        saveAndTest()
                    }
                    .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !key.isEmpty {
                        Button("Remove") {
                            SecureStorage.deleteAnthropicKey()
                            key = ""
                            status = nil
                        }
                        .font(UdhaFont.medium(15))
                        .foregroundStyle(UdhaTheme.badInk)
                    }
                }
                .padding(.top, 14)

                Text("Without a key, recordings made away from your Mac are still saved in full — transcript and audio — and summarised automatically as soon as your Mac is reachable again.")
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ status: CheckStatus) -> some View {
        switch status {
        case .ok:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                Text("Key works.").font(UdhaFont.regular(14))
            }
            .foregroundStyle(UdhaTheme.goodInk)
        case .problem(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14))
                Text(message).font(UdhaFont.regular(14)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(UdhaTheme.badInk)
        }
    }

    /// Saves first, then proves it — a key that fails the check is still worth
    /// keeping if the failure was the network rather than the key.
    private func saveAndTest() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecureStorage.saveAnthropicKey(trimmed)
        checking = true
        status = nil
        Task {
            defer { checking = false }
            guard let client = ClaudeDirect(apiKey: trimmed) else {
                status = .problem("That does not look like a key.")
                return
            }
            do {
                try await client.ping()
                status = .ok
            } catch {
                status = .problem(error.localizedDescription)
            }
        }
    }
}
