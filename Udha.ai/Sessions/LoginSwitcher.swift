import SwiftUI

/// The session's Claude login as a chip, and — when its tree has more than one
/// — a menu that moves the conversation to another login. The desktop pane's
/// login strip, folded into one pill: a phone has no row to spare for meters,
/// so the headroom rides in each menu item instead.
struct LoginPill: View {
    let bridge: UdhaBridge
    let row: SessionRow

    var body: some View {
        if let info = bridge.logins(for: row) {
            let me = info.current
            let label = me?.displayName ?? row.account ?? "—"
            if bridge.canSwitchLogin(row) {
                Menu {
                    LoginSwitchItems(bridge: bridge, row: row)
                } label: {
                    Pill(label, tint: tint(me), icon: "person.crop.circle")
                }
                .simultaneousGesture(TapGesture().onEnded { bridge.refreshLogins() })
            } else {
                QuietPill(label, icon: "person.crop.circle")
            }
        }
    }

    private func tint(_ login: ClaudeLogin?) -> Color {
        guard let login else { return UdhaTheme.secondary }
        if login.isLimited() { return UdhaTheme.badInk }
        if login.needsSignIn { return UdhaTheme.warnInk }
        return UdhaTheme.secondary
    }
}

/// "Emptiest login", then every login in the pool with its headroom. Shared by
/// the chip, the detail's overflow menu and the list's context menu.
struct LoginSwitchItems: View {
    let bridge: UdhaBridge
    let row: SessionRow

    var body: some View {
        if let info = bridge.logins(for: row) {
            Button {
                bridge.switchLogin(sessionID: row.id, to: nil)
            } label: {
                Label("Emptiest login", systemImage: "arrow.left.arrow.right")
            }
            Divider()
            ForEach(info.members) { login in
                let isCurrent = login.dir == info.current?.dir
                Button {
                    bridge.switchLogin(sessionID: row.id, to: login.dir)
                } label: {
                    // Name as the title, headroom as the subtitle: one joined
                    // line truncated the meters on a phone-width menu.
                    Text(login.displayName)
                    Text(login.headroom())
                    if isCurrent { Image(systemName: "checkmark") }
                }
                .disabled(isCurrent)
            }
        }
    }
}
