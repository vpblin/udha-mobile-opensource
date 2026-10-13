import Foundation
import ActivityKit
import os

/// Drives the recording Live Activity.
///
/// Kept apart from `LocalMeetingRecorder` so that every failure here is
/// cosmetic: ActivityKit can be disabled by the user, budget-limited by the
/// system, or unavailable on the device, and none of that is a reason for a
/// recording to stop. Every call is best-effort and silent on failure.
@MainActor
final class MeetingActivityController {

    private var activity: Activity<MeetingActivityAttributes>?
    /// Throttles updates: the clock runs on the widget's own timer, so pushes
    /// are only for the transcript line, and ActivityKit budgets them.
    private var lastPush: Date = .distantPast
    private let minimumInterval: TimeInterval = 8

    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "liveactivity")

    var isRunning: Bool { activity != nil }

    func start(title: String, elapsed: TimeInterval) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("live activities are disabled; recording continues without one")
            return
        }
        let state = MeetingActivityAttributes.ContentState(
            timerOrigin: Date().addingTimeInterval(-elapsed),
            pausedElapsed: nil,
            lastLine: ""
        )
        do {
            activity = try Activity.request(
                attributes: MeetingActivityAttributes(title: title),
                content: .init(state: state, staleDate: nil)
            )
            lastPush = Date()
        } catch {
            log.error("could not start live activity: \(error.localizedDescription)")
        }
    }

    /// `force` bypasses the throttle for changes the user would notice
    /// immediately — pausing and resuming.
    func update(elapsed: TimeInterval, paused: Bool, lastLine: String, force: Bool = false) {
        guard let activity else { return }
        guard force || Date().timeIntervalSince(lastPush) >= minimumInterval else { return }
        lastPush = Date()
        let state = MeetingActivityAttributes.ContentState(
            timerOrigin: Date().addingTimeInterval(-elapsed),
            pausedElapsed: paused ? elapsed : nil,
            lastLine: String(lastLine.suffix(140))
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end(elapsed: TimeInterval) {
        guard let activity else { return }
        self.activity = nil
        let state = MeetingActivityAttributes.ContentState(
            timerOrigin: Date().addingTimeInterval(-elapsed),
            pausedElapsed: elapsed,
            lastLine: ""
        )
        Task {
            // Immediately, not after the default four-hour grace period — a
            // finished meeting lingering on the Lock Screen reads as one that
            // is still recording.
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    /// Clears anything a previous launch left behind — a crash mid-recording
    /// would otherwise leave a Live Activity claiming to record forever.
    func clearStaleActivities() {
        for activity in Activity<MeetingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
