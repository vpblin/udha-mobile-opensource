import SwiftUI

/// One machine's detail screen: what it is, whether this client can see it, and
/// what it has been doing.
///
/// This used to answer "what is it now" — four bars and a table of key/values.
/// It answers "what has it been doing" instead: every number carries the shape
/// it has been making, because a reading of 68% tells you nothing on its own and
/// a line tells you whether that is a plateau or a climb. Nothing extra is
/// collected for the charts — the screen already causes a sample every five
/// seconds while it is open, and `MachineHistory` keeps them.
///
/// Every connected machine reports its own vitals, whichever one the Sessions
/// tab is showing. A machine this client has no live connection to shows its
/// identity and a way to reconnect, not invented numbers.
///
/// Every value here is measured. A field the collector could not read renders as
/// "—" rather than 0, because a dash says "no reading" and a zero lies. A series
/// with fewer than two samples draws a dashed baseline and says "collecting"
/// instead of a dot that would read as data.
struct MachineDetail: View {
    let bridge: UdhaBridge
    let machineID: String
    var onBack: (() -> Void)? = nil

    private var instance: BridgeInstance? {
        bridge.instances.first { $0.id == machineID }
    }

    private var isConnected: Bool { bridge.isConnected(machineID) }
    private var stats: MachineStats? { bridge.stats(for: machineID) }
    private var history: MachineHistory { bridge.history }

    /// The level at which a reading stops being information and starts being a
    /// warning. The same threshold the bars used, so hot still means one thing
    /// across the app.
    private let hotAbove: Double = 80

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Machines",
                onBack: onBack,
                showsSeparator: false
            ) {
                CircleButton(systemImage: "arrow.clockwise", diameter: 36) {
                    bridge.refreshStats()
                }
                .accessibilityLabel("Refresh vitals")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityHead

                    if isConnected {
                        if let stats {
                            resourceGrid(stats)
                            temperatures(stats)
                            work(stats)
                            subStats(stats)
                            if !stats.tools.isEmpty { toolchain(stats) }
                            errors(stats)
                            identity(stats)
                            if !stats.logTail.isEmpty { log(stats) }
                            Text(footer(stats))
                                .font(UdhaFont.regular(11.5))
                                .foregroundStyle(UdhaTheme.tertiary)
                                .padding(.horizontal, 4)
                        } else if !bridge.canReportStats(machineID) {
                            note("This host does not report vitals. Update Udha on it.")
                        } else if bridge.isLoadingStats(machineID) {
                            note("Reading…")
                        } else {
                            note("No reading yet. Pull down to ask.")
                        }
                    } else if instance?.isOnline == true {
                        note("Connecting…")
                        SecondaryButton(title: "Reconnect", systemImage: "arrow.clockwise") {
                            Task { await bridge.hardReconnect() }
                        }
                    } else {
                        note("Offline. Nothing to read until it comes back.")
                        SecondaryButton(title: "Re-check", systemImage: "arrow.clockwise") {
                            Task { await bridge.hardReconnect() }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 36)
            }
            .refreshable { bridge.refreshStats() }
        }
        .background(UdhaTheme.canvas)
        // The poll runs only while this screen is up, which is also what makes
        // the charts' spans honest: they cover the time you have been watching.
        .onAppear { bridge.addStatsViewer() }
        .onDisappear { bridge.removeStatsViewer() }
    }

    /// This machine's own handshake, not the active host's.
    private var kind: String {
        bridge.feeds[machineID]?.handshake?.instanceKind == "udha-headless" ? "udha-agent" : "Udha"
    }

    private var stateLine: String? {
        guard let instance else { return nil }
        guard instance.isOnline else { return "Offline" }
        guard isConnected else { return "Online · connecting" }
        return kind == "udha-headless" ? "udha-agent" : "Udha"
    }

    // MARK: - Head

    /// The machine's name at title size, then the three facts that decide
    /// whether the rest of the screen is worth reading.
    private var identityHead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instance?.displayName ?? machineID)
                .font(UdhaFont.bold(32))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 7) {
                if instance?.isOnline == true {
                    Pill(isConnected ? "Connected" : "Online",
                         tint: UdhaTheme.goodInk, showsDot: true)
                } else {
                    Pill("Offline", tint: UdhaTheme.badInk, showsDot: true)
                }
                if let rtt = stats?.relay?.rttMilliseconds {
                    QuietPill(String(format: "%.0f ms relay", rtt))
                }
                if let uptime = stats?.uptimeSeconds {
                    QuietPill("up \(MachineStats.uptime(uptime))")
                }
            }

            if let meta = machineMeta {
                Text(meta)
                    .font(UdhaFont.regular(13))
                    .lineSpacing(2)
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var machineMeta: String? {
        guard let s = stats else { return nil }
        var parts: [String] = []
        if !s.os.isEmpty { parts.append(s.os) }
        if !s.cpuModel.isEmpty {
            parts.append(s.cpuThreads > 0 ? "\(s.cpuModel) (\(s.cpuThreads)T)" : s.cpuModel)
        }
        if s.memoryTotal > 0 { parts.append(MachineStats.gigabytes(s.memoryTotal)) }
        if let relay = s.relay, !relay.instanceID.isEmpty { parts.append("instance \(relay.instanceID)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Resources

    /// Four measurements over the time you have been watching, two across. The
    /// desktop's six-across strip does not survive a phone: a sparkline
    /// narrower than a thumb is decoration.
    private func resourceGrid(_ s: MachineStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(Array(charts(s).enumerated()), id: \.offset) { _, chart in
                StatCard(label: chart.label,
                         value: chart.value,
                         note: chart.note,
                         series: chart.series,
                         hot: chart.hot)
            }
        }
    }

    private struct Chart {
        var label: String
        var value: String
        var note: String
        var series: [Double]
        var hot: Bool
        /// How much time the series covers. "—" until there are two samples.
        var span: String
    }

    private func charts(_ s: MachineStats) -> [Chart] {
        let cpuNote: String = {
            var parts: [String] = []
            if !s.load.isEmpty {
                parts.append("load " + s.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            if s.cpuThreads > 0 { parts.append("\(s.cpuThreads) threads") }
            if let t = s.temperature(matching: ["tctl", "package", "core"]) {
                parts.append(String(format: "%.0f °C", t))
            }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }()

        let memNote = s.swapTotal > 0
            ? "swap \(MachineStats.gigabytes(s.swapUsed)) / \(MachineStats.gigabytes(s.swapTotal))"
            : "no swap"

        let diskNote: String = {
            var parts = [s.diskDevice]
            if s.diskTotal > s.diskUsed {
                parts.append("\(MachineStats.gigabytes(s.diskTotal - s.diskUsed)) free")
            }
            if let t = s.temperature(matching: ["nvme"]) { parts.append(String(format: "%.0f °C", t)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }()

        let gpuNote: String = {
            guard let gpu = s.gpu else { return "no GPU reported" }
            var parts: [String] = [gpu.name]
            if let used = gpu.memUsedMB, let total = gpu.memTotalMB, total > 0 {
                parts.append(String(format: "%.1f / %.0f GB", used / 1024, total / 1024))
            }
            if let t = gpu.celsius { parts.append(String(format: "%.0f °C", t)) }
            if let w = gpu.watts { parts.append(String(format: "%.0f W", w)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }()

        return [
            Chart(label: "CPU", value: MachineStats.percent(s.cpuPercent), note: cpuNote,
                  series: history.series(machineID, .cpu),
                  hot: (s.cpuPercent ?? 0) >= hotAbove, span: history.span(machineID, .cpu)),
            Chart(label: "Memory", value: memoryHeadline(s), note: memNote,
                  series: history.series(machineID, .memory),
                  hot: (s.memoryPercent ?? 0) >= hotAbove, span: history.span(machineID, .memory)),
            Chart(label: "Disk",
                  value: MachineStats.pair(s.diskUsed, s.diskTotal),
                  note: diskNote, series: history.series(machineID, .disk),
                  hot: (s.diskPercent ?? 0) >= hotAbove, span: history.span(machineID, .disk)),
            Chart(label: "GPU", value: MachineStats.percent(s.gpu?.utilPercent), note: gpuNote,
                  series: history.series(machineID, .gpu),
                  hot: (s.gpu?.utilPercent ?? 0) >= hotAbove, span: history.span(machineID, .gpu)),
        ]
    }

    private func memoryHeadline(_ s: MachineStats) -> String {
        MachineStats.pair(s.memoryUsed, s.memoryTotal)
    }

    // MARK: - Temperatures

    /// One row per sensor the machine actually exposes, each with its own line.
    /// A box with no hwmon says so rather than drawing rows at 0 °C — the
    /// difference between "cold" and "no sensor" is the whole premise here.
    @ViewBuilder
    private func temperatures(_ s: MachineStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Temperatures",
                          note: s.temperatures.isEmpty ? nil : "\(s.temperatures.count) sensors")
            if s.temperatures.isEmpty {
                UdhaCard {
                    // The Mac genuinely cannot answer this; a Linux box with no
                    // hwmon is a different fact and gets a different sentence.
                    Text(kind == "udha-agent"
                         ? "No sensor samples — hwmon reported nothing on this machine."
                         : "macOS has no public sensor API, so the Mac reports no temperatures.")
                        .font(UdhaFont.regular(14))
                        .lineSpacing(2)
                        .foregroundStyle(UdhaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                    ForEach(Array(s.temperatures.enumerated()), id: \.offset) { index, reading in
                        if index > 0 { CardDivider() }
                        temperatureRow(reading)
                    }
                }
            }
        }
    }

    private func temperatureRow(_ reading: MachineStats.Reading) -> some View {
        let series = history.temperature(machineID, label: reading.label)
        let hot = reading.celsius >= hotAbove
        let warm = reading.celsius >= 55
        return HStack(spacing: 12) {
            Text(reading.label)
                .font(UdhaFont.regular(14.5))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            Sparkline(values: series,
                      color: hot ? UdhaTheme.bad : (warm ? UdhaTheme.warn : UdhaTheme.accent),
                      lineWidth: 1.6,
                      animated: false)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            Text(String(format: "%.0f °C", reading.celsius))
                .font(UdhaFont.semibold(15))
                .monospacedDigit()
                .foregroundStyle(hot ? UdhaTheme.bad : UdhaTheme.label)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
    }

    // MARK: - Work

    /// How many sessions this machine has been holding while you watched, which
    /// is the line that tells you a hand-off actually landed.
    private func work(_ s: MachineStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Sessions here",
                          note: s.tmuxNote.isEmpty ? nil : s.tmuxNote)
            UdhaCard {
                HStack(alignment: .center, spacing: 12) {
                    Text("\(s.sessionCount)")
                        .font(UdhaFont.bold(30))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.label)
                    Text(s.sessionCount == 0
                         ? "tmux sessions — nothing to reattach"
                         : "tmux sessions · \(history.span(machineID, .sessions))")
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(UdhaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Sparkline(values: history.series(machineID, .sessions),
                              fill: UdhaTheme.accentTint)
                        .frame(width: 86, height: 30)
                }
            }
        }
    }

    // MARK: - Sub stats

    private func subStats(_ s: MachineStats) -> some View {
        let network: String = {
            guard let net = s.net else { return "—" }
            guard net.rxBytesPerSec != nil || net.txBytesPerSec != nil else {
                return net.interface.isEmpty ? "—" : net.interface
            }
            return "↓\(MachineStats.rate(net.rxBytesPerSec)) ↑\(MachineStats.rate(net.txBytesPerSec))"
        }()
        let docker: String = {
            guard let d = s.docker else { return "not collected" }
            return d.running == 0 ? "none running" : "\(d.running) running"
        }()
        let top = s.topProcesses.isEmpty
            ? "—"
            : s.topProcesses.prefix(2)
                .map { "\($0.name) \(String(format: "%.0f", $0.cpuPercent))%" }
                .joined(separator: " · ")
        let items = [("Network", network), ("Docker", docker),
                     ("Top processes", top), ("Logged in", "\(s.loggedInUsers)")]
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Host", note: s.collector.isEmpty ? nil : s.collector)
            UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardDivider() }
                    keyValue(item.0, item.1)
                }
            }
        }
    }

    // MARK: - Toolchain

    private func toolchain(_ s: MachineStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Toolchain", note: "\(s.tools.count) tools")
            UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                ForEach(Array(s.tools.enumerated()), id: \.offset) { index, tool in
                    if index > 0 { CardDivider() }
                    keyValue(tool.name, tool.version.isEmpty ? "—" : tool.version)
                }
            }
        }
    }

    // MARK: - Errors

    /// The one real 24-hour series on this screen: these errors carry their own
    /// timestamps, so they are history from the very first sample rather than
    /// from the moment you opened the screen.
    private func errors(_ s: MachineStats) -> some View {
        let drops = MachineHistory.dropsPerHour(s.errors)
        let total = Int(drops.reduce(0, +))
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Connection drop-outs",
                          note: total == 0 ? "none in 24 h" : "\(total) in 24 h")
            UdhaCard {
                Sparkline(values: drops,
                          color: total == 0 ? UdhaTheme.accent : UdhaTheme.bad,
                          fill: total == 0 ? UdhaTheme.accentTint : UdhaTheme.badTint)
                    .frame(height: 34)
                HStack {
                    Text("24 h ago").font(UdhaFont.regular(11)).foregroundStyle(UdhaTheme.tertiary)
                    Spacer(minLength: 8)
                    Text("now").font(UdhaFont.regular(11)).foregroundStyle(UdhaTheme.tertiary)
                }
                .padding(.top, 4)

                if s.errors.isEmpty {
                    Text("None recorded since the host started.")
                        .font(UdhaFont.regular(13.5))
                        .foregroundStyle(UdhaTheme.secondary)
                        .padding(.top, 10)
                } else {
                    ForEach(s.errors.prefix(5)) { error in
                        HStack(alignment: .top, spacing: 10) {
                            Text(error.at.formatted(date: .omitted, time: .standard))
                                .font(UdhaFont.mono(10.5))
                                .foregroundStyle(UdhaTheme.tertiary)
                                .frame(width: 68, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(error.code)
                                    .font(UdhaFont.semibold(12.5))
                                    .foregroundStyle(UdhaTheme.badInk)
                                if !error.text.isEmpty {
                                    Text(error.text)
                                        .font(UdhaFont.regular(12.5))
                                        .foregroundStyle(UdhaTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
    }

    // MARK: - Identity

    private func identity(_ s: MachineStats) -> some View {
        var rows: [(String, String)] = [
            ("Host", s.host.isEmpty ? "—" : s.host),
            ("OS", s.os.isEmpty ? "—" : s.os),
        ]
        if !s.kernel.isEmpty { rows.append(("Kernel", s.kernel)) }
        if !s.cpuModel.isEmpty {
            rows.append(("CPU", s.cpuThreads > 0 ? "\(s.cpuModel) · \(s.cpuThreads)t" : s.cpuModel))
        }
        if !s.agentKind.isEmpty {
            rows.append(("Agent", "\(s.agentKind) \(s.agentVersion)".trimmingCharacters(in: .whitespaces)))
        }
        if let relay = s.relay, !relay.instanceID.isEmpty {
            rows.append(("Instance", relay.instanceID))
        }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Identity", note: s.arch.isEmpty ? nil : s.arch)
            UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardDivider() }
                    keyValue(item.0, item.1)
                }
            }
        }
    }

    // MARK: - Log

    private func log(_ s: MachineStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Supervisor log", note: "tail")
            UdhaCard {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(s.logTail.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(UdhaFont.mono(10.5))
                            .foregroundStyle(UdhaTheme.inkCode)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func footer(_ s: MachineStats) -> String {
        let age = Int(Date().timeIntervalSince(s.sampledAt))
        let when = age < 60 ? "\(max(age, 0))s ago" : "\(age / 60)m ago"
        return s.collector.isEmpty ? "Sampled \(when)" : "Sampled \(when) · \(s.collector)"
    }

    // MARK: - Pieces

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(UdhaFont.regular(14))
                .foregroundStyle(UdhaTheme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(UdhaFont.medium(14))
                .foregroundStyle(UdhaTheme.label)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private func note(_ text: String) -> some View {
        UdhaCard {
            Text(text)
                .font(UdhaFont.regular(14.5))
                .lineSpacing(2)
                .foregroundStyle(UdhaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
