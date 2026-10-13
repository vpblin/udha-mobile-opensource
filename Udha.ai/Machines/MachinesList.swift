import SwiftUI

/// The Machines master list: every host the relay knows about, in the order it
/// listed them.
///
/// Selection and connection are deliberately separate, as they are on the
/// desktop. Tapping a row opens that machine — including one this client is not
/// talking to, so you can read what little is known about a box before deciding
/// to move to it. Switching is an explicit verb in the detail pane.
struct MachinesList: View {
    let bridge: UdhaBridge
    var selection: String?
    var compact: Bool = true
    var onMenu: (() -> Void)?
    var onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                LargeTitleHeader(title: "Machines", subtitle: subtitle) {
                    CircleButton(systemImage: "arrow.clockwise") { bridge.refreshStats() }
                        .accessibilityLabel("Refresh")
                }
            } else {
                PadListHeader(title: "Machines", onMenu: onMenu) {
                    CircleButton(systemImage: "arrow.clockwise", diameter: 40) {
                        bridge.refreshStats()
                    }
                    .accessibilityLabel("Refresh")
                }
            }

            if bridge.instances.isEmpty {
                EmptyHint(systemImage: "server.rack",
                          title: "No machines",
                          subtitle: "The relay has not told this device about any host yet.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        MasterList(items: bridge.instances, compact: compact, separatorInset: 35) { instance in
                            Button { onSelect(instance.id) } label: { row(instance) }
                                .buttonStyle(.plain)
                        }

                        Text("Pairing is per instance ID — every machine here is one this device can reach.")
                            .font(UdhaFont.regular(12.5))
                            .lineSpacing(2)
                            .foregroundStyle(UdhaTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, compact ? 16 : 12)
                    .padding(.bottom, 20)
                }
                .refreshable { bridge.refreshStats() }
            }
        }
        .background(compact ? AnyShapeStyle(UdhaTheme.canvas) : AnyShapeStyle(Color.clear))
        // On iPhone this list and the detail pane are different screens; on iPad
        // they are side by side. Both ask, the bridge counts, and the poll stops
        // when the last of them goes away.
        .onAppear { bridge.addStatsViewer() }
        .onDisappear { bridge.removeStatsViewer() }
    }

    private var subtitle: String {
        let online = bridge.instances.count { $0.isOnline }
        guard !bridge.instances.isEmpty else { return "None paired" }
        return "\(online) of \(bridge.instances.count) online"
    }

    private func row(_ instance: BridgeInstance) -> some View {
        let active = instance.id == bridge.activeInstanceID
        let style = MasterSelection(compact: compact, selected: instance.id == selection)
        return HStack(spacing: 12) {
            LiveDot(color: active ? UdhaTheme.good : (instance.isOnline ? UdhaTheme.secondary : UdhaTheme.tertiary),
                    animated: active,
                    hollow: !instance.isOnline)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(instance.displayName)
                        .font(UdhaFont.rowTitle)
                        .foregroundStyle(style.label)
                        .lineLimit(1)
                    if active, !style.selected || compact {
                        Pill("Showing", tint: UdhaTheme.goodInk)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Image(systemName: instance.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(style.tertiary)
                    Text(detail(instance, active: active))
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Any connected machine has a series; one without a live
                    // connection has nothing measured to draw.
                    if bridge.isConnected(instance.id) {
                        let cpu = bridge.history.series(instance.id, .cpu)
                        if cpu.count > 1 {
                            Sparkline(values: cpu, lineWidth: 1.4,
                                      fill: UdhaTheme.accentTint, animated: false)
                                .frame(width: 64, height: 18)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.chevron)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(style.background)
        .opacity(instance.isOnline ? 1 : 0.6)
        .contentShape(Rectangle())
    }

    private func detail(_ instance: BridgeInstance, active: Bool) -> String {
        guard instance.isOnline else { return "Offline" }
        guard bridge.isConnected(instance.id) else { return "Online · connecting" }
        // Session count from the machine's own reckoning when it has reported,
        // and from what this client is holding when it has not.
        let count = bridge.stats(for: instance.id)?.sessionCount
            ?? bridge.sessions.count(where: { $0.instanceID == instance.id && bridge.canDrive($0) })
        return "Online · \(count) session\(count == 1 ? "" : "s")"
    }
}
