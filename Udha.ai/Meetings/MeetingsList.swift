import SwiftUI

/// The meetings master list, with the live recording pinned to the top.
struct MeetingsList: View {
    let bridge: UdhaBridge
    @Bindable var recorder: LocalMeetingRecorder
    var notes: MeetingNotesEngine
    var selection: String?
    var compact: Bool = true
    var onMenu: (() -> Void)?
    var onSettings: () -> Void = {}
    var onSelect: (String) -> Void
    var onOpenLive: () -> Void

    @State private var starting = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 14) {
                    if recorder.state.isActive {
                        liveCard(elapsed: recorder.elapsedLabel,
                                 subtitle: "Mic only · this \(deviceWord)",
                                 action: onOpenLive)
                    } else if let hostLive = bridge.liveMeeting {
                        liveCard(elapsed: elapsedLabel(bridge.liveElapsedSec),
                                 subtitle: "\(hostLive.origin.audioLabel) · on \(bridge.activeInstance?.displayName ?? "host")",
                                 action: { onSelect(hostLive.id) })
                    } else {
                        recordCTA
                    }

                    if case .denied(let why) = recorder.state { notice(why) }
                    if case .failed(let why) = recorder.state { notice(why) }
                    if !bridge.status.isReady && bridge.meetingStore.pendingUploads.count > 0 {
                        notice("\(bridge.meetingStore.pendingUploads.count) recording(s) waiting for your Mac. They are saved on this device.")
                    }

                    if !finished.isEmpty {
                        MasterList(items: finished, compact: compact) { meeting in
                            Button { onSelect(meeting.id) } label: { meetingRow(meeting) }
                                .buttonStyle(.plain)
                        }
                    } else if !recorder.state.isActive {
                        EmptyHint(systemImage: "video",
                                  title: "No meetings yet",
                                  subtitle: "Record one here, or start a call on your Mac.")
                    }
                }
                .padding(.horizontal, compact ? 16 : 12)
                .padding(.bottom, 20)
            }
            .refreshable { bridge.refresh() }
        }
        .background(compact ? AnyShapeStyle(UdhaTheme.canvas) : AnyShapeStyle(Color.clear))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if compact {
            LargeTitleHeader(title: "Meetings", subtitle: subtitle) {
                CircleButton(systemImage: "gearshape", action: onSettings)
                    .accessibilityLabel("Meeting settings")
                CircleButton(systemImage: "record.circle", prominent: true, action: startRecording)
                    .accessibilityLabel("Record a meeting")
            }
        } else {
            PadListHeader(title: "Meetings", onMenu: onMenu) {
                CircleButton(systemImage: "gearshape", diameter: 40, action: onSettings)
                    .accessibilityLabel("Meeting settings")
                CircleButton(systemImage: "record.circle", diameter: 40,
                             prominent: true, action: startRecording)
                    .accessibilityLabel("Record a meeting")
            }
        }
    }

    private var subtitle: String {
        if recorder.state.isActive { return "Recording · \(recorder.elapsedLabel)" }
        if bridge.liveMeeting != nil { return "Recording on your Mac" }
        let count = finished.count
        return count == 0 ? "Nothing recorded yet" : "\(count) recording\(count == 1 ? "" : "s")"
    }

    private var finished: [Meeting] {
        bridge.meetings
            .filter { !$0.isRecording }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func elapsedLabel(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func startRecording() {
        starting = true
        Task {
            await recorder.start()
            starting = false
            if recorder.state.isActive { onOpenLive() }
        }
    }

    // MARK: - Cards

    /// Something is recording right now. Ringed rather than merely coloured,
    /// because this is the one card on the screen you might need to get back to
    /// in a hurry.
    private func liveCard(elapsed: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            UdhaCard(ring: UdhaTheme.bad) {
                HStack(spacing: 8) {
                    RecordingDot()
                    Text("Recording now").kicker(UdhaTheme.badInk)
                    Spacer(minLength: 8)
                    Text(elapsed)
                        .font(UdhaFont.semibold(15))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.badInk)
                }
                Text(subtitle)
                    .font(UdhaFont.regular(14))
                    .foregroundStyle(UdhaTheme.secondary)
                    .padding(.top, 6)
                HStack(spacing: 6) {
                    Text("Open")
                        .font(UdhaFont.semibold(15))
                        .foregroundStyle(UdhaTheme.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(UdhaTheme.accent)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
            }
        }
        .buttonStyle(PressDim())
    }

    /// Recording is the primary action on this tab, so it sits at the top of
    /// the list rather than hiding behind a toolbar button.
    private var recordCTA: some View {
        Button(action: startRecording) {
            UdhaCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(UdhaTheme.badTint).frame(width: 40, height: 40)
                        if starting {
                            ProgressView().tint(UdhaTheme.bad)
                        } else {
                            Circle().fill(UdhaTheme.bad).frame(width: 14, height: 14)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record a meeting")
                            .font(UdhaFont.semibold(16))
                            .foregroundStyle(UdhaTheme.label)
                        Text(recorder.state.preparingMessage ?? "Mic only · transcribed on this device")
                            .font(UdhaFont.regular(13))
                            .foregroundStyle(UdhaTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UdhaTheme.tertiary.opacity(0.55))
                }
            }
        }
        .buttonStyle(PressDim())
    }

    // MARK: - Rows

    private func meetingRow(_ meeting: Meeting) -> some View {
        let style = MasterSelection(compact: compact, selected: meeting.id == selection)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(UdhaFont.rowTitle)
                    .foregroundStyle(style.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(meeting.listMeta)
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                    if let tag = tag(for: meeting), !style.selected || compact {
                        Pill(tag.0, tint: tag.1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.chevron)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .background(style.background)
        .contentShape(Rectangle())
    }

    /// The one thing about this recording that is not already in its meta line.
    ///
    /// `listMeta` already ends in "needs summary" for an unfinalised one, and a
    /// pill saying the same thing two inches to the right is the kind of detail
    /// that makes a list look automated rather than written.
    private func tag(for meeting: Meeting) -> (String, Color)? {
        let meta = meeting.listMeta.lowercased()
        func unlessInMeta(_ text: String, _ tint: Color) -> (String, Color)? {
            meta.contains(text.lowercased()) ? nil : (text, tint)
        }
        if notes.isWorking(on: meeting.id) { return ("Summarising", UdhaTheme.accentInk) }
        if meeting.provisionalSummary { return unlessInMeta("Phone summary", UdhaTheme.warnInk) }
        if !meeting.finalized { return unlessInMeta("Needs summary", UdhaTheme.warnInk) }
        if meeting.origin == .local { return unlessInMeta("On device", UdhaTheme.secondary) }
        return nil
    }

    private func notice(_ text: String) -> some View {
        UdhaCard(ring: UdhaTheme.warn) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UdhaTheme.warn)
                Text(text)
                    .font(UdhaFont.regular(14))
                    .lineSpacing(2)
                    .foregroundStyle(UdhaTheme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}
