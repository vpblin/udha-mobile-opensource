import ActivityKit
import WidgetKit
import SwiftUI

/// The Lock Screen and Dynamic Island presence of a meeting being recorded.
///
/// A recorder that keeps running while the phone is in a pocket has to be
/// visibly still running, or the only way to know it survived being
/// backgrounded is to open the app and hope. This is the proof — and the way
/// back in, since tapping it deep-links to the live screen.
struct MeetingLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Palette.ink)
                .activitySystemActionForegroundColor(Palette.paper)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        dot(context.state)
                        Text(context.state.isPaused ? "Paused" : "Recording")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.paper)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.paper)
                            .lineLimit(1)
                        if !context.state.lastLine.isEmpty {
                            Text(context.state.lastLine)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.paper.opacity(0.65))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            } compactLeading: {
                dot(context.state)
            } compactTrailing: {
                clock(context.state)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            } minimal: {
                dot(context.state)
            }
            .widgetURL(URL(string: "udha://live"))
            .keylineTint(Palette.red)
        }
    }

    // MARK: - Lock Screen

    private func lockScreen(_ context: ActivityViewContext<MeetingActivityAttributes>) -> some View {
        HStack(spacing: 14) {
            dot(context.state)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.paper)
                    .lineLimit(1)
                Text(context.state.isPaused
                     ? "Paused — recording resumes automatically"
                     : (context.state.lastLine.isEmpty ? "Listening" : context.state.lastLine))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.paper.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            clock(context.state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Pieces

    /// A square, not a circle — it is the same record mark the app uses.
    private func dot(_ state: MeetingActivityAttributes.ContentState) -> some View {
        Rectangle()
            .fill(state.isPaused ? Palette.paper.opacity(0.4) : Palette.red)
            .frame(width: 11, height: 11)
    }

    @ViewBuilder
    private func clock(_ state: MeetingActivityAttributes.ContentState) -> some View {
        if let paused = state.pausedElapsed {
            Text(Self.stamp(paused))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.paper.opacity(0.55))
        } else {
            // Counts up on the device's own clock; the app does not push a
            // frame per second to keep it moving.
            Text(state.timerOrigin, style: .timer)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.paper)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The app's palette, restated here because the extension does not compile
    /// the design system — keep these in step with `UdhaTheme`.
    ///
    /// Fixed rather than trait-resolved on purpose: a Live Activity is drawn on
    /// the Lock Screen and in the Dynamic Island, both of which are dark
    /// whatever the phone's appearance is set to.
    private enum Palette {
        /// UdhaTheme.canvas, dark — 0x1B1B1D
        static let ink = Color(red: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255)
        /// UdhaTheme.label, dark — 0xF5F5F7
        static let paper = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
        /// UdhaTheme.bad, dark — 0xFF6961
        static let red = Color(red: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255)
    }
}
