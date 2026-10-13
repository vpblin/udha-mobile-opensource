import GameController
import SwiftUI
import UIKit

/// Whether a physical keyboard is attached to the device right now.
///
/// The distinction matters because focus costs nothing with a real keyboard and
/// costs half the screen without one: focusing a field on a bare iPhone throws
/// the software keyboard up over the pane you were reading. So the app only
/// claims focus on its own when there is hardware behind it — then you sit
/// down, start typing, and the characters land in the composer without a tap.
///
/// `GCKeyboard` is the honest source: it reports Magic Keyboards, Smart
/// Keyboard Folios and Bluetooth keyboards alike, and it tells us the moment
/// one connects or drops rather than making us guess from keyboard frames.
@MainActor
@Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()

    private(set) var isAttached: Bool

    private init() {
        isAttached = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.isAttached = true }
        }
        // Not simply `false`: unpairing one of two keyboards still leaves you
        // typing on the other.
        center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                HardwareKeyboard.shared.isAttached = GCKeyboard.coalesced != nil
            }
        }
    }
}

// MARK: - Autofocus

extension View {
    /// Hold focus for as long as a hardware keyboard is attached, so typing
    /// goes straight into the field with nothing to tap first — not once, but
    /// every time.
    ///
    /// Claiming focus on appear is not enough on its own, because iOS hands it
    /// back at the least convenient moment: pressing Return resigns the field,
    /// so sending one message cost a tap to start the next. Focus is therefore
    /// re-taken whenever it is lost — as well as on appear, on a keyboard
    /// connecting, on return to the front, when `enabled` turns back on (pass
    /// `false` while a sheet or dialog is up so this does not pull the keys out
    /// from under it), and whenever `resetOn` changes.
    ///
    /// Re-taking is deliberately polite: if some *other* text field has since
    /// become first responder — the command palette, a sheet's own field — it
    /// keeps the keys. Only an unclaimed keyboard is picked back up.
    func hardwareKeyboardAutofocus<Token: Equatable>(
        _ focus: FocusState<Bool>.Binding,
        enabled: Bool = true,
        resetOn token: Token = 0
    ) -> some View {
        modifier(HardwareKeyboardAutofocus(focus: focus, enabled: enabled, token: token))
    }
}

private struct HardwareKeyboardAutofocus<Token: Equatable>: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let enabled: Bool
    let token: Token

    @Environment(\.scenePhase) private var scenePhase
    @MainActor private var keyboard: HardwareKeyboard { .shared }

    /// When focus was last taken back, so a field that refuses to hold it
    /// cannot turn this into a loop that re-claims every 80ms forever.
    @State private var lastReclaim = Date.distantPast

    func body(content: Content) -> some View {
        content
            .onAppear { claim() }
            .onChange(of: keyboard.isAttached) { _, attached in if attached { claim() } }
            .onChange(of: enabled) { _, on in if on { claim() } }
            .onChange(of: token) { _, _ in claim() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { claim() } }
            // The one that makes this a feature rather than a first impression:
            // Return, a swipe, a dismissed sheet — whatever dropped the field,
            // it comes straight back.
            .onChange(of: focus.wrappedValue) { _, isFocused in
                guard !isFocused else { return }
                guard Date().timeIntervalSince(lastReclaim) > 0.3 else { return }
                claim(reclaim: true)
            }
    }

    private func claim(reclaim: Bool = false) {
        guard enabled, keyboard.isAttached else { return }
        if reclaim { lastReclaim = Date() }
        Task { @MainActor in
            // A hair after the fact: focus set while the view is still being
            // installed — during `onAppear`, or in the frame a sheet is
            // dismissing — is dropped on the floor. It also lets whatever is
            // taking focus next actually take it, so the check below sees it.
            try? await Task.sleep(for: .milliseconds(80))
            guard enabled, keyboard.isAttached, !UIResponder.someTextInputIsFirstResponder
            else { return }
            focus.wrappedValue = true
        }
    }
}

// MARK: - Who has the keys

extension UIResponder {
    @MainActor private static weak var firstResponderProbe: UIResponder?

    /// Whether something on screen is already taking typed characters.
    ///
    /// There is no public "current first responder" property, but there is a
    /// public way to ask: an action sent to `nil` is delivered along the
    /// responder chain, so the responder that answers is the one holding it.
    @MainActor
    static var someTextInputIsFirstResponder: Bool {
        firstResponderProbe = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder), to: nil, from: nil, for: nil)
        return firstResponderProbe is UITextInput
    }

    @MainActor
    @objc private func captureFirstResponder() {
        UIResponder.firstResponderProbe = self
    }
}
