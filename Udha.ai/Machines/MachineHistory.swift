import Foundation
import Observation

/// The recent past of a machine's vitals, so the Machines screen can draw a
/// line instead of a single number.
///
/// `MachineStats` is one instant — the host reads and forgets. A shape is what
/// tells you whether 68% memory is a plateau or a climb, so every reading that
/// arrives is appended here.
///
/// Two honest limits, both deliberate. The phone only asks for vitals while the
/// Machines screen is open, so a chart covers *the time you have been watching*
/// rather than a rolling hour; `span` reports that measured window instead of a
/// label like "60 m" that would be a lie for the first fifty-nine of them. And
/// nothing is persisted — relaunching starts the charts empty rather than
/// drawing a gap as though it were flat.
@MainActor
@Observable
final class MachineHistory {

    /// What is tracked per machine. Temperatures are keyed separately, by sensor
    /// label, because which sensors exist differs per box.
    enum Track: String, CaseIterable {
        case cpu, memory, disk, gpu, rtt, sessions
    }

    /// An hour at 5s is 720 points — more than any sparkline this size can
    /// resolve, and the oldest is already older than the window the screen
    /// claims to cover.
    private let capacity = 720

    private struct Log {
        var values: [Double] = []
        var stamps: [Date] = []

        mutating func append(_ value: Double, at when: Date, capacity: Int) {
            values.append(value)
            stamps.append(when)
            if values.count > capacity {
                values.removeFirst(values.count - capacity)
                stamps.removeFirst(stamps.count - capacity)
            }
        }
    }

    private var tracks: [String: [Track: Log]] = [:]
    private var temps: [String: [String: Log]] = [:]
    /// The `sampledAt` of the last reading stored per machine. The phone polls
    /// rather than being pushed, so the same payload can arrive twice — counting
    /// it twice would stretch the span with time nothing was measured in.
    private var lastSampleAt: [String: Date] = [:]

    // MARK: - Recording

    func record(_ stats: MachineStats?, for id: String?) {
        guard let stats, let id, !id.isEmpty else { return }
        if let seen = lastSampleAt[id], seen == stats.sampledAt { return }
        lastSampleAt[id] = stats.sampledAt
        let at = stats.sampledAt

        var machine = tracks[id] ?? [:]
        func put(_ track: Track, _ value: Double?) {
            guard let value else { return }
            var log = machine[track] ?? Log()
            log.append(value, at: at, capacity: capacity)
            machine[track] = log
        }
        put(.cpu, stats.cpuPercent)
        put(.memory, stats.memoryPercent)
        put(.disk, stats.diskPercent)
        put(.gpu, stats.gpu?.utilPercent)
        put(.rtt, stats.relay?.rttMilliseconds)
        put(.sessions, Double(stats.sessionCount))
        tracks[id] = machine

        var sensors = temps[id] ?? [:]
        for reading in stats.temperatures {
            var log = sensors[reading.label] ?? Log()
            log.append(reading.celsius, at: at, capacity: capacity)
            sensors[reading.label] = log
        }
        temps[id] = sensors
    }

    /// Drop everything for a machine — used when a box leaves the relay, so a
    /// line never spans a gap it did not measure.
    func forget(id: String) {
        tracks[id] = nil
        temps[id] = nil
        lastSampleAt[id] = nil
    }

    // MARK: - Reading

    func series(_ id: String?, _ track: Track) -> [Double] {
        guard let id else { return [] }
        return tracks[id]?[track]?.values ?? []
    }

    func temperature(_ id: String?, label: String) -> [Double] {
        guard let id else { return [] }
        return temps[id]?[label]?.values ?? []
    }

    /// How much time the samples actually cover: "19s", "12m", "1h 4m", or "—"
    /// when there is not yet a second sample to measure against.
    func span(_ id: String?, _ track: Track = .cpu) -> String {
        guard let id, let log = tracks[id]?[track],
              let first = log.stamps.first, let last = log.stamps.last,
              log.stamps.count > 1 else { return "—" }
        return Self.duration(first, last)
    }

    /// Pure arithmetic over two dates — no state, so it is callable from
    /// anywhere, tests included.
    nonisolated static func duration(_ from: Date, _ to: Date) -> String {
        let seconds = Int(max(to.timeIntervalSince(from), 0))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    /// Errors bucketed into the last 24 hours, one point per hour, oldest first.
    /// Read straight from the payload's own timestamps, so unlike the resource
    /// series this one is real history from the very first sample.
    nonisolated static func dropsPerHour(_ errors: [MachineStats.ConnectionError],
                                         now: Date = Date()) -> [Double] {
        var buckets = [Double](repeating: 0, count: 24)
        for error in errors {
            let hoursAgo = now.timeIntervalSince(error.at) / 3600
            guard hoursAgo >= 0, hoursAgo < 24 else { continue }
            let index = 23 - Int(hoursAgo)
            buckets[max(0, min(23, index))] += 1
        }
        return buckets
    }
}
