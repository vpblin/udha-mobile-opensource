import SwiftUI

/// The in-call screen: elapsed clock, live transcript, jotted notes, and a
/// question box for asking about what was just said.
struct LiveMeetingView: View {
    let bridge: UdhaBridge
    @Bindable var recorder: LocalMeetingRecorder
    var onBack: (() -> Void)? = nil

    enum Tab: Hashable { case notes, transcript, ask }
    @State private var tab: Tab = .notes
    @State private var noteDraft = ""
    @State private var askDraft = ""
    @State private var stopping = false
    @FocusState private var focus: Tab?

    private let ask = MeetingAskEngine()
    /// Owned here rather than by the recorder: summarising is what happens
    /// *after* the recorder is done, and it must outlive the live screen.
    var notes: MeetingNotesEngine

    init(bridge: UdhaBridge,
         recorder: LocalMeetingRecorder,
         notes: MeetingNotesEngine,
         onBack: (() -> Void)? = nil) {
        self.bridge = bridge
        _recorder = Bindable(wrappedValue: recorder)
        self.notes = notes
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Meetings",
                onBack: onBack,
                title: "Recording",
                subtitle: recorder.interrupted
                    ? "Paused" : (recorder.state.preparingMessage ?? "Mic only"),
                showsSeparator: false
            ) {
                Pill(recorder.elapsedLabel, tint: UdhaTheme.badInk, showsDot: true)
            }

            recordingCard
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            SegmentedTabs(
                items: [(Tab.notes, "Notes", recorder.notes.isEmpty ? nil : recorder.notes.count),
                        (Tab.transcript, "Transcript", nil),
                        (Tab.ask, "Ask", nil)],
                selection: $tab
            )
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .notes:      notesTab
                    case .transcript: transcriptTab
                    case .ask:        askTab
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            composer
        }
        .background(UdhaTheme.canvas)
    }

    // MARK: - Recording card

    /// The clock, the level meter and Stop, in one ringed card. The meter is the
    /// point: discovering a silent recording afterwards is the worst possible
    /// outcome for this feature, and a live bar graph is the only thing that
    /// proves the mic is actually hearing something.
    private var recordingCard: some View {
        UdhaCard(ring: UdhaTheme.bad) {
            HStack(spacing: 12) {
                RecordingDot(size: 9)
                Text(recorder.elapsedLabel)
                    .font(UdhaFont.bold(26))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.label)
                    .fixedSize()
                meter
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { stop() } label: {
                    HStack(spacing: 7) {
                        if stopping {
                            ProgressView().controlSize(.mini).tint(UdhaTheme.onAccent)
                        } else {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                        }
                        Text(stopping ? "Saving" : "Stop").font(UdhaFont.semibold(15)).fixedSize()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .foregroundStyle(.white)
                    .background(UdhaTheme.bad,
                                in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                     style: .continuous))
                }
                .buttonStyle(PressDim())
                .disabled(stopping)
                .layoutPriority(1)
            }
        }
    }

    private var meter: some View {
        let values = Array(recorder.levels.suffix(24))
        return HStack(alignment: .center, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(UdhaTheme.bad)
                    .frame(width: 2.5, height: max(3, CGFloat(level) * 26))
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    private func stop() {
        stopping = true
        Task {
            // Awaits the analyzer's tail and the disk write, so by the time
            // this returns the meeting exists whatever happens next.
            let meeting = await recorder.stop()
            stopping = false
            guard let meeting else { return }
            // Queue it for the Mac's notes pass, and — when the Mac is not
            // there — summarise it here so the user is not left holding a
            // transcript and nothing else.
            bridge.uploadLocalMeeting(meeting)
            await notes.summarizeIfNeeded(meeting, bridge: bridge)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var notesTab: some View {
        if recorder.notes.isEmpty {
            UdhaCard {
                Text("Notes you type here are kept with the transcript and sent along for the summary.")
                    .font(UdhaFont.regular(14.5))
                    .lineSpacing(2)
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            UdhaCard {
                ForEach(Array(recorder.notes.enumerated()), id: \.offset) { _, note in
                    DashItem {
                        Text(note)
                            .font(UdhaFont.regular(15))
                            .lineSpacing(3)
                            .foregroundStyle(UdhaTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !recorder.segments.isEmpty {
                UdhaCard(insets: EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                    ForEach(Array(recorder.segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 { CardDivider(inset: 14) }
                        TranscriptLine(segment: segment)
                    }
                }
            }
            HStack(spacing: 9) {
                LiveDot(color: UdhaTheme.bad, animated: !recorder.partial.isEmpty, size: 8)
                Text(recorder.partial.isEmpty ? "Listening" : recorder.partial)
                    .font(UdhaFont.regular(recorder.partial.isEmpty ? 13 : 15))
                    .lineSpacing(3)
                    .foregroundStyle(recorder.partial.isEmpty ? UdhaTheme.tertiary : UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var askTab: some View {
        if bridge.askThread.isEmpty {
            UdhaCard {
                Text("Ask what you missed, what was decided, or whether anyone committed to anything. Answered on this device from the live transcript — nobody else on the call can tell.")
                    .font(UdhaFont.regular(14.5))
                    .lineSpacing(3)
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        suggestionChips

        if !MeetingNotesEngine.hasKey {
            UdhaCard(ring: UdhaTheme.warn) {
                Text("Add an Anthropic API key in Settings to ask about this call.")
                    .font(UdhaFont.regular(14))
                    .foregroundStyle(UdhaTheme.warnInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        ForEach(bridge.askThread) { turn in
            Bubble(text: turn.text,
                   kind: turn.role == .you ? .you : .them,
                   stamp: turn.role == .you ? "You" : "Udha")
        }

        if bridge.askPending {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(UdhaTheme.accent)
                Text("Thinking").font(UdhaFont.regular(13)).foregroundStyle(UdhaTheme.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// The one-tap questions. "Make me sound smart" leads because it is the
    /// thing people actually want mid-call and would never think to type.
    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhoneMeetingPrompts.suggestions, id: \.self) { suggestion in
                    let isLead = suggestion == PhoneMeetingPrompts.suggestions.first
                    Button {
                        tab = .ask
                        submitAsk(PhoneMeetingPrompts.question(for: suggestion))
                    } label: {
                        Text(suggestion)
                            .font(UdhaFont.medium(14))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .foregroundStyle(isLead ? UdhaTheme.onAccent : UdhaTheme.label)
                            .background(isLead ? UdhaTheme.accent : UdhaTheme.fill, in: Capsule())
                    }
                    .buttonStyle(PressDim())
                    .disabled(bridge.askPending)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    // MARK: - Composer

    private var composer: some View {
        ChromeBar {
            HStack(spacing: 9) {
                TextField(tab == .notes ? "Jot a note…" : "Ask about this call…",
                          text: tab == .notes ? $noteDraft : $askDraft)
                    .textFieldStyle(.plain)
                    .font(UdhaFont.regular(16))
                    .foregroundStyle(UdhaTheme.label)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(UdhaTheme.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(UdhaTheme.separator, lineWidth: 0.5) }
                    .focused($focus, equals: tab == .notes ? .notes : .ask)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(UdhaTheme.onAccent)
                        .background(UdhaTheme.accent, in: Circle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private func submit() {
        if tab == .notes {
            recorder.addNote(noteDraft)
            noteDraft = ""
        } else {
            tab = .ask
            let question = askDraft
            askDraft = ""
            submitAsk(question)
        }
    }

    /// Answered here, not on the Mac. The host only learns about a phone
    /// recording when it ends, so routing this over the bridge meant asking
    /// about a meeting id it had never seen — the pane just spun.
    private func submitAsk(_ question: String) {
        Task {
            await ask.ask(
                question: question,
                meetingID: recorder.meetingID,
                transcript: recorder.liveTranscriptText,
                notes: recorder.notes,
                bridge: bridge
            )
        }
    }
}
