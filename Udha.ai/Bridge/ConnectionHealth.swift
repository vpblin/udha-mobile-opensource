import Foundation

/// Liveness and reconnect *policy*, kept apart from the socket that enforces it.
///
/// The rules here decide when a connection is dead, when a ping is worth the
/// radio wake-up, and how long to wait before redialling. They are pure
/// functions over timestamps precisely so the battery-relevant decisions are
/// testable without a relay, a simulator, or a stopwatch — see tests/main.swift.
///
/// The shape of the policy is deliberate. A phone spends most of its life
/// suspended, and every timer that fires while nothing is happening is a radio
/// wake-up the user pays for. So: pings only when the wire has actually gone
/// quiet, backoff that really escalates, and no polling anywhere — staleness is
/// derived from timestamps we already record.
enum ConnectionHealth {

    /// How long the wire may be silent before a keepalive is worth sending.
    /// Traffic of any kind counts, so an active session sends none of these.
    static let pingInterval: TimeInterval = 25

    /// Silence past this and the socket is presumed dead. Two missed pings plus
    /// slack: long enough that a slow relay is not mistaken for a dead one,
    /// short enough that a session found on the couch recovers within a glance.
    static let silenceLimit: TimeInterval = 70

    /// How long a foreground health probe waits for its pong before giving up.
    /// This runs while the user is watching, so it has to be brisk.
    static let probeTimeout: TimeInterval = 3

    /// How long a fresh dial has to answer before it counts as a failed
    /// connection. Longer than the foreground probe on purpose: this one
    /// includes a TLS handshake over whatever cellular the user happens to
    /// have, and killing that early would turn a slow network into no network.
    static let connectTimeout: TimeInterval = 12

    /// How long an `attach_terminal` may go unanswered before the pane is
    /// presumed broken.
    ///
    /// Note what this measures, and what it deliberately does not. Frames are
    /// pushed on change, so a quiet pane is indistinguishable from a dead one —
    /// timing plain silence would flag every session where nobody is typing. An
    /// *attach*, though, is always answered: the host replies with the current
    /// capture. So the client asks a question it knows the answer to, and only
    /// an unanswered question counts as evidence.
    static let attachTimeout: TimeInterval = 30

    /// How many unanswered re-attaches before the watchdog gives up and lets
    /// the user decide. A host that ignored two will ignore a third, and a
    /// phone that retries forever on a locked screen is the battery bug this
    /// whole change exists to avoid.
    static let terminalResyncAttempts = 2

    /// How long a changed terminal grid settles before it is sent.
    ///
    /// A pinch gesture rewrites the grid on every frame, and each resize the
    /// host applies costs a SIGWINCH and a full TUI repaint on the Mac. Long
    /// enough to coalesce a gesture, short enough that letting go of a rotation
    /// feels like it took effect immediately.
    static let resizeSettleDelay: TimeInterval = 0.4

    /// Ceiling on redial backoff.
    static let maxBackoff: TimeInterval = 30

    /// Slack the OS may use to coalesce our timer with other wake-ups. Free
    /// battery: nothing here needs to be punctual to the second.
    static let timerTolerance: TimeInterval = 5

    /// Exponential redial backoff, capped. Attempt 0 is the first retry after a
    /// connection that had proven itself, so it waits the shortest time.
    ///
    /// The point of counting attempts at all is the offline case: a phone in a
    /// tunnel must not dial once a second for the length of the tunnel.
    static func backoffDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(pow(2.0, Double(min(attempt, 16))), maxBackoff)
    }

    /// Whether a keepalive is worth sending right now.
    ///
    /// Any inbound frame proves the wire is alive, so a busy connection never
    /// pings at all — the cost scales with idleness, not with uptime.
    static func shouldPing(lastInboundAt: Date?, now: Date) -> Bool {
        guard let lastInboundAt else { return true }
        return now.timeIntervalSince(lastInboundAt) >= pingInterval
    }

    /// Whether the socket should be declared dead and redialled.
    ///
    /// This is the check the old build lacked: `URLSessionWebSocketTask` reports
    /// nothing when a NAT table forgets us or the radio hands off networks, so
    /// without a silence rule the app sat "connected" to a socket that would
    /// never deliver another byte.
    static func isDead(lastInboundAt: Date?, now: Date) -> Bool {
        guard let lastInboundAt else { return false }
        return now.timeIntervalSince(lastInboundAt) > silenceLimit
    }

    /// Whether an `attach_terminal` has gone unanswered long enough to count as
    /// a broken pane rather than a slow one.
    static func attachIsUnanswered(sentAt: Date?, now: Date) -> Bool {
        guard let sentAt else { return false }
        return now.timeIntervalSince(sentAt) > attachTimeout
    }

    /// "live", "12s", "8m" — how far behind the pane is, for the stale bar.
    static func ageLabel(since: Date?, now: Date) -> String {
        guard let since else { return "—" }
        return SessionRow.compactAge(Int(now.timeIntervalSince(since)))
    }
}
