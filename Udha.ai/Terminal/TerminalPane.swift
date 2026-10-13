import SwiftUI

/// The live pane view: ANSI frames, anchored bottom-left, with zoom.
///
/// Two things this has to get right that a plain `ScrollView` does not:
///
/// 1. **Anchor bottom-*leading*, not bottom.** Auto-scrolling to `.bottom` in a
///    two-axis scroll view drags the horizontal offset to the trailing edge
///    too, which parks you on the blank right-hand side of a wide pane and
///    hides every line of actual output.
/// 2. **Zoom.** A tmux pane is typically 100–120 columns; an iPad mini is not
///    that wide at a readable point size. Rather than shrink the type
///    permanently, the reader picks: pinch, the ± buttons, or "Fit" to size the
///    text so the widest line exactly spans the view.
struct TerminalPane: View {
    let ansi: String
    let seq: Int
    /// Reports the character grid this view can display, whenever it changes.
    /// The host uses it to size the real tmux window to this screen — which is
    /// the only way the text comes out right, since a pane already rendered for
    /// 362 columns cannot be re-wrapped to 44 after the fact.
    var onGridChange: ((Int, Int) -> Void)? = nil
    /// Bound to the bridge's `matchHostToScreen`. Nil when the host cannot
    /// resize, which is how the control stays off screen for an older desktop
    /// rather than offering something that would silently do nothing.
    var matchHost: Binding<Bool>? = nil
    /// History above the live pane, nearest-first as the bridge holds it.
    var scrollback: [ScrollbackChunk] = []
    var hasMoreScrollback = false
    var isLoadingScrollback = false
    var onLoadEarlier: (() -> Void)? = nil

    /// Persisted so the zoom you chose survives leaving and reopening a session.
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13
    @State private var pinchStart: Double?
    @State private var showControls = true
    /// Whether new output should pull the view to the bottom.
    ///
    /// The pane used to follow unconditionally, which made reading anything but
    /// the last screenful impossible: scroll up, and the next frame — one
    /// keystroke of Claude's output — yanked you back down. Following is now
    /// something the view stops doing the moment you scroll away from the
    /// bottom, and resumes when you return to it.
    @State private var isFollowing = true
    /// The block to re-anchor on after older history is prepended, so loading
    /// more does not shift the text you were mid-sentence in.
    @State private var prependAnchor: String?
    @State private var scrollY: CGFloat = 0
    /// URLs in the live frame, newest first. Recomputed per frame rather than
    /// per body pass: `body` also runs on every scroll tick, and scanning the
    /// pane on each of those to answer a question only new output can change
    /// would be work for nothing.
    @State private var links: [TerminalLinks.Hit] = []
    @Environment(\.openURL) private var openURL

    private let minSize: Double = 5
    private let maxSize: Double = 22

    /// `capture-pane` pads its output to the full pane height, so an idle
    /// session arrives with a block of empty rows below its last line. Hosts
    /// trim this now, but do it here too: scrollback chunks come from a
    /// different path, and an older desktop still sends the raw grid.
    private var trimmed: String { ANSIText.trimTrailingBlankLines(ansi) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                UdhaTheme.Term.background

                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            historyHeader
                            // Reversed: the bridge stores history
                            // nearest-first, but it has to be drawn
                            // oldest-at-the-top to read as one transcript.
                            ForEach(scrollback.reversed(), id: \.offset) { page in
                                block(page.ansi).id("sb-\(page.offset)")
                            }
                            block(trimmed).id("tail")
                        }
                        // minHeight belongs on the whole stack, not on the live
                        // block. Putting it on the block made the content taller
                        // than the viewport by exactly the height of the header
                        // above it — so the pane opened scrolled to the bottom
                        // and the "earlier output" control sat just off-screen,
                        // which is a poor showing for a button whose entire job
                        // is to be found. Without it, a capture shorter than
                        // the viewport gets centred vertically and reads as a
                        // rendering fault.
                        .frame(minWidth: geo.size.width,
                               minHeight: geo.size.height,
                               alignment: .topLeading)
                    }
                    // Swiping the pane puts the keyboard away, the same
                    // gesture that works in Messages and Mail. With a hardware
                    // keyboard there is nothing on screen to put away, and
                    // dropping focus would silently stop your typing from
                    // reaching the pane — so scrolling leaves focus alone.
                    .scrollDismissesKeyboard(
                        HardwareKeyboard.shared.isAttached ? .never : .interactively)
                    // Following is a consequence of where you are, not a mode
                    // you set: sitting at the bottom means you want the newest
                    // line, and being anywhere else means you are reading.
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let maxOffset = geometry.contentSize.height
                            - geometry.containerSize.height
                            - geometry.contentInsets.bottom
                        return geometry.contentOffset.y >= maxOffset - 24
                    } action: { _, atBottom in
                        isFollowing = atBottom
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                        scrollY = y
                    }
                    // Loading is tied to the scroll *settling*, not to the
                    // geometry changing. Geometry changes when the content
                    // grows — so loading on it meant each arriving page
                    // triggered the next, and the pane quietly drained the
                    // host's entire scrollback in one go the first time it was
                    // opened. Settling is a thing only a person does.
                    .onScrollPhaseChange { previous, phase in
                        // The transition has to come from a finger. Prepending
                        // a page moves the scroll view itself — re-anchoring so
                        // the reader does not jump — and that settles to `idle`
                        // too, which is enough to ask for the next page, and
                        // the next. Requiring the *previous* phase to be a drag
                        // or its momentum is what separates "a person stopped
                        // here" from "the content changed underneath them".
                        guard phase == .idle,
                              previous == .interacting || previous == .decelerating,
                              scrollY <= 40
                        else { return }
                        loadEarlierIfAtTop()
                    }
                    .onChange(of: seq) { _, _ in
                        guard isFollowing else { return }
                        // bottomLeading, not bottom: follow the newest line
                        // without being dragged to the far right of the pane.
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("tail", anchor: .bottomLeading)
                        }
                    }
                    // Older text arrives *above* the reader, which would other-
                    // wise shove the line they were on down the screen. Re-pin
                    // to whatever was topmost before the page landed.
                    .onChange(of: scrollback.count) { previous, current in
                        guard current > previous, let anchor = prependAnchor else { return }
                        proxy.scrollTo(anchor, anchor: .top)
                        prependAnchor = nil
                    }
                    .onAppear { proxy.scrollTo("tail", anchor: .bottomLeading) }
                    .overlay(alignment: .bottom) {
                        if !isFollowing { latestButton(proxy) }
                    }
                }

                if showControls {
                    controls(available: geo.size.width)
                        .padding(10)
                }

                linkBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .onAppear { refreshLinks() }
            .onChange(of: seq) { _, _ in refreshLinks() }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchStart ?? fontSize
                        if pinchStart == nil { pinchStart = fontSize }
                        fontSize = min(maxSize, max(minSize, base * value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .onTapGesture(count: 2) { fit(to: geo.size.width) }
            // Every input to the grid, in one place: the viewport changes on
            // rotation, split-view drags and the keyboard appearing; the font
            // size changes on pinch and on the ± buttons.
            .onAppear { reportGrid(geo.size) }
            .onChange(of: geo.size) { _, size in reportGrid(size) }
            .onChange(of: fontSize) { _, _ in reportGrid(geo.size) }
        }
    }

    private func reportGrid(_ viewport: CGSize) {
        guard let onGridChange, viewport.width > 0, viewport.height > 0 else { return }
        let grid = TerminalGrid.grid(viewport: viewport, fontSize: fontSize)
        onGridChange(grid.cols, grid.rows)
    }

    private func block(_ ansi: String) -> some View {
        Text(ANSIText.render(ansi, baseFont: UdhaFont.mono(fontSize)))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(alignment: .topLeading)
    }

    /// The top of the transcript: a way up, a spinner while a page is in
    /// flight, and an end-stop when tmux has no more history to give.
    ///
    /// A button rather than scroll-position alone. Reaching the top by dragging
    /// also loads, but that cannot be the only route: a session whose visible
    /// output is shorter than the screen never scrolls at all, so there is no
    /// top edge to reach — and those are exactly the sessions whose interesting
    /// output has already scrolled off.
    @ViewBuilder
    private var historyHeader: some View {
        if isLoadingScrollback {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(UdhaTheme.Term.dim)
                Text("loading earlier output…")
                    .font(UdhaFont.regular(12))
                    .foregroundStyle(UdhaTheme.Term.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else if hasMoreScrollback {
            Button { loadEarlierIfAtTop() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                    Text("earlier output").font(UdhaFont.regular(12))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(UdhaTheme.Term.out)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(PressDim())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else if !scrollback.isEmpty {
            Text("— start of scrollback —")
                .font(UdhaFont.regular(12))
                .foregroundStyle(UdhaTheme.Term.dim)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    /// Shown only while you are reading history. Without it, getting back to
    /// the live output means scrolling an unknown distance by hand.
    private func latestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowing = true
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("tail", anchor: .bottomLeading)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                Text("Latest").font(UdhaFont.semibold(13))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .foregroundStyle(UdhaTheme.onAccent)
            .background(UdhaTheme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(PressDim())
        .padding(.bottom, 10)
    }

    private func loadEarlierIfAtTop() {
        guard hasMoreScrollback, !isLoadingScrollback, let onLoadEarlier else { return }
        // Remember the block currently at the top so the incoming page can be
        // slid in above it without moving it.
        prependAnchor = scrollback.last.map { "sb-\($0.offset)" } ?? "tail"
        onLoadEarlier()
    }

    // MARK: - Links

    /// Sign-in URLs and other links in the live frame, as buttons.
    ///
    /// The pane already draws them as tappable text, but a 13-point mono link
    /// in a wall of output is a small target you have to find first — and the
    /// command that printed it is usually *blocked*, polling, with a code that
    /// expires in ten minutes. `aws sso login --no-browser` is the case this
    /// was built for: the Mac cannot open that page usefully, the iPad can.
    ///
    /// Pinned to the top because the bottom is where the newest output lands,
    /// and covering that is how you end up reading a login prompt through a
    /// button bar.
    @ViewBuilder
    private var linkBar: some View {
        if !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(links, id: \.url) { hit in
                        Button { openURL(hit.url) } label: { linkChip(hit) }
                            .buttonStyle(PressDim())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(UdhaTheme.Term.keyBar.opacity(0.96))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
            }
        }
    }

    /// Newest last on screen means newest *first* in the bar: the URL that
    /// just appeared is the one something is waiting on.
    private func refreshLinks() {
        links = Array(TerminalLinks.detect(inANSI: trimmed).reversed())
    }

    private func linkChip(_ hit: TerminalLinks.Hit) -> some View {
        HStack(spacing: 6) {
            Image(systemName: hit.isSignIn ? "person.badge.key.fill" : "arrow.up.forward")
                .font(.system(size: 10, weight: .bold))
            Text(hit.isSignIn ? "Sign in" : (hit.url.host ?? "Open"))
                .font(UdhaFont.semibold(12))
                .lineLimit(1)
            // The code the page will ask you to confirm. Shown so the match can
            // be made on sight, without scrolling back to the line that
            // printed it.
            if let code = hit.code {
                Text(code)
                    .font(UdhaFont.mono(11))
                    .tracking(1)
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .foregroundStyle(hit.isSignIn ? UdhaTheme.onAccent : UdhaTheme.Term.out)
        .background(hit.isSignIn ? UdhaTheme.accent : Color.white.opacity(0.12), in: Capsule())
    }

    // MARK: - Controls

    private func controls(available: CGFloat) -> some View {
        HStack(spacing: 2) {
            zoomButton("minus") { fontSize = max(minSize, fontSize - 1) }
            zoomButton("plus") { fontSize = min(maxSize, fontSize + 1) }
            Button { fit(to: available) } label: {
                Text("Fit")
                    .font(UdhaFont.semibold(12))
                    .frame(width: 36, height: 30)
                    .foregroundStyle(UdhaTheme.Term.out)
            }
            .buttonStyle(PressDim())

            // The inverse of FIT, and worth the neighbouring slot for that
            // reason: FIT shrinks the type until the Mac's pane fits this
            // screen, MATCH reshapes the Mac's pane to fit type at the size you
            // already chose. Only one of them leaves the text readable.
            if let matchHost {
                Button { matchHost.wrappedValue.toggle() } label: {
                    Text("Match")
                        .font(UdhaFont.semibold(12))
                        .frame(width: 50, height: 30)
                        .foregroundStyle(matchHost.wrappedValue
                                         ? UdhaTheme.onAccent : UdhaTheme.Term.out)
                        .background(matchHost.wrappedValue ? UdhaTheme.accent : .clear,
                                    in: Capsule())
                }
                .buttonStyle(PressDim())
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.12), in: Capsule())
        .opacity(0.9)
    }

    private func zoomButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(UdhaTheme.Term.out)
        }
        .buttonStyle(PressDim())
    }

    /// Size the text so the widest line spans the view exactly.
    ///
    /// Monospace advance width is a fixed fraction of point size (~0.6 for SF
    /// Mono), so the fit can be computed from the longest line's character
    /// count without laying anything out and measuring.
    private func fit(to width: CGFloat) {
        let longest = trimmed
            .components(separatedBy: .newlines)
            .map { ANSIText.visibleLength($0) }
            .max() ?? 80
        guard longest > 0 else { return }
        let usable = max(80, width - 24)   // minus horizontal padding
        let ideal = Double(usable) / (Double(longest) * 0.601)
        fontSize = min(maxSize, max(minSize, (ideal * 2).rounded() / 2))
    }
}
