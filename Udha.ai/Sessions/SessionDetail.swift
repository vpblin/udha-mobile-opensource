import SwiftUI

/// A session up close: a nav bar, the live terminal, and then the blocked card
/// and the composer.
///
/// The terminal is the detail pane itself, not a screen behind a button. That is
/// this app's central claim — you are looking at the real pane, and approving is
/// a thing you do to what you can see. The redesign does not touch that: the
/// design's chat transcript is a picture of what a *session* looks like, and a
/// session here is a tmux pane, so the pane keeps its dark ground and its full
/// width. What changes is everything around it — a proper nav bar, chips instead
/// of a monospace smear, a card for the permission prompt, and a composer that
/// looks like a composer.
struct SessionDetail: View {
    let bridge: UdhaBridge
    let sessionID: String
    /// Bound to the shell so the pane can claim the whole display.
    var fullScreen: Binding<Bool>? = nil
    /// Pops back to the list. Nil when the list is beside us.
    var onBack: (() -> Void)? = nil
    /// Opens the command palette — the iPad design's ⌘K.
    var onCommands: () -> Void = {}

    @State private var draft = ""
    @State private var ctrlLatched = false
    @State private var showingDiff = false
    @State private var renaming = false
    @State private var confirmingTerminate = false
    @State private var confirmingRemove = false
    /// The block the user has waved away, identified by what it says.
    ///
    /// Dismissing sends nothing and resolves nothing — the pane still holds the
    /// dialog and the key row can still answer it. It only puts away a card
    /// that is in the way, which matters most when the host's question parser
    /// has misfired and the "question" is a stray line of output. A *new* block
    /// has different text, so the card comes back on its own.
    @State private var dismissedBlock: String?
    @FocusState private var composerFocused: Bool

    private var row: SessionRow? { bridge.session(id: sessionID) }
    private var isPending: Bool { bridge.pendingActions.contains(sessionID) }
    private var isBlocked: Bool {
        guard let row, row.isBlocking else { return false }
        return blockKey(row) != dismissedBlock
    }

    /// Identifies one block by what it is asking, so dismissing this question
    /// never hides the next one.
    private func blockKey(_ row: SessionRow) -> String {
        [sessionID, row.phase.rawValue, row.lastQuestion ?? row.statusDetail ?? ""].joined(separator: "\u{1F}")
    }
    /// Only offer the control when the paired host actually implements it.
    private var canResizeHost: Bool { row.map { bridge.canResize($0) } ?? false }
    private var isFull: Bool { fullScreen?.wrappedValue ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if let row {
                if !isFull {
                    header(row)
                    metaStrip(row)
                }
                if bridge.terminalIsStale { staleBar }
                terminal
                // The blocked card sits *above* the composer rather than
                // replacing it. Swapping them took the 1 / 2 / 3 / Enter / Esc
                // keys away at exactly the moment a dialog needed answering —
                // and since Approve could only ever press "1", a three-option
                // prompt became unanswerable and the session stopped dead.
                if row.supportsAttentionEvents {
                    AttentionInbox(bridge: bridge, sessionID: sessionID) { _ in composerFocused = true }
                        .padding(.horizontal, 10)
                } else if row.phase == .awaitingApproval && isBlocked { blockedCard(row) }
                // In the stack rather than overlaid on it. As an overlay this
                // sat squarely on the composer — so the message telling you the
                // tap did nothing also hid the field you would have typed in.
                actionErrorToast
                AttachmentBar(bridge: bridge, sessionID: sessionID)
                composer
            } else {
                ZStack {
                    UdhaTheme.canvas
                    EmptyHint(systemImage: "questionmark.folder", title: "Session ended",
                              subtitle: "It is no longer on the fleet.")
                }
            }
        }
        .background(UdhaTheme.canvas)
        // Top-*trailing*: the terminal pins its own "earlier output" control to
        // the top-leading corner, and in full screen these two landed on each
        // other at the same inset — so the one control that leaves full screen
        // was half-covered by the one that loads scrollback, and which of them
        // took the tap was a coin flip.
        .overlay(alignment: .topTrailing) { if isFull { exitFullScreenButton } }
        .task(id: sessionID) { bridge.attachTerminal(to: sessionID) }
        .task(id: "attention-" + sessionID) {
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active { bridge.attentionPresence(sessionID) }
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            }
        }
        .onDisappear { bridge.attentionPresence(nil); bridge.detachTerminal() }
        .sheet(isPresented: $showingDiff) {
            DiffView(bridge: bridge, sessionID: sessionID)
        }
        .sheet(isPresented: $renaming) {
            if let row {
                RenameSheet.session(bridge: bridge, row: row)
            }
        }
        // Two dialogs, not one with two buttons: these do different things and
        // only one of them is undoable. Wording matches the Mac's verbs.
        .confirmationDialog("Terminate this session?",
                            isPresented: $confirmingTerminate, titleVisibility: .visible) {
            Button("Terminate", role: .destructive) { bridge.killSession(id: sessionID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SessionDestruction.terminateExplanation)
        }
        .confirmationDialog("Remove this session?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { bridge.closeSession(id: sessionID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SessionDestruction.removeExplanation)
        }
    }

    // MARK: - Header

    private func header(_ row: SessionRow) -> some View {
        DetailNavBar(
            backTitle: onBack == nil ? nil : "Sessions",
            onBack: onBack,
            title: row.label,
            subtitle: hostLine(row),
            showsSeparator: false
        ) {
            CircleButton(systemImage: "magnifyingglass", diameter: 36, action: onCommands)
                .accessibilityLabel("Commands")
            CircleButton(systemImage: "plusminus", diameter: 36) { showingDiff = true }
                .accessibilityLabel("Review changes")
            overflowButton
        }
    }

    /// The machine this session runs on — not the one the app happens to be
    /// pointed at. With the fleet merged into one list, a devbox session read
    /// "MBPro" because this asked the bridge for its *active* instance.
    private func hostLine(_ row: SessionRow) -> String? {
        let name = bridge.machineName(for: row)
        // Vitals are only held for the machine we subscribe to for stats, so a
        // latency figure is only quotable next to that machine's own name.
        if row.instanceID == bridge.activeInstanceID,
           let rtt = bridge.machineStats?.relay?.rttMilliseconds {
            return "\(name) · \(String(format: "%.0f ms", rtt))"
        }
        return name
    }

    /// The session's facts as chips: where it is, what it is on, how full it is.
    /// The same three the desktop's pane header carries, in the design's pills
    /// rather than a run of monospace separated by dots.
    private func metaStrip(_ row: SessionRow) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if bridge.canUseAttention(row) {
                    Button {
                        bridge.changeAttention(sessionID, action: "watch", enabled: !row.attentionState.notifyWhenDone)
                    } label: {
                        Pill(row.attentionState.notifyWhenDone ? "Will notify when done" : "Notify when done",
                             tint: UdhaTheme.accentInk, icon: row.attentionState.notifyWhenDone ? "bell.fill" : "bell")
                    }.buttonStyle(PressDim())
                }
                if let branch = row.branch, row.isWorktree {
                    QuietPill(branch, icon: "arrow.triangle.branch")
                } else if !row.directoryName.isEmpty {
                    QuietPill(row.directoryName, icon: "folder")
                }
                if let model = row.modelBadge {
                    Pill(model, tint: UdhaTheme.accentInk)
                }
                LoginPill(bridge: bridge, row: row)
                if let context = row.contextPercent {
                    QuietPill("ctx \(context)%")
                }
                if let cost = row.costDisplay {
                    QuietPill(cost)
                }
                if row.subagentCount > 0 {
                    QuietPill("\(row.subagentCount) sub", icon: "square.stack.3d.up")
                }
                Button { bridge.interrupt(sessionID) } label: {
                    Pill("Stop", tint: UdhaTheme.badInk, icon: "stop.fill")
                }
                .buttonStyle(PressDim())
                .disabled(isPending)
                if let fullScreen {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { fullScreen.wrappedValue = true }
                    } label: {
                        Pill("Full", tint: UdhaTheme.secondary,
                             icon: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(PressDim())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// Duplicate / Terminate / Remove, the same set the Mac's sidebar offers.
    private var overflowButton: some View {
        Menu {
            if let row, bridge.canUseAttention(row) {
                Button(row.attentionState.notifyWhenDone ? "Cancel completion notification" : "Notify me when done") {
                    bridge.changeAttention(sessionID, action: "watch", enabled: !row.attentionState.notifyWhenDone)
                }
                Toggle("Notify for reviews", isOn: Binding(get: { row.attentionState.notifyReviews },
                    set: { bridge.changeAttention(sessionID, action: "reviews", enabled: $0) }))
                Toggle("Notify for completions", isOn: Binding(get: { row.attentionState.notifyCompletions },
                    set: { bridge.changeAttention(sessionID, action: "completions", enabled: $0) }))
                Divider()
            }
            if let row, bridge.canRename(row) {
                Button("Rename…") { renaming = true }
            }
            Button("Duplicate") { bridge.duplicateSession(id: sessionID) }
            if let row, bridge.canSwitchLogin(row) {
                Menu("Switch Claude login") { LoginSwitchItems(bridge: bridge, row: row) }
            }
            Divider()
            Button("Terminate") { confirmingTerminate = true }
            Button("Remove", role: .destructive) { confirmingRemove = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(UdhaTheme.label)
                .background(UdhaTheme.fill, in: Circle())
        }
        .disabled(isPending)
    }

    // MARK: - Terminal

    /// The pane, as a card on the canvas.
    ///
    /// Inset by 10pt rather than bled to the edges: in this language a surface
    /// that touches the screen edge reads as the screen itself, and the pane is
    /// a *thing on* the screen. The cost is three columns at the default zoom,
    /// which "Full" gives straight back.
    private var terminal: some View {
        TerminalPane(
            ansi: bridge.terminalANSI,
            seq: bridge.terminalSeq,
            onGridChange: { cols, rows in bridge.setTerminalGrid(cols: cols, rows: rows) },
            matchHost: canResizeHost
                ? Binding(get: { bridge.matchHostToScreen },
                          set: { bridge.matchHostToScreen = $0 })
                : nil,
            scrollback: bridge.scrollbackPages,
            hasMoreScrollback: bridge.scrollbackHasMore,
            isLoadingScrollback: bridge.scrollbackLoading,
            onLoadEarlier: { bridge.fetchMoreScrollback() }
        )
        .clipShape(RoundedRectangle(cornerRadius: isFull ? 0 : UdhaTheme.Radius.card,
                                    style: .continuous))
        // A five-option dialog is tall enough to squeeze the pane to nothing,
        // which defeats the point of answering while looking at it.
        .frame(minHeight: 150)
        .layoutPriority(1)
        .padding(.horizontal, isFull ? 0 : 10)
        .padding(.bottom, isFull ? 0 : 10)
    }

    // MARK: - Action errors

    @ViewBuilder
    private var actionErrorToast: some View {
        if let error = bridge.lastActionError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(error)
                    .font(UdhaFont.medium(13.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    bridge.clearActionError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(PressDim())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .foregroundStyle(UdhaTheme.badInk)
            .background(UdhaTheme.badTint,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous)
                    .strokeBorder(UdhaTheme.bad.opacity(0.5), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // Long enough to read, short enough not to sit on the composer.
            .task(id: error) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                bridge.clearActionError()
            }
        }
    }

    // MARK: - Stale bar

    /// Shown only when the pane genuinely cannot be trusted — the host
    /// connection is down, or an attach went unanswered.
    ///
    /// It exists because the old failure mode had no exit: the pane froze, the
    /// chrome kept insisting everything was fine, and there was no control
    /// anywhere that would force the issue. Whatever else is true, there is now
    /// always something to tap.
    private var staleBar: some View {
        HStack(spacing: 9) {
            LiveDot(color: UdhaTheme.bad, animated: true, size: 7)

            // Ticks only while the bar is on screen, which by definition means
            // something is already wrong — so this costs nothing in the normal
            // case, and the alternative is a label that quietly lies about how
            // old the output is.
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text(staleMessage)
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.badInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await bridge.hardReconnect() }
            } label: {
                Pill("Reconnect", tint: UdhaTheme.bad, solid: true)
            }
            .buttonStyle(PressDim())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(UdhaTheme.badTint)
        .padding(.horizontal, 10)
        .clipShape(RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        .padding(.bottom, 8)
    }

    private var staleMessage: String {
        let cause: String
        switch bridge.status {
        case .connecting, .pairing: return "Reconnecting…"
        case .ready:                cause = "Pane not responding"
        case .awaitingHost:         cause = "Host offline"
        default:                    cause = "Disconnected"
        }
        // A pane that never received a first frame has no "last output" to
        // date, and "last output — ago" is worse than saying nothing.
        guard bridge.lastFrameAt != nil else { return cause }
        return "\(cause) · last output \(bridge.terminalAge) ago"
    }

    // MARK: - Blocked

    /// The couch workflow's whole point: what Claude wants, and the buttons.
    ///
    /// The design's permission card, wired to the real prompt: the kicker names
    /// the kind of block, the ask is the host's own words, and the mono block is
    /// the command it is asking about when there is one.
    private func blockedCard(_ row: SessionRow) -> some View {
        let isApproval = row.phase == .awaitingApproval
        return UdhaCard(ring: isApproval ? UdhaTheme.accent : UdhaTheme.warn) {
            HStack(spacing: 8) {
                Image(systemName: isApproval ? "lock" : "bubble.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isApproval ? UdhaTheme.accent : UdhaTheme.warn)
                Text(row.blockedKind)
                    .kicker(isApproval ? UdhaTheme.accentInk : UdhaTheme.warnInk)
                Spacer(minLength: 8)
                Text(row.phaseAge)
                    .font(UdhaFont.regular(12))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.secondary)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { dismissedBlock = blockKey(row) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(UdhaTheme.secondary)
                        .background(UdhaTheme.fill, in: Circle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel("Put this away")
            }

            Text(row.lastQuestion ?? row.statusDetail ?? "Waiting on you")
                .font(UdhaFont.regular(15))
                .lineSpacing(3)
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            // Only when it is genuinely a second fact. The host sends the same
            // string as both `lastQuestion` and `statusDetail` for most prompts,
            // and printing it twice made the card look like a rendering bug.
            if let detail = row.statusDetail, let question = row.lastQuestion,
               detail != question, !detail.isEmpty {
                CodeBlock(text: detail).padding(.top, 8)
            }

            blockedButtons(row).padding(.top, 12)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func blockedButtons(_ row: SessionRow) -> some View {
        let options = row.dialogOptions
        if row.phase == .awaitingReply {
            // A question, not a dialog. There is nothing on the pane to press
            // "1" against, so offering Allow / Deny here produced exactly one
            // outcome: the host answering "no dialog on screen". You answer a
            // question by typing, so the button opens the composer.
            Button { composerFocused = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Reply").font(UdhaFont.button)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(UdhaTheme.onAccent)
                .background(UdhaTheme.accent,
                            in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                 style: .continuous))
            }
            .buttonStyle(PressDim())
        } else if options.isEmpty {
            // No parsed choices: an older host, or a prompt whose shape we will
            // not guess at. Approve presses "1", which is what it always did.
            HStack(spacing: 8) {
                Button { bridge.approve(sessionID) } label: {
                    Text("Allow once")
                        .font(UdhaFont.button)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(UdhaTheme.onAccent)
                        .background(UdhaTheme.accent,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                         style: .continuous))
                }
                .buttonStyle(PressDim())

                Button { bridge.deny(sessionID) } label: {
                    Text("Deny")
                        .font(UdhaFont.medium(16))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(UdhaTheme.label)
                        .background(UdhaTheme.fill,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                         style: .continuous))
                }
                .buttonStyle(PressDim())
            }
            .disabled(isPending)
        } else {
            // One button per choice, in screen order, labelled with what the
            // dialog actually says. Tapping sends that digit — the host has
            // always accepted an option number; nothing had ever sent one.
            VStack(spacing: 7) {
                ForEach(options) { option in
                    Button {
                        bridge.approve(sessionID, option: option.number)
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(option.number)")
                                .font(UdhaFont.mono(12, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .foregroundStyle(option.isSelected ? UdhaTheme.onAccent : UdhaTheme.secondary)
                                .background(option.isSelected ? UdhaTheme.accent : UdhaTheme.fill,
                                            in: Circle())
                            Text(option.label)
                                .font(UdhaFont.medium(15))
                                .foregroundStyle(UdhaTheme.label)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(option.isSelected ? UdhaTheme.accentTint : UdhaTheme.fill,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                         style: .continuous))
                    }
                    .buttonStyle(PressDim())
                }
            }
            .disabled(isPending)
        }
    }

    /// The only chrome left in full screen.
    private var exitFullScreenButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { fullScreen?.wrappedValue = false }
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                // 44pt. It was 34 — under the minimum for a target, and this is
                // the only way out of a mode with no other chrome in it.
                .frame(width: 44, height: 44)
                .foregroundStyle(UdhaTheme.Term.bright)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
        }
        .buttonStyle(PressDim())
        .padding(.trailing, 12)
        .padding(.top, 10)
        .accessibilityLabel("Exit full screen")
    }

    // MARK: - Composer

    private var composer: some View {
        ChromeBar {
            // Keys a software keyboard can't produce. Ctrl latches so the next
            // tap composes a chord.
            //
            // This row *is* the keyboard accessory. There used to be a second
            // one — a `ToolbarItemGroup(placement: .keyboard)` carrying its own
            // esc and Done — which iOS 26 draws as floating pills over the
            // content rather than as a bar above the keyboard, so they landed
            // squarely on the composer's add and send buttons. Two accessory
            // rows for one text field was a duplicate before it was a
            // collision: `esc` is the first key here already.
            HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc") { send(["Escape"]) }
                    key("tab") { send(["Tab"]) }
                    key("⇧tab") { send(["BTab"]) }
                    key("ctrl", latched: ctrlLatched) { ctrlLatched.toggle() }
                    key("↑") { send(["Up"]) }
                    key("↓") { send(["Down"]) }
                    key("←") { send(["Left"]) }
                    key("→") { send(["Right"]) }
                    key("1") { send(["1"]) }
                    key("2") { send(["2"]) }
                    key("3") { send(["3"]) }
                    key("⏎") { send(["Enter"]) }
                    key("^C") { bridge.sendKeys(to: sessionID, keys: ["C-c"]) }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.top, 9)
                .padding(.bottom, 2)
            }

            // Pinned rather than scrolled: a phone keyboard covers most of the
            // pane, and the way out must not be something you have to scroll a
            // key row sideways to find. Hidden when there is no software
            // keyboard to put away.
            if composerFocused, !HardwareKeyboard.shared.isAttached {
                Button { composerFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 32)
                        .foregroundStyle(UdhaTheme.label)
                        .background(UdhaTheme.fill,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.chip,
                                                         style: .continuous))
                }
                .buttonStyle(PressDim())
                .accessibilityLabel("Hide the keyboard")
                .padding(.trailing, 14)
                .padding(.top, 9)
                .padding(.bottom, 2)
            }
            }

            HStack(spacing: 9) {
                // Hidden against a host that predates `put_attachment` rather
                // than disabled: it would pick a photo and then have nowhere to
                // put it.
                if bridge.canStageAttachments {
                    AttachmentPickerButton(bridge: bridge, sessionID: sessionID)
                }

                TextField(composerPrompt, text: $draft)
                    .textFieldStyle(.plain)
                    .font(UdhaFont.mono(15))
                    .foregroundStyle(UdhaTheme.label)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(UdhaTheme.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(UdhaTheme.separator, lineWidth: 0.5) }
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(canSend ? UdhaTheme.onAccent : UdhaTheme.tertiary)
                        .background(canSend ? UdhaTheme.accent : UdhaTheme.fill, in: Circle())
                }
                .buttonStyle(PressDim())
                .disabled(!canSend || isPending)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        // With a keyboard attached there is no reason to make someone aim at a
        // text field first — sit down, type, and it goes to the pane. Held off
        // while a sheet or dialog is up so the composer does not take the keys
        // away from whatever is on top of it.
        .hardwareKeyboardAutofocus(
            $composerFocused,
            enabled: !showingDiff && !renaming && !confirmingTerminate && !confirmingRemove,
            resetOn: sessionID
        )
    }

    private func key(_ label: String, latched: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(UdhaFont.mono(12.5, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .foregroundStyle(latched ? UdhaTheme.onAccent : UdhaTheme.label)
                .background(latched ? UdhaTheme.accent : UdhaTheme.fill,
                            in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(PressDim())
    }

    private func send(_ keys: [String]) {
        guard ctrlLatched, let first = keys.first else {
            bridge.sendKeys(to: sessionID, keys: keys)
            return
        }
        ctrlLatched = false
        let chord = first.count == 1 ? "C-\(first.lowercased())" : first
        bridge.sendKeys(to: sessionID, keys: [chord] + keys.dropFirst())
    }

    /// An image alone is a perfectly good message — "look at this" with a
    /// screenshot is how half of them start — so text is not required, but a
    /// path the host has not finished writing is never sent.
    private var canSend: Bool {
        guard !bridge.isStagingAttachment(for: sessionID) else { return false }
        return !draft.isEmpty || stagedPaths.isEmpty == false
    }

    private var stagedPaths: [String] {
        bridge.attachments(for: sessionID).compactMap(\.path)
    }

    private var composerPrompt: String {
        stagedPaths.isEmpty ? "Reply to \(row?.label ?? "the pane")…" : "say what to do with it…"
    }

    private func submit() {
        // Paths first, then whatever was typed: Claude reads a bare absolute
        // path, and it has to be in the same message as the question about it.
        let text = (stagedPaths + [draft])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return }
        bridge.sendInput(to: sessionID, text: text)
        bridge.clearAttachments(for: sessionID)
        draft = ""
    }
}

extension SessionRow {
    /// The uppercase kicker above the blocked line.
    var blockedKind: String {
        if state == .errored || state == .crashed { return "This session errored" }
        switch phase {
        case .awaitingApproval: return "Permission"
        case .awaitingReply:    return "Question"
        default:                return "Waiting on you"
        }
    }
}


// MARK: - Destruction copy

/// One place for the two destructive explanations, because the list and the
/// detail pane both ask and they must not describe the same action differently.
///
/// The split mirrors the Mac exactly: Terminate is `terminateSession` (process
/// dies, config entry survives), Remove is `removeSession` (process dies, the
/// Terminal window closes, the entry is deleted).
enum SessionDestruction {
    static let terminateExplanation =
        "The tmux session is killed immediately. The label survives on your Mac, so you can respawn it."

    static let removeExplanation =
        "Kills the session, closes its Terminal window, and deletes it from your Mac's session list. "
        + "A git worktree, if this session has one, is left on disk."
}
