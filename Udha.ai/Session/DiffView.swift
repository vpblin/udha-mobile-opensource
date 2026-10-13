import SwiftUI

/// Read-only patch review for a session that is ready for a look.
///
/// Deliberately no staging and no merge: merging stays a deliberate act at a
/// real keyboard. Review here, then reply or run "Commit and summarize".
struct DiffView: View {
    let bridge: UdhaBridge
    let sessionID: String

    @Environment(\.dismiss) private var dismiss
    @State private var mode: DiffMode = .branch

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Review", onCancel: { dismiss() })

            SegmentedTabs(
                items: DiffMode.allCases.map { (value: $0, label: $0.title, badge: nil) },
                selection: $mode
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if bridge.diffLoading {
                Spacer()
                ProgressView().tint(UdhaTheme.accent)
                Spacer()
            } else if let diff = bridge.diff, !diff.files.isEmpty {
                content(diff)
            } else if bridge.diff != nil {
                Spacer()
                EmptyHint(systemImage: "checkmark.seal", title: "No changes",
                          subtitle: "Nothing to review in \(mode.title.lowercased()) mode.")
                Spacer()
            } else {
                Spacer()
                EmptyHint(systemImage: "plusminus", title: "Loading diff…")
                Spacer()
            }
        }
        .background(UdhaTheme.canvas)
        .task(id: mode) { bridge.fetchDiff(for: sessionID, mode: mode) }
        .onDisappear { bridge.clearDiff() }
    }

    private func content(_ diff: DiffResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    QuietPill(diff.stat)
                    if diff.truncated { Pill("truncated", tint: UdhaTheme.warnInk) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)

                ForEach(diff.files) { file in
                    FilePatch(file: file)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
    }
}

private struct FilePatch: View {
    let file: DiffResult.DiffFile
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(UdhaTheme.tertiary)
                    Text(file.fileName)
                        .font(UdhaFont.medium(14.5))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("+\(file.additions)")
                        .font(UdhaFont.mono(12, weight: .medium))
                        .foregroundStyle(UdhaTheme.goodInk)
                    Text("−\(file.deletions)")
                        .font(UdhaFont.mono(12, weight: .medium))
                        .foregroundStyle(UdhaTheme.badInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())

            if expanded {
                CardDivider(inset: 0)
                // Long lines scroll on their own axis; the review page itself
                // must never scroll sideways.
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                                id: \.offset) { _, line in
                            PatchLine(text: String(line))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .udhaCard()
    }
}

private struct PatchLine: View {
    let text: String

    private var tint: Color {
        if text.hasPrefix("+++") || text.hasPrefix("---") { return UdhaTheme.tertiary }
        if text.hasPrefix("@@") { return UdhaTheme.accentInk }
        if text.hasPrefix("+") { return UdhaTheme.goodInk }
        if text.hasPrefix("-") { return UdhaTheme.badInk }
        return UdhaTheme.inkCode
    }

    private var background: Color {
        if text.hasPrefix("+++") || text.hasPrefix("---") { return .clear }
        if text.hasPrefix("+") { return UdhaTheme.goodTint }
        if text.hasPrefix("-") { return UdhaTheme.badTint }
        return .clear
    }

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(UdhaFont.mono(11.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }
}
