import SwiftUI

// MARK: - Surfaces

/// A padded content card on the canvas.
struct UdhaCard<Content: View>: View {
    var radius: CGFloat = UdhaTheme.Radius.card
    var insets = EdgeInsets(top: 14, leading: 15, bottom: 13, trailing: 15)
    /// A coloured ring instead of the hairline, for a card that is asking for
    /// something — blocked, permission, error.
    var ring: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(insets)
            .modifier(CardSurface(radius: radius, ring: ring))
    }
}

private struct CardSurface: ViewModifier {
    var radius: CGFloat
    var ring: Color?

    func body(content: Content) -> some View {
        if let ring {
            content.udhaCard(ringed: ring, radius: radius)
        } else {
            content.udhaCard(radius: radius)
        }
    }
}

/// The inset grouped list: one card holding a run of rows, separated by
/// hairlines that start after the row's leading content rather than at the card
/// edge — the thing that makes a grouped table read as a table.
struct InsetGroup<Item: Identifiable, Row: View>: View {
    var items: [Item]
    /// Where the separator starts, measured from the card's leading edge.
    var separatorInset: CGFloat = 14
    var radius: CGFloat = UdhaTheme.Radius.card
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(UdhaTheme.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, separatorInset)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .udhaCard(radius: radius)
    }
}

/// The divider for a hand-built stack of rows inside a card.
struct CardDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(UdhaTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

// MARK: - Headers

/// The uppercase label above a group, with an optional note on the right.
struct SectionHeader: View {
    var title: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).sectionLabel()
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(UdhaFont.mono(11))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

/// The header over a machine's run of sessions: a live dot, the machine, how
/// many, and where the ball is.
struct GroupHeader: View {
    var name: String
    var count: String
    var badge: String?
    var badgeTint: Color = UdhaTheme.good
    var online: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            LiveDot(color: online ? UdhaTheme.good : UdhaTheme.secondary,
                    animated: online, size: 8)
            Text(name)
                .font(UdhaFont.semibold(17))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
            Text(count)
                .font(UdhaFont.regular(14))
                .foregroundStyle(UdhaTheme.secondary)
            Spacer(minLength: 8)
            if let badge {
                Pill(badge, tint: badgeTint)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Indicators

/// The status dot: a filled circle, with a ping ring while something is live.
///
/// A circle rather than the old square, because everything in this design is
/// round — and the ping is the only motion on a resting list, so it is the one
/// thing that reads as "this one is moving" from across the room.
struct StatusDot: View {
    var tone: SessionStatus.Tone
    var size: CGFloat = 9

    var body: some View {
        LiveDot(color: UdhaTheme.color(for: tone),
                animated: tone == .needsYou || tone == .working,
                hollow: tone == .dormant,
                size: size)
    }
}

/// A dot that can ping. The ring expands and fades once every couple of
/// seconds; a dormant dot is hollow, so "not running" survives being read by
/// someone who cannot separate the hues.
struct LiveDot: View {
    var color: Color
    var animated: Bool = false
    var hollow: Bool = false
    var size: CGFloat = 9

    @State private var pinging = false

    var body: some View {
        ZStack {
            if animated {
                // The stroke scales with the circle, so a 2pt ring blown up
                // 2.6x reads as a blob rather than a ripple. 0.8pt lands at
                // roughly 2pt at full expansion, which is what the design draws.
                Circle()
                    .stroke(color, lineWidth: 0.8)
                    .frame(width: size, height: size)
                    .scaleEffect(pinging ? 2.6 : 1)
                    .opacity(pinging ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 1.9).repeatForever(autoreverses: false),
                        value: pinging
                    )
            }
            Group {
                if hollow {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { if animated { pinging = true } }
        .accessibilityHidden(true)
    }
}

/// The three-dot "still going" tell beside a working session's state.
struct TypingDots: View {
    var color: Color
    var size: CGFloat = 3.5

    @State private var phase = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .opacity(index == step ? 1 : 0.25)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A recording indicator that breathes rather than blinks.
struct RecordingDot: View {
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        Circle()
            .fill(UdhaTheme.bad)
            .frame(width: size, height: size)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Kept under its old name for the places that still say "pulse"; now a dot.
struct PulseSquare: View {
    var color: Color = UdhaTheme.bad
    var size: CGFloat = 10

    var body: some View {
        LiveDot(color: color, animated: true, size: size)
    }
}

// MARK: - Pills and chips

/// The tinted capsule the design uses everywhere a short status belongs.
struct Pill: View {
    var text: String
    var tint: Color
    /// Filled with the tint at full strength rather than washed.
    var solid: Bool = false
    var icon: String?
    var showsDot: Bool = false

    init(_ text: String, tint: Color = UdhaTheme.secondary,
         solid: Bool = false, icon: String? = nil, showsDot: Bool = false) {
        self.text = text
        self.tint = tint
        self.solid = solid
        self.icon = icon
        self.showsDot = showsDot
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(solid ? UdhaTheme.onAccent : tint).frame(width: 6, height: 6)
            }
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(UdhaFont.semibold(12.5))
                .lineLimit(1)
        }
        .padding(.horizontal, showsDot ? 9 : 10)
        .frame(height: 24)
        .foregroundStyle(solid ? UdhaTheme.onAccent : tint)
        .background(solid ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
    }
}

/// A neutral capsule — no status, just metadata.
struct QuietPill: View {
    var text: String
    var icon: String?

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
            }
            Text(text).font(UdhaFont.medium(12.5)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .foregroundStyle(UdhaTheme.secondary)
        .background(UdhaTheme.fill, in: Capsule())
    }
}

/// A mono path in a capsule, centred over a transcript.
struct PathChip: View {
    var path: String
    var dot: Color? = UdhaTheme.good

    var body: some View {
        HStack(spacing: 8) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(path)
                .font(UdhaFont.mono(12))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .foregroundStyle(UdhaTheme.secondary)
        .background(UdhaTheme.fill, in: Capsule())
    }
}

// MARK: - Buttons

/// The filled accent button — approve, send, start. 44pt, 12pt radius.
///
/// Reads `isEnabled` itself rather than leaving each call site to remember an
/// opacity: a full-strength accent button that does nothing when tapped is the
/// worst state a button can be in.
struct PrimaryButton: View {
    var title: String
    var systemImage: String?
    var height: CGFloat = 44
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(UdhaFont.button).fixedSize()
            }
            .padding(.horizontal, 20)
            .frame(height: height)
            .foregroundStyle(isEnabled ? UdhaTheme.onAccent : UdhaTheme.tertiary)
            .background(isEnabled ? UdhaTheme.accent : UdhaTheme.fill,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressDim())
    }
}

/// The neutral fill button — deny, cancel, secondary actions.
struct SecondaryButton: View {
    var title: String
    var systemImage: String?
    var height: CGFloat = 44
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(UdhaFont.medium(16)).fixedSize()
            }
            .padding(.horizontal, 18)
            .frame(height: height)
            .foregroundStyle(isEnabled ? UdhaTheme.label : UdhaTheme.tertiary)
            .background(UdhaTheme.fill,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressDim())
    }
}

/// The round icon button in a nav bar. Filled with the accent when it is the
/// screen's primary action, with the neutral fill otherwise.
struct CircleButton: View {
    var systemImage: String
    var diameter: CGFloat = 44
    var prominent: Bool = false
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.44, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .foregroundStyle(prominent ? UdhaTheme.onAccent : (tint ?? UdhaTheme.label))
                .background(prominent ? UdhaTheme.accent : UdhaTheme.fill, in: Circle())
        }
        .buttonStyle(PressDim())
    }
}

/// The back control: a chevron and the name of where you came from, in the
/// accent — the iOS idiom, which the design keeps.
struct BackButton: View {
    var title: String
    var badge: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                Text(title).font(UdhaFont.regular(16)).fixedSize()
                if let badge {
                    Text(badge)
                        .font(UdhaFont.bold(11.5))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .foregroundStyle(UdhaTheme.onAccent)
                        .background(UdhaTheme.accent, in: Capsule())
                        .padding(.leading, 2)
                }
            }
            .foregroundStyle(UdhaTheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}

/// The design has no pressed-state shadows or scale — just a slight dim.
struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Controls

/// The iOS segmented control: a fill track with the selected segment lifted out
/// of it as a card.
struct SegmentedTabs<T: Hashable>: View {
    var items: [(value: T, label: String, badge: Int?)]
    @Binding var selection: T
    /// Whether the selected tab's list is currently put away. Drawn hollow so
    /// the tab shows at a glance that tapping again brings something back.
    var isCollapsed: Bool = false
    /// Tapping the tab that is already selected.
    var onReselect: ((T) -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button {
                    if selected { onReselect?(item.value) } else { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.label).font(UdhaFont.medium(14)).fixedSize()
                        if let badge = item.badge, badge > 0 {
                            Text("\(badge)")
                                .font(UdhaFont.bold(10.5))
                                .padding(.horizontal, 5)
                                .frame(minHeight: 16)
                                .foregroundStyle(UdhaTheme.onAccent)
                                .background(UdhaTheme.bad, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .foregroundStyle(selected ? UdhaTheme.label : UdhaTheme.secondary)
                    .background {
                        if selected && !isCollapsed {
                            RoundedRectangle(cornerRadius: UdhaTheme.Radius.chip, style: .continuous)
                                .fill(UdhaTheme.card)
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        } else if selected {
                            RoundedRectangle(cornerRadius: UdhaTheme.Radius.chip, style: .continuous)
                                .strokeBorder(UdhaTheme.separator, lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
            }
        }
        .padding(2)
        .background(UdhaTheme.fill,
                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.field, style: .continuous))
    }
}

/// The in-pane tab switcher — Summary / My notes / Transcript.
///
/// The same segmented control as everywhere else. Underlined tabs were the old
/// language's device; in this one the selected thing is a lifted card.
struct UnderlineTabs<T: Hashable>: View {
    var items: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        SegmentedTabs(
            items: items.map { (value: $0.value, label: $0.label, badge: nil) },
            selection: $selection
        )
    }
}

/// The search / filter field: a fill-backed rounded rect with a magnifier.
struct SearchField: View {
    var placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UdhaTheme.secondary)
            Group {
                if let focused {
                    field.focused(focused)
                } else {
                    field
                }
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused?.wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(UdhaTheme.fill,
                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.field, style: .continuous))
    }

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(UdhaFont.regular(16))
            .foregroundStyle(UdhaTheme.label)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit(onSubmit)
    }
}

/// The round checkbox on an action item.
struct CheckCircle: View {
    var done: Bool
    var diameter: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .fill(done ? UdhaTheme.accent : UdhaTheme.fill)
                .frame(width: diameter, height: diameter)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.52, weight: .bold))
                    .foregroundStyle(UdhaTheme.onAccent)
            } else {
                Circle()
                    .strokeBorder(UdhaTheme.separator, lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// The standard list row inside an inset group: a status dot, two lines, and a
/// chevron.
struct UdhaRow<Content: View>: View {
    var accessory: Color?
    var tone: SessionStatus.Tone?
    var isSelected: Bool
    var showsChevron: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            if let tone {
                StatusDot(tone: tone)
            } else if let accessory {
                LiveDot(color: accessory, size: 9)
            }
            VStack(alignment: .leading, spacing: 2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UdhaTheme.tertiary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(isSelected ? UdhaTheme.accentTint : .clear)
        .contentShape(Rectangle())
    }
}

/// Title + trailing metadata, the first line of most rows.
struct RowHeadline: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(UdhaFont.rowTitle)
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
            if let trailing {
                Spacer(minLength: 6)
                Text(trailing)
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .layoutPriority(1)
            }
        }
    }
}

/// Small metadata text.
struct MetaText: View {
    var text: String
    var tint: Color = UdhaTheme.tertiary

    var body: some View {
        Text(text)
            .font(UdhaFont.regular(12.5))
            .foregroundStyle(tint)
    }
}

// MARK: - Bubbles

/// One turn in a transcript or thread.
///
/// Asymmetric corners rather than a name label on every bubble: the tail corner
/// says who is speaking, which leaves the text the only thing to read.
struct Bubble: View {
    enum Kind { case you, them, quiet }

    var text: String
    var kind: Kind
    var stamp: String?
    var wide: Bool = false

    var body: some View {
        VStack(alignment: kind == .you ? .trailing : .leading, spacing: 3) {
            if let stamp, kind != .quiet {
                Text(stamp)
                    .font(UdhaFont.regular(11.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .padding(.horizontal, 4)
            }
            Text(text)
                .font(kind == .quiet ? UdhaFont.mono(12) : UdhaFont.regular(wide ? 15.5 : 15))
                .lineSpacing(3)
                .foregroundStyle(foreground)
                .multilineTextAlignment(kind == .quiet ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, kind == .quiet ? 4 : 13)
                .padding(.vertical, kind == .quiet ? 2 : 11)
                .background(background, in: shape)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch kind {
        case .you:   return .trailing
        case .them:  return .leading
        case .quiet: return .center
        }
    }

    private var foreground: Color {
        switch kind {
        case .you:   return UdhaTheme.onAccent
        case .them:  return UdhaTheme.label
        case .quiet: return UdhaTheme.tertiary
        }
    }

    private var background: Color {
        switch kind {
        case .you:   return UdhaTheme.accent
        case .them:  return UdhaTheme.card
        case .quiet: return .clear
        }
    }

    private var shape: UnevenRoundedRectangle {
        switch kind {
        case .you:
            return UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                          bottomTrailingRadius: 6, topTrailingRadius: 18,
                                          style: .continuous)
        case .them:
            return UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6,
                                          bottomTrailingRadius: 18, topTrailingRadius: 18,
                                          style: .continuous)
        case .quiet:
            return UnevenRoundedRectangle(cornerRadii: .init(), style: .continuous)
        }
    }
}

/// A block of mono text inside a card — the command a permission prompt is
/// asking about, a path, a snippet.
struct CodeBlock: View {
    var text: String

    var body: some View {
        Text(text)
            .font(UdhaFont.mono(12))
            .lineSpacing(3)
            .foregroundStyle(UdhaTheme.inkCode)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(UdhaTheme.fill,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Misc

/// The em-dash bullet used for notes and decisions.
struct DashItem<Content: View>: View {
    var tint: Color = UdhaTheme.tertiary
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("—")
                .font(UdhaFont.regular(14))
                .foregroundStyle(tint)
            content
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

struct EmptyHint: View {
    var systemImage: String
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(UdhaTheme.tertiary.opacity(0.7))
            Text(title)
                .font(UdhaFont.semibold(16))
                .foregroundStyle(UdhaTheme.label)
            if let subtitle {
                Text(subtitle)
                    .font(UdhaFont.regular(14))
                    .foregroundStyle(UdhaTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 28)
    }
}

/// Small uppercase field caption above a form control.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(UdhaFont.semibold(13))
            .foregroundStyle(UdhaTheme.secondary)
    }
}

// MARK: - Markdown

/// Renders the Markdown the notes pass produces, in the app's own type.
///
/// `AttributedString(markdown:)` alone collapses everything into one run and
/// drops headings and list structure, which turned a well-shaped set of notes
/// into an undifferentiated paragraph. Splitting by line and styling each one
/// keeps the shape the model was asked to produce.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .heading:
                    Text(block.inline)
                        .font(UdhaFont.semibold(15))
                        .foregroundStyle(UdhaTheme.label)
                        .padding(.top, 18)
                        .padding(.bottom, 4)
                case .bullet:
                    HStack(alignment: .top, spacing: 9) {
                        Text("—")
                            .font(UdhaFont.regular(14))
                            .foregroundStyle(UdhaTheme.tertiary)
                        Text(block.inline)
                            .font(UdhaFont.regular(15))
                            .lineSpacing(3)
                            .foregroundStyle(UdhaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                case .paragraph:
                    Text(block.inline)
                        .font(UdhaFont.regular(15))
                        .lineSpacing(3)
                        .foregroundStyle(UdhaTheme.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Block {
        enum Kind { case heading, bullet, paragraph }
        let kind: Kind
        let inline: AttributedString
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return Block(kind: .heading, inline: Self.inline(text))
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return Block(kind: .bullet, inline: Self.inline(String(line.dropFirst(marker.count))))
            }
            return Block(kind: .paragraph, inline: Self.inline(line))
        }
    }

    /// Bold and italic survive; anything the parser cannot handle falls back to
    /// the raw text rather than rendering nothing.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Screen chrome

/// The phone's large-title header: the screen's name, a line of counts under
/// it, and up to two 44pt round buttons on the right.
///
/// Not a `navigationTitle`. The design puts a live subtitle under the title and
/// round accessories beside it, neither of which a stock large title will hold.
struct LargeTitleHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(UdhaFont.largeTitle)
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) { trailing }
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

/// The iPad master column header: a menu button that brings the sidebar over,
/// the column's name, and its primary action.
struct PadListHeader<Trailing: View>: View {
    var title: String
    var onMenu: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let onMenu {
                CircleButton(systemImage: "line.3.horizontal", diameter: 40, action: onMenu)
                    .accessibilityLabel("Show sidebar")
            }
            Text(title)
                .font(UdhaFont.bold(22))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A detail screen's nav bar: where you came from on the left, what you are
/// looking at in the middle, one control on the right.
struct DetailNavBar<Trailing: View>: View {
    var backTitle: String?
    var backBadge: String?
    var onBack: (() -> Void)?
    /// Empty means the screen carries its own large title below the bar, and a
    /// truncated copy of it here would only be noise.
    var title: String = ""
    var subtitle: String?
    /// Drawn only when the title needs to be separated from what scrolls under
    /// it — a transcript, a thread. A screen with its own big title below does
    /// not want a second line here.
    var showsSeparator: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let backTitle, let onBack {
                    BackButton(title: backTitle, badge: backBadge, action: onBack)
                }
            }
            .frame(minWidth: 0)

            VStack(spacing: 0) {
                if !title.isEmpty {
                    Text(title)
                        .font(UdhaFont.navTitle)
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(UdhaFont.regular(11.5))
                            .foregroundStyle(UdhaTheme.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(.clear)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle().fill(UdhaTheme.separator).frame(height: 0.5)
            }
        }
    }
}

/// The bottom tab bar: five icons on the chrome blur, the active one in the
/// accent, an unread count riding the badge corner.
struct UdhaTabBar: View {
    var items: [Item]
    @Binding var selection: String

    struct Item: Identifiable {
        var id: String
        var label: String
        var systemImage: String
        var badge: Int?
        /// A recording indicator instead of a count.
        var recording: Bool = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button { selection = item.id } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 20, weight: .regular))
                                .frame(width: 28, height: 26)
                            if item.recording {
                                RecordingDot(size: 7).offset(x: 4, y: -1)
                            } else if let badge = item.badge, badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(UdhaFont.bold(11))
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .foregroundStyle(.white)
                                    .background(UdhaTheme.bad, in: Capsule())
                                    .offset(x: 10, y: -4)
                            }
                        }
                        Text(item.label).font(UdhaFont.medium(11))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .foregroundStyle(selected ? UdhaTheme.accent : UdhaTheme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(UdhaTheme.chrome)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(UdhaTheme.separator).frame(height: 0.5)
        }
    }
}

/// The bar a composer or a key row sits on: the chrome blur with a hairline
/// above it, extended into the home-indicator inset.
struct ChromeBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background {
                Rectangle()
                    .fill(.regularMaterial)
                    .overlay(UdhaTheme.chrome)
                    .ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(UdhaTheme.separator).frame(height: 0.5)
            }
    }
}

/// The message composer: an add button, a rounded field, and a send button.
struct Composer<Field: View>: View {
    var leading: (() -> AnyView)?
    var trailing: (() -> AnyView)?
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 9) {
            if let leading { leading() }
            field
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .padding(.horizontal, 13)
                .background(UdhaTheme.card, in: Capsule())
                .overlay { Capsule().strokeBorder(UdhaTheme.separator, lineWidth: 0.5) }
            if let trailing { trailing() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// A master list's rows: one inset card on a phone, flat selectable rows in an
/// iPad column.
///
/// The card is what makes a grouped list read on a canvas. In the iPad's master
/// column it reads as nothing at all — the column's own surface is within a
/// couple of percent of the card's, so the card edge disappears and all it
/// contributes is a 12pt inset. Flat rows with a rounded selection are what the
/// design draws there, and they are also what lets the selected row be the
/// accent rather than a tint.
struct MasterList<Item: Identifiable, Row: View>: View {
    var items: [Item]
    var compact: Bool
    var separatorInset: CGFloat = 14
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        if compact {
            InsetGroup(items: items, separatorInset: separatorInset, row: row)
        } else {
            LazyVStack(spacing: 4) {
                ForEach(items) { item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                    style: .continuous))
                }
            }
        }
    }
}

/// How a master-list row paints when it is the selected one.
///
/// Solid accent in an iPad column, a tint on a phone. The iPad column is a
/// standing selection you are reading a detail pane *from*, so it has to hold
/// its place across the screen; a phone row is only ever selected for the
/// instant before the push, where a full accent bar would read as a button.
struct MasterSelection {
    var compact: Bool
    var selected: Bool

    var background: Color {
        guard selected else { return .clear }
        return compact ? UdhaTheme.accentTint : UdhaTheme.accent
    }

    private var onAccent: Bool { selected && !compact }

    var label: Color { onAccent ? UdhaTheme.onAccent : UdhaTheme.label }
    var secondary: Color { onAccent ? UdhaTheme.onAccent.opacity(0.82) : UdhaTheme.secondary }
    var tertiary: Color { onAccent ? UdhaTheme.onAccent.opacity(0.7) : UdhaTheme.tertiary }
    /// The chevron, which is quieter again.
    var chevron: Color {
        onAccent ? UdhaTheme.onAccent.opacity(0.6) : UdhaTheme.tertiary.opacity(0.55)
    }
}
