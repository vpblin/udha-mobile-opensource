import SwiftUI

/// Watching — and asking about — a meeting the Mac is recording right now.
///
/// The bridge has always accumulated `meeting_live` segments, but nothing ever
/// rendered them: tapping the live row opened the ordinary detail pane, which
/// reads the *stored* transcript and therefore showed "No transcript" for the
/// entire call. This is the missing screen.
struct HostLiveMeetingView: View {
    let bridge: UdhaBridge
    let meeting: Meeting
    var onBack: (() -> Void)? = nil

    enum Tab: Hashable { case transcript, ask }
    @State private var tab: Tab = .transcript
    @State private var askDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Meetings",
                onBack: onBack,
                title: meeting.title,
                subtitle: sourceLine,
                showsSeparator: false
            ) {
                Pill(elapsedLabel, tint: UdhaTheme.badInk, showsDot: true)
            }

            UdhaCard(ring: UdhaTheme.bad) {
                HStack(spacing: 12) {
                    RecordingDot(size: 9)
                    Text(elapsedLabel)
                        .font(UdhaFont.bold(26))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.label)
                    Text(sourceLine)
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { bridge.stopHostRecording() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                            Text("Stop").font(UdhaFont.semibold(15)).fixedSize()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .foregroundStyle(.white)
                        .background(UdhaTheme.bad,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                         style: .continuous))
                    }
                    .buttonStyle(PressDim())
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            SegmentedTabs(
                items: [(Tab.transcript, "Transcript", nil), (Tab.ask, "Ask", nil)],
                selection: $tab
            )
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
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

            if tab == .ask { composer }
        }
        .background(UdhaTheme.canvas)
        .task(id: meeting.id) { bridge.beginAsk(for: meeting.id) }
    }

    private var sourceLine: String {
        "\(meeting.origin.audioLabel) · on \(bridge.activeInstance?.displayName ?? "your Mac")"
    }

    private var elapsedLabel: String {
        String(format: "%02d:%02d", bridge.liveElapsedSec / 60, bridge.liveElapsedSec % 60)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var transcriptTab: some View {
        if bridge.liveTranscript.isEmpty {
            EmptyHint(systemImage: "waveform",
                      title: "Listening",
                      subtitle: "The Mac is recording. Transcript lines appear here as they are recognised.")
        } else {
            UdhaCard(insets: EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)) {
                ForEach(Array(bridge.liveTranscript.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 { CardDivider(inset: 14) }
                    TranscriptLine(segment: segment)
                }
            }
        }
    }

    @ViewBuilder
    private var askTab: some View {
        if bridge.askThread.isEmpty {
            UdhaCard {
                Text("Ask what you missed or what was just decided. Answered on the Mac from the live transcript — nobody on the call can tell.")
                    .font(UdhaFont.regular(14.5))
                    .lineSpacing(3)
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        suggestionChips

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

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhoneMeetingPrompts.suggestions, id: \.self) { suggestion in
                    let isLead = suggestion == PhoneMeetingPrompts.suggestions.first
                    Button {
                        bridge.askAboutMeeting(id: meeting.id,
                                               question: PhoneMeetingPrompts.question(for: suggestion))
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
                TextField("Ask about this call…", text: $askDraft)
                    .textFieldStyle(.plain)
                    .font(UdhaFont.regular(16))
                    .foregroundStyle(UdhaTheme.label)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(UdhaTheme.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(UdhaTheme.separator, lineWidth: 0.5) }
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
        let question = askDraft
        askDraft = ""
        bridge.askAboutMeeting(id: meeting.id, question: question)
    }
}
