import Foundation

/// One machine's vital signs, as collected *on that machine* and shipped over
/// the bridge as a `stats` payload.
///
/// The mirror of the desktop's `MachineStats`: same wire keys, same
/// optional-by-omission rule. A collector that cannot see something leaves it
/// out rather than sending a zero, so every field that can be absent is an
/// optional here too — "0 °C" and "no sensor" must not render alike.
///
/// Only the active host's stats ever arrive. The relay subscribes a client to
/// one instance at a time, so this is always "the machine you are looking at",
/// never a fleet-wide reading.
struct MachineStats: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        var label: String
        var celsius: Double
    }

    struct GPU: Equatable, Sendable {
        var name: String = ""
        var utilPercent: Double?
        var memUsedMB: Double?
        var memTotalMB: Double?
        var celsius: Double?
        var watts: Double?
        var fanPercent: Double?
    }

    struct Docker: Equatable, Sendable {
        var running: Int = 0
        var note: String = ""
    }

    struct Net: Equatable, Sendable {
        var interface: String = ""
        var rxBytesPerSec: Double?
        var txBytesPerSec: Double?
    }

    struct Proc: Equatable, Sendable {
        var name: String
        var cpuPercent: Double
    }

    struct Tool: Equatable, Sendable {
        var name: String
        var version: String
    }

    /// The relay link as the host itself sees it — the other end of the socket
    /// this phone is talking over.
    struct Relay: Equatable, Sendable {
        var instanceID: String = ""
        var url: String = ""
        var transport: String = ""
        var connectedAt: Date?
        var lastPongAt: Date?
        var rttMilliseconds: Double?
        var capabilities: [String] = []
        var deltaSeq: Int = 0
        var signedIn: Bool = false
    }

    struct ConnectionError: Equatable, Sendable, Identifiable {
        var at: Date
        var code: String
        var text: String
        var id: String { "\(at.timeIntervalSince1970)-\(code)" }
    }

    // Identity
    var host = ""
    var os = ""
    var kernel = ""
    var arch = ""
    var cpuModel = ""
    var cpuThreads = 0
    var uptimeSeconds: Double = 0
    var agentKind = ""              // "Udha.app" / "udha-agent"
    var agentVersion = ""
    var agentResidentBytes: UInt64 = 0

    // Load
    var cpuPercent: Double?
    var load: [Double] = []

    // Memory
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    // Disk (root volume)
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskDevice = ""

    var temperatures: [Reading] = []
    var gpu: GPU?
    var docker: Docker?
    var net: Net?
    var topProcesses: [Proc] = []
    var tools: [Tool] = []

    // Sessions as the machine itself counts them
    var sessionCount = 0
    var tmuxNote = ""
    var loggedInUsers = 0

    var collector = ""
    var relay: Relay?
    var logTail: [String] = []
    var errors: [ConnectionError] = []
    var sampledAt = Date()

    var memoryPercent: Double? {
        guard memoryTotal > 0 else { return nil }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }

    var diskPercent: Double? {
        guard diskTotal > 0 else { return nil }
        return Double(diskUsed) / Double(diskTotal) * 100
    }

    /// The temperature worth showing, by preference order of the labels a
    /// collector is likely to have used.
    func temperature(matching needles: [String]) -> Double? {
        for needle in needles {
            if let hit = temperatures.first(where: { $0.label.lowercased().contains(needle) }) {
                return hit.celsius
            }
        }
        return nil
    }
}

// MARK: - Wire

extension MachineStats {
    /// Hand-decoded rather than `Codable` for the same reason the rest of the
    /// protocol is: a host that predates a field omits it, and a synthesised
    /// decoder would fail the whole payload over one missing key.
    init(wire w: [String: Any]) {
        host = w["host"] as? String ?? ""
        os = w["os"] as? String ?? ""
        kernel = w["kernel"] as? String ?? ""
        arch = w["arch"] as? String ?? ""
        cpuModel = w["cpuModel"] as? String ?? ""
        cpuThreads = w["cpuThreads"] as? Int ?? 0
        uptimeSeconds = MachineStats.double(w["uptimeSeconds"]) ?? 0
        agentKind = w["agentKind"] as? String ?? ""
        agentVersion = w["agentVersion"] as? String ?? ""
        agentResidentBytes = MachineStats.bytes(w["agentResidentBytes"])

        cpuPercent = MachineStats.double(w["cpuPercent"])
        load = (w["load"] as? [Any])?.compactMap { MachineStats.double($0) } ?? []

        memoryUsed = MachineStats.bytes(w["memoryUsed"])
        memoryTotal = MachineStats.bytes(w["memoryTotal"])
        swapUsed = MachineStats.bytes(w["swapUsed"])
        swapTotal = MachineStats.bytes(w["swapTotal"])

        diskUsed = MachineStats.bytes(w["diskUsed"])
        diskTotal = MachineStats.bytes(w["diskTotal"])
        diskDevice = w["diskDevice"] as? String ?? ""

        temperatures = (w["temperatures"] as? [[String: Any]])?.compactMap {
            guard let label = $0["label"] as? String,
                  let celsius = MachineStats.double($0["celsius"]) else { return nil }
            return Reading(label: label, celsius: celsius)
        } ?? []

        if let g = w["gpu"] as? [String: Any] {
            gpu = GPU(name: g["name"] as? String ?? "",
                      utilPercent: MachineStats.double(g["utilPercent"]),
                      memUsedMB: MachineStats.double(g["memUsedMB"]),
                      memTotalMB: MachineStats.double(g["memTotalMB"]),
                      celsius: MachineStats.double(g["celsius"]),
                      watts: MachineStats.double(g["watts"]),
                      fanPercent: MachineStats.double(g["fanPercent"]))
        }

        if let d = w["docker"] as? [String: Any] {
            docker = Docker(running: d["running"] as? Int ?? 0,
                            note: d["note"] as? String ?? "")
        }

        if let n = w["net"] as? [String: Any] {
            net = Net(interface: n["interface"] as? String ?? "",
                      rxBytesPerSec: MachineStats.double(n["rxBytesPerSec"]),
                      txBytesPerSec: MachineStats.double(n["txBytesPerSec"]))
        }

        topProcesses = (w["topProcesses"] as? [[String: Any]])?.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return Proc(name: name, cpuPercent: MachineStats.double($0["cpuPercent"]) ?? 0)
        } ?? []

        tools = (w["tools"] as? [[String: Any]])?.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return Tool(name: name, version: $0["version"] as? String ?? "")
        } ?? []

        sessionCount = w["sessionCount"] as? Int ?? 0
        tmuxNote = w["tmuxNote"] as? String ?? ""
        loggedInUsers = w["loggedInUsers"] as? Int ?? 0
        collector = w["collector"] as? String ?? ""

        if let r = w["relay"] as? [String: Any] {
            relay = Relay(
                instanceID: r["instanceId"] as? String ?? "",
                url: r["url"] as? String ?? "",
                transport: r["transport"] as? String ?? "",
                connectedAt: MachineStats.date(r["connectedAt"]),
                lastPongAt: MachineStats.date(r["lastPongAt"]),
                rttMilliseconds: MachineStats.double(r["rttMilliseconds"]),
                capabilities: r["capabilities"] as? [String] ?? [],
                deltaSeq: r["deltaSeq"] as? Int ?? 0,
                signedIn: r["signedIn"] as? Bool ?? false
            )
        }

        logTail = w["logTail"] as? [String] ?? []
        errors = (w["errors"] as? [[String: Any]])?.compactMap {
            guard let at = MachineStats.date($0["at"]) else { return nil }
            return ConnectionError(at: at,
                                   code: $0["code"] as? String ?? "",
                                   text: $0["text"] as? String ?? "")
        } ?? []
        sampledAt = MachineStats.date(w["sampledAt"]) ?? Date()
    }

    /// JSON numbers arrive as `Int`, `Double` or `NSNumber` depending on how
    /// the host serialised them; all three have to land in the same field.
    private static func double(_ any: Any?) -> Double? {
        switch any {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    private static func bytes(_ any: Any?) -> UInt64 {
        switch any {
        case let v as UInt64: return v
        case let v as Int where v >= 0: return UInt64(v)
        case let v as Double where v >= 0: return UInt64(v)
        case let v as NSNumber: return v.uint64Value
        default: return 0
        }
    }

    private static func date(_ any: Any?) -> Date? {
        guard let seconds = double(any), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Formatting

extension MachineStats {
    static func gigabytes(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// Terabytes once a disk is big enough that gigabytes stop being readable.
    static func capacity(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// "20.6 / 36.0 GB", but "612 GB / 2.0 TB".
    ///
    /// The unit twice is a third of the width of a stat card on a phone and says
    /// nothing the second time — so it is written once when both halves land in
    /// the same unit. When they do not, dropping it would cost a digit of the
    /// used figure ("0.6 / 2.0 TB" for 612 GB), and the reading matters more
    /// than the width.
    static func pair(_ used: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return "—" }
        let usedText = capacity(used)
        let totalText = capacity(total)
        let usedUnit = usedText.split(separator: " ").last
        let totalUnit = totalText.split(separator: " ").last
        guard usedUnit == totalUnit, let value = usedText.split(separator: " ").first else {
            return "\(usedText) / \(totalText)"
        }
        return "\(value) / \(totalText)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func uptime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "—" }
        let mb = bytesPerSecond / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}
