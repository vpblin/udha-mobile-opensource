import SwiftUI

enum PaletteDestination {
    case session(String)
    case meeting(String)
    case agents
    case record
    case voice
    case newSession
    case newFolder
    case machines
    case settings
}

/// "Do anything…" — one search field over every actionable thing in the app.
///
/// Results are built from live state, not a static menu, so the top entries are
/// whatever is actually blocking right now. That makes the palette the fastest
/// path to the one thing worth doing, which is the point of having it.
struct CommandPalette: View {
    let bridge: UdhaBridge
    var onDismiss: () -> Void
    var onNavigate: (PaletteDestination) -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let hint: String
        let icon: String
        /// Rendered in the accent — the blocked sessions at the top.
        var urgent = false
        let run: () -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(UdhaTheme.secondary)
                    TextField("Do anything…", text: $query)
                        .textFieldStyle(.plain)
                        .font(UdhaFont.regular(19))
                        .foregroundStyle(UdhaTheme.label)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { results.first?.run() }
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(UdhaTheme.tertiary)
                    }
                    .buttonStyle(PressDim())
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(UdhaTheme.separator).frame(height: 0.5)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            Button(action: entry.run) {
                                HStack(spacing: 13) {
                                    Image(systemName: entry.icon)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(entry.urgent ? UdhaTheme.onAccent : UdhaTheme.accent)
                                        .frame(width: 30, height: 30)
                                        .background(entry.urgent ? UdhaTheme.accent : UdhaTheme.accentTint,
                                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.label)
                                            .font(UdhaFont.medium(16))
                                            .foregroundStyle(UdhaTheme.label)
                                            .lineLimit(1)
                                        Text(entry.hint)
                                            .font(UdhaFont.regular(13))
                                            .foregroundStyle(UdhaTheme.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .frame(minHeight: 56, alignment: .leading)
                                .overlay(alignment: .top) {
                                    if index > 0 {
                                        Rectangle().fill(UdhaTheme.hairline)
                                            .frame(height: 0.5)
                                            .padding(.leading, 59)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressDim())
                        }

                        if results.isEmpty {
                            Text("Nothing matches. Try “approve”, “record”, “agent”.")
                                .font(UdhaFont.regular(15))
                                .foregroundStyle(UdhaTheme.secondary)
                                .padding(26)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: 620)
            .frame(maxHeight: 480)
            .background(UdhaTheme.card)
            // Clipped, not just backed: the scroll view's last row runs past a
            // rounded corner otherwise, and a square row poking out of a round
            // card is the one thing that makes a sheet look unfinished.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(UdhaTheme.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 34, y: 16)
            .padding(.horizontal, 16)
            .padding(.top, 56)
        }
        .onAppear { focused = true }
    }

    // MARK: - Results

    private var results: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter {
            q.isEmpty || $0.label.lowercased().contains(q) || $0.hint.lowercased().contains(q)
        }
    }

    private var all: [Entry] {
        var out: [Entry] = []

        // Blocked sessions first — this is the whole reason to open the palette.
        for row in bridge.sessions where row.attention == .needsYou {
            let isApproval = row.phase == .awaitingApproval
            out.append(Entry(
                label: isApproval ? "Approve what Claude is asking" : "Answer the open question",
                hint: "\(row.label) · \(row.statusDetail ?? row.statusLabel)",
                icon: isApproval ? "checkmark" : "bubble.left",
                urgent: true,
                run: { onNavigate(.session(row.id)) }
            ))
        }

        out.append(Entry(label: "New session…",
                         hint: "browse your Mac and start Claude somewhere",
                         icon: "plus",
                         run: { onNavigate(.newSession) }))

        if bridge.status.isReady, bridge.canUseFolders(onInstance: nil) {
            out.append(Entry(label: "New folder…",
                             hint: "group sessions on \(bridge.activeInstance?.displayName ?? "your Mac")",
                             icon: "folder.badge.plus",
                             run: { onNavigate(.newFolder) }))
        }

        out.append(Entry(label: "Record a meeting",
                         hint: "mic only, transcribed on this device",
                         icon: "record.circle",
                         run: { onNavigate(.record) }))

        out.append(Entry(label: "Talk to Udha",
                         hint: "hand the voice agent to this device",
                         icon: "mic",
                         run: { onNavigate(.voice) }))

        // Only one host is subscribed at a time, so the other machine's
        // sessions are invisible until you switch — which makes "switch" a
        // first-class command, not a setting.
        for instance in bridge.instances
        where instance.id != bridge.activeInstanceID && instance.isOnline {
            out.append(Entry(label: "Switch to \(instance.displayName)",
                             hint: "show that machine's sessions instead",
                             icon: instance.systemImage,
                             run: {
                                 bridge.selectInstance(instance.id)
                                 onDismiss()
                             }))
        }

        out.append(Entry(label: "Machines",
                         hint: "link, resources and toolchain of each host",
                         icon: "server.rack",
                         run: { onNavigate(.machines) }))

        out.append(Entry(label: "Run an agent…",
                         hint: bridge.agents.prefix(3).map(\.name).joined(separator: ", "),
                         icon: "cpu",
                         run: { onNavigate(.agents) }))

        out.append(Entry(label: "Settings",
                         hint: "accent colour, Anthropic API key",
                         icon: "gearshape",
                         run: { onNavigate(.settings) }))

        for meeting in bridge.meetings.prefix(6) where !meeting.isRecording {
            out.append(Entry(label: meeting.title,
                             hint: meeting.listMeta,
                             icon: "video",
                             run: { onNavigate(.meeting(meeting.id)) }))
        }

        for row in bridge.sessions where row.attention != .needsYou {
            out.append(Entry(label: row.label,
                             hint: row.statusLine,
                             icon: "terminal",
                             run: { onNavigate(.session(row.id)) }))
        }

        return out
    }
}
