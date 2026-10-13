import SwiftUI

/// The same authoritative inbox on the fleet and inside a session.
struct AttentionInbox: View {
    let bridge: UdhaBridge
    var sessionID: String? = nil
    var onOpen: (String) -> Void
    @State private var expanded = true
    @State private var showAll = false
    @Environment(\.openURL) private var openURL

    private struct Item: Identifiable {
        let row: SessionRow
        let event: AttentionEvent
        var id: String { row.id + ":" + event.id }
    }
    private var items: [Item] {
        // The fleet inbox skips hidden sessions, the way the list does; inside
        // a session you are looking at it, hidden or not.
        bridge.sessions.filter { sessionID == nil ? bridge.isVisible($0) : $0.id == sessionID }.flatMap { row in
            row.attentionState.visibleEvents.map { Item(row: row, event: $0) }
        }.sorted {
            if $0.event.kind.needsAction != $1.event.kind.needsAction { return $0.event.kind.needsAction }
            return $0.event.createdAt > $1.event.createdAt
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if !items.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.prefix(showAll ? 100 : 3))) { item in
                            entry(item)
                        }
                        if items.count > 3 {
                            Button(showAll ? "Show less" : "Show all \(items.count)") { showAll.toggle() }
                                .font(.subheadline)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    let needs = items.filter { $0.event.kind.needsAction }.count
                    Text(needs > 0
                         ? "\(needs) \(needs == 1 ? "needs" : "need") you" + (items.count > needs ? " · \(items.count - needs) to review" : "")
                         : "\(items.count) to review")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(UdhaTheme.accentInk)
                .padding(12)
                .background(UdhaTheme.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func entry(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.event.kind.label).font(.caption.weight(.semibold))
                    .foregroundStyle(item.event.kind.needsAction ? UdhaTheme.warnInk : UdhaTheme.secondary)
                Spacer()
                Text(Date(timeIntervalSince1970: item.event.createdAt), style: .relative).font(.caption2)
                    .foregroundStyle(UdhaTheme.secondary)
                Menu {
                    Button("Snooze 15 minutes") { change(item, "snooze") }
                    Button("Dismiss") { change(item, "dismiss") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 28)
                }
                .disabled(!bridge.canUseAttention(item.row))
            }
            if sessionID == nil { Text(item.row.label).font(.caption).foregroundStyle(UdhaTheme.secondary) }
            Text(item.event.summary).font(.subheadline).lineLimit(3)
            if sessionID != nil, let detail = item.event.detail {
                Text(detail).font(.caption).foregroundStyle(UdhaTheme.secondary).lineLimit(4)
            }
            HStack {
                Button(item.event.safeURL == nil ? item.event.kind.actionLabel : "Open preview") {
                    guard let current = bridge.session(id: item.row.id)?.attentionState.events.first(where: { $0.id == item.event.id }), current.visible else { return }
                    if let url = current.safeURL { openURL(url) } else { onOpen(item.row.id) }
                }
                .font(.subheadline.weight(.semibold))
                if item.event.safeURL != nil { Button("Open session") { onOpen(item.row.id) }.font(.caption) }
                Spacer()
            }
        }
    }
    private func change(_ item: Item, _ action: String) {
        bridge.changeAttention(item.row.id, action: action, eventID: item.event.id)
    }
}
