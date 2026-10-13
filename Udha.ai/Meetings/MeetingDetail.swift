import SwiftUI

/// A finished meeting: what has to be done, what was said about it, and the
/// transcript underneath.
///
/// Action items lead. They used to be the last thing on the summary tab, below
/// however many paragraphs the notes pass produced — which is the wrong order
/// for the one part of a meeting that outlives it. Now they are a tab of their
/// own, first, and tickable.
struct MeetingDetail: View {
    let bridge: UdhaBridge
    let meeting: Meeting
    /// Not named `notes`: this view already has a `notes` tab body.
    var notesEngine: MeetingNotesEngine
    var retranscriber: MeetingRetranscriber
    var onBack: (() -> Void)? = nil

    enum Tab: Hashable { case actions, notes, transcript }
    @State private var tab: Tab = .actions

    /// Local buffer while editing. Committed on blur and on a short idle pause
    /// rather than per keystroke, so a slow link never stalls typing.
    @State private var draftNotes: String = ""
    @State private var notesLoadedFor: String?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Meetings",
                onBack: onBack,
                showsSeparator: false
            ) {
                if bridge.liveMeeting != nil {
                    Pill(liveClock, tint: UdhaTheme.badInk, showsDot: true)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meeting.title)
                            .font(UdhaFont.screenTitle)
                            .foregroundStyle(UdhaTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(meeting.detailStamp)
                            .font(UdhaFont.regular(13))
                            .foregroundStyle(UdhaTheme.secondary)
                    }
                    .padding(.horizontal, 4)

                    SegmentedTabs(
                        items: [(Tab.actions, actionsLabel, openActions),
                                (Tab.notes, "Notes", nil),
                                (Tab.transcript, "Transcript", nil)],
                        selection: $tab
                    )

                    switch tab {
                    case .actions:    actions
                    case .notes:      notes
                    case .transcript: transcript
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .background(UdhaTheme.canvas)
        .task(id: meeting.id) { loadDraft() }
        .onDisappear { commit() }
    }

    private var liveClock: String {
        String(format: "%02d:%02d", bridge.liveElapsedSec / 60, bridge.liveElapsedSec % 60)
    }

    private var actionsLabel: String { "Actions" }

    private var openActions: Int? {
        let open = (meeting.actionItems ?? []).filter { !$0.done }.count
        return open > 0 ? open : nil
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let items = meeting.actionItems ?? []
        if items.isEmpty {
            UdhaCard {
                Text(meeting.hasNotesContent
                     ? "The notes pass found nothing anyone committed to."
                     : "Not summarised yet — action items arrive with the summary.")
                    .font(UdhaFont.regular(14.5))
                    .lineSpacing(2)
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !meeting.hasNotesContent { needsSummary.padding(.top, 4) }
        } else {
            InsetGroup(items: items, separatorInset: 47) { item in
                Button {
                    bridge.toggleActionItem(meetingID: meeting.id, itemID: item.id)
                } label: {
                    actionRow(item)
                }
                .buttonStyle(PressDim())
            }
        }
    }

    private func actionRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            CheckCircle(done: item.done).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text)
                    .font(UdhaFont.regular(14.5))
                    .lineSpacing(3)
                    .foregroundStyle(item.done ? UdhaTheme.tertiary : UdhaTheme.label)
                    .strikethrough(item.done, color: UdhaTheme.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = item.owner {
                    Pill(owner, tint: owner.lowercased() == "me"
                         ? UdhaTheme.accentInk : UdhaTheme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    // MARK: - Notes

    @ViewBuilder
    private var notes: some View {
        if !meeting.hasNotesContent {
            if meeting.origin == .local && !meeting.finalized {
                needsSummary
            } else if meeting.hasDetail {
                // Fetched, and there genuinely is nothing — say so rather than
                // spinning on "Loading" forever.
                EmptyHint(systemImage: "text.quote",
                          title: meeting.finalized ? "No notes were generated" : "Not summarised yet",
                          subtitle: meeting.finalized
                              ? "The transcript is still on the Transcript tab."
                              : "Your Mac has not run the notes pass on this recording.")
            } else {
                EmptyHint(systemImage: "ellipsis", title: "Loading notes…")
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if meeting.provisionalSummary { provisionalBadge }

                if let body = meeting.displayNotes, !body.isEmpty {
                    // The finalize pass emits Markdown; rendering it as plain
                    // text turned polished notes into a wall of hashes.
                    UdhaCard { MarkdownText(body) }
                }

                if let decisions = meeting.decisions, !decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "Decisions")
                        UdhaCard {
                            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                                DashItem {
                                    Text(decision)
                                        .font(UdhaFont.regular(14.5))
                                        .lineSpacing(3)
                                        .foregroundStyle(UdhaTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                myNotes
            }
        }
    }

    private var needsSummary: some View {
        UdhaCard(ring: UdhaTheme.warn) {
            Text(notesEngine.isWorking(on: meeting.id) ? "Summarising" : "Needs summary")
                .kicker(UdhaTheme.warnInk)
            Text(needsSummaryExplanation)
                .font(UdhaFont.regular(14.5))
                .lineSpacing(3)
                .foregroundStyle(UdhaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Group {
                if notesEngine.isWorking(on: meeting.id) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(UdhaTheme.accent)
                        Text("Running the notes pass on this device")
                            .font(UdhaFont.regular(13))
                            .foregroundStyle(UdhaTheme.tertiary)
                    }
                } else if bridge.status.isReady {
                    PrimaryButton(title: "Summarise on the Mac", systemImage: "sparkles") {
                        // Only ever reached for a meeting this device recorded —
                        // pushing a host meeting back at the host would file it
                        // as a phone recording.
                        guard meeting.origin == .local else { return }
                        bridge.uploadLocalMeeting(meeting)
                    }
                } else if MeetingNotesEngine.hasKey {
                    PrimaryButton(title: "Summarise on this phone", systemImage: "sparkles") {
                        Task { await notesEngine.summarize(meeting, bridge: bridge) }
                    }
                }
            }
            .padding(.top, 12)

            if let error = notesEngine.lastError {
                Text(error)
                    .font(UdhaFont.regular(13))
                    .foregroundStyle(UdhaTheme.badInk)
                    .padding(.top, 8)
            }
        }
    }

    private var needsSummaryExplanation: String {
        if bridge.status.isReady {
            return "This recording has not been summarised yet. Send it to the Mac to run the full notes pass."
        }
        if MeetingNotesEngine.hasKey {
            return "The Mac is not reachable, so this has not been summarised there yet. It is queued and will go up automatically — or summarise it here now."
        }
        return "The Mac is not reachable. The recording is saved on this device and will be summarised as soon as your Mac is back. Add an API key in Settings to summarise it here instead."
    }

    /// Says plainly that these notes came from the phone's smaller pass, so a
    /// later, different-looking version from the Mac is not a surprise.
    private var provisionalBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .semibold))
            Text("Summarised on this device — your Mac will redo it properly when it syncs.")
                .font(UdhaFont.regular(12.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(UdhaTheme.warnInk)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(UdhaTheme.warnTint,
                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
    }

    // MARK: - My notes

    private var myNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your notes").sectionLabel()
                Spacer(minLength: 0)
                if editing {
                    Button("Done") { commit(); editing = false }
                        .font(UdhaFont.semibold(14))
                        .foregroundStyle(UdhaTheme.accent)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            UdhaCard(insets: EdgeInsets(top: 6, leading: 9, bottom: 10, trailing: 9)) {
                TextEditor(text: $draftNotes)
                    .font(UdhaFont.regular(15))
                    .foregroundStyle(UdhaTheme.label)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if draftNotes.isEmpty && !editing {
                            Text("Anything the summary missed — decisions, follow-ups, who owes what.")
                                .font(UdhaFont.regular(15))
                                .foregroundStyle(UdhaTheme.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: draftNotes) { _, _ in scheduleSave() }

                Text("Saved to the meeting on your Mac, and kept separate from the generated summary.")
                    .font(UdhaFont.regular(12))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.top, 6)
            }
        }
    }

    private func loadDraft() {
        guard notesLoadedFor != meeting.id else { return }
        notesLoadedFor = meeting.id
        draftNotes = meeting.userNotes ?? ""
    }

    /// Debounced autosave — a keystroke should not be a network round trip.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        saveTask?.cancel()
        saveTask = nil
        guard notesLoadedFor == meeting.id, draftNotes != (meeting.userNotes ?? "") else { return }
        bridge.saveMeetingNotes(id: meeting.id, notes: draftNotes)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        let segments = meeting.transcript ?? []
        VStack(alignment: .leading, spacing: 12) {
            if segments.isEmpty {
                EmptyHint(systemImage: "text.quote", title: "No transcript")
                retranscribeControl
            } else {
                UdhaCard(insets: EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 { CardDivider(inset: 14) }
                        TranscriptLine(segment: segment)
                    }
                }
                // Also offered on a transcript that exists: live recognition on
                // a bad connection or a noisy room can produce something poor
                // enough to be worth redoing from the audio.
                if retranscriber.canRetranscribe(meeting) {
                    retranscribeControl
                }
            }
        }
    }
}

extension MeetingDetail {
    /// The payoff for always writing the audio file: a failed transcription is
    /// a retry, not a lost meeting.
    @ViewBuilder
    fileprivate var retranscribeControl: some View {
        if retranscriber.isWorking(on: meeting.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(UdhaTheme.accent)
                Text(retranscriber.progress ?? "transcribing")
                    .font(UdhaFont.regular(13))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            .padding(.horizontal, 4)
        } else if retranscriber.canRetranscribe(meeting) {
            UdhaCard {
                SecondaryButton(title: "Re-transcribe from audio", systemImage: "waveform") {
                    Task { await retranscriber.retranscribe(meeting, bridge: bridge) }
                }
                Text("The recording itself was saved. Running speech recognition over it again replaces the transcript and re-runs the notes.")
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                if let error = retranscriber.lastError {
                    Text(error)
                        .font(UdhaFont.regular(12.5))
                        .foregroundStyle(UdhaTheme.badInk)
                        .padding(.top, 6)
                }
            }
        }
    }
}

/// One transcript turn. The speaker column is fixed-width so the text edge stays
/// aligned down a long transcript.
struct TranscriptLine: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.speaker)
                    .font(UdhaFont.semibold(12.5))
                    .foregroundStyle(segment.isMe ? UdhaTheme.accentInk : UdhaTheme.label)
                    .lineLimit(1)
                Text(segment.stamp)
                    .font(UdhaFont.mono(10.5))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            .frame(width: 64, alignment: .leading)
            .padding(.top, 1)

            Text(segment.text)
                .font(UdhaFont.regular(14.5))
                .lineSpacing(3)
                .foregroundStyle(UdhaTheme.label)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
