import Foundation
import ActivityKit

/// The contract between the app and its Live Activity.
///
/// Lives in `Shared/` and is compiled into both targets: an `ActivityAttributes`
/// type has to be the same shape on both sides or the widget cannot decode what
/// the app sends.
struct MeetingActivityAttributes: ActivityAttributes {

    /// Everything that changes while the meeting runs.
    struct ContentState: Codable, Hashable {
        /// The instant the elapsed clock would have started had it never
        /// paused. Passing this rather than a running count lets the Lock
        /// Screen tick on its own — pushing an update twice a second to move a
        /// timer would drain the battery and hit ActivityKit's update budget.
        var timerOrigin: Date
        /// Frozen elapsed seconds while interrupted, since a paused timer
        /// cannot be expressed as an origin.
        var pausedElapsed: TimeInterval?
        /// The last thing transcribed, so a glance tells you it is hearing you.
        var lastLine: String

        var isPaused: Bool { pausedElapsed != nil }
    }

    /// Fixed for the life of the activity.
    var title: String
}
