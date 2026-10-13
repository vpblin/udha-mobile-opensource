import SwiftUI
import UIKit

/// The Udha mobile design language, ported from `Udha Mobile HIG.dc.html`.
///
/// This replaced a warm-paper, square-cornered, Archivo-set language with a
/// native-feeling one. Three things define it and are easy to erode, so they
/// are centralised here:
///
/// 1. **Every surface is a rounded card on a canvas.** 16pt for content cards,
///    12pt for rows and buttons, 999 for pills. Nothing is square any more, and
///    nothing sits directly on the canvas without either a card or a fill.
/// 2. **Two palettes, one set of names.** Every token below resolves through
///    the trait collection, so a view written once is correct in light and in
///    dark. No view should branch on `colorScheme` itself.
/// 3. **The system font.** The design is specified in `-apple-system`, so
///    Dynamic Type, the optical sizes and the numeric variants all come for
///    free. `UdhaFont` exists to keep the *sizes and weights* consistent, not
///    to smuggle a custom family back in.
///
/// The accent is a user choice (`UdhaAppearance`), which is why the accent
/// tokens are computed rather than stored.
enum UdhaTheme {

    // MARK: - Ground

    /// The page behind everything.
    static let canvas = pair(0xF2F2F4, 0x1B1B1D)
    /// Content surfaces — cards, inset groups, message bubbles.
    static let card = pair(0xFFFFFF, 0x2A2A2C)
    /// Bars that float over content: nav bars, tab bars, composers.
    static let chrome = pair(0xF6F6F8, 0x2A2A2D, lightAlpha: 0.82, darkAlpha: 0.80)
    /// The iPad slide-over sidebar.
    static let sidebar = pair(0xF0F0F3, 0x222224, lightAlpha: 0.86, darkAlpha: 0.92)
    /// The iPad master column behind the detail pane.
    static let list = pair(0xFAFAFB, 0x262629, lightAlpha: 0.86, darkAlpha: 0.72)

    // MARK: - Ink

    /// Primary text.
    static let label = pair(0x1D1D1F, 0xF5F5F7)
    /// Secondary text — subtitles, section headers, metadata.
    static let secondary = pair(0x64646A, 0xA6A6AC)
    /// Tertiary text — timestamps, chevrons, the quietest line on a row.
    static let tertiary = pair(0x5D5D62, 0xA3A3A9)
    /// Code and paths set in mono.
    static let inkCode = pair(0x2B2B2E, 0xE7E7EA)

    // MARK: - Lines and fills

    /// Structural edges — the line under a nav bar, above a tab bar.
    static let separator = pair(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    /// Row separators *inside* a card, which must be lighter than the card edge.
    static let hairline = pair(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    /// The neutral fill: secondary buttons, search fields, quiet pills.
    static let fill = pair(0x787880, 0x787880, lightAlpha: 0.10, darkAlpha: 0.22)
    /// A step up from `fill` — key caps, a pressed neutral.
    static let fillStrong = pair(0x787880, 0x787880, lightAlpha: 0.18, darkAlpha: 0.36)

    // MARK: - Accent

    /// The action colour: primary buttons, selection, the caret, active tabs.
    static var accent: Color { UdhaAppearance.shared.accent.color }
    /// A wash of the accent, for tinted pills and chart fills.
    static var accentTint: Color { UdhaAppearance.shared.accent.tint }
    /// Text *on* the accent.
    static var onAccent: Color { UdhaAppearance.shared.accent.onAccent }
    /// Accent-coloured text on a canvas or tint. Darker than `accent` in light
    /// mode and lighter in dark, so it passes contrast at small sizes where the
    /// button colour would not.
    static var accentInk: Color { UdhaAppearance.shared.accent.ink }

    // MARK: - Status

    /// Running, connected, healthy.
    static let good = pair(0x1C8B3A, 0x45D669)
    static let goodTint = pair(0x1C8B3A, 0x45D669, lightAlpha: 0.13, darkAlpha: 0.16)
    static let goodInk = pair(0x14702E, 0x6FE089)

    /// Stale, degraded, warm.
    static let warn = pair(0x9A5B00, 0xFFB340)
    static let warnTint = pair(0x9A5B00, 0xFFB340, lightAlpha: 0.13, darkAlpha: 0.16)
    static let warnInk = pair(0x7D4A00, 0xFFC46B)

    /// Blocked, errored, recording.
    static let bad = pair(0xCF2A20, 0xFF6961)
    static let badTint = pair(0xCF2A20, 0xFF6961, lightAlpha: 0.12, darkAlpha: 0.16)
    static let badInk = pair(0x9C1E16, 0xFF9A94)

    // MARK: - Terminal

    /// The terminal keeps its own dark ground in both appearances. A pane that
    /// flipped to paper-white in light mode would be unreadable against every
    /// ANSI colour a program picks, all of which assume a dark background.
    enum Term {
        static let background = Color(hex: 0x171615)
        /// The key-row strip and composer behind the terminal.
        static let keyBar = Color(hex: 0x232122)
        static let out = Color(hex: 0xCFCBCB)
        static let dim = Color(hex: 0x8A8685)
        static let bright = Color(hex: 0xF3F2F2)
        static let red = Color(hex: 0xFF7B60)
        static let plus = Color(hex: 0xA8D5A2)
        static let minus = Color(hex: 0xFF9D88)
        /// Tappable URLs in output.
        static let link = Color(hex: 0x7FB4FF)
    }

    // MARK: - Status mapping

    /// The colour for a session's status. One place, so the dot, the state text
    /// and the card ring can never disagree about a row.
    static func color(for tone: SessionStatus.Tone) -> Color {
        switch tone {
        case .needsYou: return bad
        case .error:    return bad
        case .working:  return accent
        case .idle:     return warn
        case .dormant:  return secondary
        }
    }

    /// The *ink* for that status — the same meaning at text contrast.
    static func ink(for tone: SessionStatus.Tone) -> Color {
        switch tone {
        case .needsYou: return badInk
        case .error:    return badInk
        case .working:  return accentInk
        case .idle:     return warnInk
        case .dormant:  return secondary
        }
    }

    /// Coarse attention colour, for the three-way grouping the fleet uses.
    static func bar(for attention: SessionAttention) -> Color {
        switch attention {
        case .needsYou: return bad
        case .working:  return accent
        case .quiet:    return secondary
        }
    }

    /// Kept as a name because "running" reads as green everywhere else in the
    /// product, including the desktop's machine rows.
    static var go: Color { good }

    // MARK: - Radii

    enum Radius {
        /// Content cards and inset groups.
        static let card: CGFloat = 16
        /// Rows, buttons, fields.
        static let control: CGFloat = 12
        /// Search fields and segmented controls.
        static let field: CGFloat = 11
        /// Small chips and key caps.
        static let chip: CGFloat = 8
    }

    // MARK: - Building blocks

    /// `Color(light:dark:)` with one call per token, so the two palettes can
    /// only ever be read side by side.
    private static func pair(_ light: UInt32, _ dark: UInt32,
                             lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Appearance

/// The accent the user picked, and nothing else.
///
/// Light and dark follow the system: the design ships both palettes and a HIG
/// app has no business overriding the setting. The accent *is* a choice, because
/// the design specifies four of them and picking one is the only personalisation
/// this app offers.
@Observable
final class UdhaAppearance {
    static let shared = UdhaAppearance()

    var accent: UdhaAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.key) }
    }

    private static let key = "udha.accent"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
        accent = UdhaAccent(rawValue: stored) ?? .blue
    }
}

/// The four accents the design defines. Each carries its own ink and tint
/// rather than deriving them: a mechanically darkened blue is not the same
/// colour as the one that was drawn, and at 12pt the difference shows.
enum UdhaAccent: String, CaseIterable, Identifiable {
    case blue, purple, green, graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:     return "Blue"
        case .purple:   return "Purple"
        case .green:    return "Green"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .blue:     return dynamic(0x0069D9, 0x4DA2FF)
        case .purple:   return dynamic(0x7B3FBF, 0xC08CF5)
        case .green:    return dynamic(0x1C8B3A, 0x45D669)
        case .graphite: return dynamic(0x4A4A4F, 0xCFCFD4)
        }
    }

    var tint: Color {
        switch self {
        case .blue:     return dynamic(0x0069D9, 0x4DA2FF, lightAlpha: 0.12, darkAlpha: 0.18)
        case .purple:   return dynamic(0x7B3FBF, 0xC08CF5, lightAlpha: 0.13, darkAlpha: 0.18)
        case .green:    return dynamic(0x1C8B3A, 0x45D669, lightAlpha: 0.13, darkAlpha: 0.18)
        case .graphite: return dynamic(0x4A4A4F, 0xCFCFD4, lightAlpha: 0.12, darkAlpha: 0.18)
        }
    }

    var ink: Color {
        switch self {
        case .blue:     return dynamic(0x0058B8, 0x8EC2FF)
        case .purple:   return dynamic(0x5E2A99, 0xD9B8FA)
        case .green:    return dynamic(0x14702E, 0x6FE089)
        case .graphite: return dynamic(0x3A3A3F, 0xDCDCE0)
        }
    }

    /// White on a dark accent, near-black on a light one. Graphite inverts
    /// between appearances, which is exactly why this is per-accent.
    var onAccent: Color {
        dynamic(0xFFFFFF, 0x0D1117)
    }

    private func dynamic(_ light: UInt32, _ dark: UInt32,
                         lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Type

/// The system font, at the design's sizes and weights.
///
/// The design is specified in `-apple-system` with CSS weights (550, 590, 640,
/// 660). Those land between the named `Font.Weight` steps, so each role below
/// records which way it was rounded rather than leaving it to the call site.
enum UdhaFont {
    static func regular(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    static func medium(_ size: CGFloat) -> Font { .system(size: size, weight: .medium) }
    static func semibold(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func bold(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    /// Kept under its old name so the heaviest role reads the same at call
    /// sites; the design never goes past bold.
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }

    /// Metadata, paths, terminal output, anything that has to align in a column.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Named roles, so sizes stay consistent across screens.

    /// The large title at the top of a root screen — 34/bold.
    static var largeTitle: Font { bold(34) }
    /// A detail screen's own title — 30/bold.
    static var screenTitle: Font { bold(30) }
    /// Nav-bar centre title — 16/semibold.
    static var navTitle: Font { semibold(16) }
    /// Card heading — 15/semibold.
    static var cardTitle: Font { semibold(15) }
    /// List row title — 16/medium.
    static var rowTitle: Font { medium(16) }
    /// Body copy — 15/regular.
    static var bodyText: Font { regular(15) }
    /// Row subtitle and metadata — 13/regular.
    static var rowMeta: Font { regular(13) }
    /// Buttons — 16/semibold.
    static var button: Font { semibold(16) }
    /// The uppercase section label above a group — 13/semibold.
    static var sectionLabel: Font { semibold(13) }
    /// The tiny uppercase kicker inside a card — 12/bold.
    static var kicker: Font { bold(12) }

    /// Kept for the handful of places that still ask for a screen title by the
    /// old name.
    static var title: Font { screenTitle }
    static var paneTitle: Font { semibold(17) }
    static var buttonPrimary: Font { semibold(16) }
    static var buttonSecondary: Font { medium(15) }
}

extension View {
    /// The design's section label: uppercase, tracked, secondary.
    func sectionLabel() -> some View {
        self.font(UdhaFont.sectionLabel)
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(UdhaTheme.secondary)
    }

    /// The kicker inside a status card — "WAITING ON YOU", "PERMISSION".
    func kicker(_ tint: Color) -> some View {
        self.font(UdhaFont.kicker)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(tint)
    }

    /// A hairline on one edge. Used for structural edges only; separators
    /// *inside* a card come from `InsetGroup`, which insets them correctly.
    func hairline(_ edge: Edge, color: Color = UdhaTheme.separator, width: CGFloat = 0.5) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle()
                .fill(color)
                .frame(
                    width: edge == .leading || edge == .trailing ? width : nil,
                    height: edge == .top || edge == .bottom ? width : nil
                )
        }
    }

    /// The card treatment: a rounded surface, a half-point ring so it holds an
    /// edge against a same-value canvas, and the design's two-stop shadow.
    ///
    /// The ring matters more than the shadow in dark mode, where the shadow is
    /// nearly invisible and the card would otherwise dissolve into the canvas.
    func udhaCard(radius: CGFloat = UdhaTheme.Radius.card,
                  background: Color = UdhaTheme.card) -> some View {
        self.background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(UdhaTheme.hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }

    /// A card that wants attention: the same surface with a 1.5pt coloured ring
    /// instead of the hairline.
    func udhaCard(ringed tint: Color,
                  radius: CGFloat = UdhaTheme.Radius.card,
                  background: Color = UdhaTheme.card) -> some View {
        self.background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
}

private extension Edge {
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

// MARK: - Hex

extension Color {
    /// `Color(hex: 0x1D1D1F)` — the design is specified in hex throughout, and
    /// converting by hand at each site is where palette drift creeps in.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
