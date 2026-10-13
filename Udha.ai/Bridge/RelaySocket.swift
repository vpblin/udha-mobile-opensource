import Foundation
import Network
import os

/// Raw WebSocket transport to the Udha relay.
///
/// Deliberately knows nothing about sessions, phases or voice — it owns the
/// socket lifecycle (auth, keepalive, reconnect) and the relay's own envelope
/// protocol (pairing, instance discovery, `{type:"relay", payload:…}` wrapping)
/// and hands everything else upward as a payload plus the instance it came
/// from. The previous build fused this with all protocol and UI state in one
/// 650-line class, which is why multi-instance was impossible to add.
///
/// ## Liveness
///
/// `URLSessionWebSocketTask` will not tell you that a connection has died. A
/// NAT table forgetting the flow, a Wi-Fi→cellular handoff, or a phone that was
/// suspended for fifteen minutes all leave a task that reports no error and
/// delivers no bytes, forever. This class therefore never infers health from
/// the API alone; it insists on proof:
///
/// - `.connected` is reached only when something actually arrives — the dial is
///   confirmed by a pong, not by `resume()` returning.
/// - Silence past `ConnectionHealth.silenceLimit` is treated as death.
/// - Returning to the foreground forces a probe rather than assuming the socket
///   survived being suspended.
/// - `NWPathMonitor` redials the moment the network comes back, and — just as
///   importantly — stops the redial loop entirely while there is no network to
///   dial over.
@MainActor
final class RelaySocket {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected          // socket open, liveness proven
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    // MARK: - Callbacks

    /// A payload forwarded from a host, with the instance that sent it.
    var onPayload: ((_ payload: [String: Any], _ instanceID: String) -> Void)?
    /// A relay-server-level message (pairing, instance status).
    var onRelayDirect: ((_ json: [String: Any]) -> Void)?
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// This client's relay-assigned id, learned from `hello_ack`. Hosts use it
    /// to address terminal frames and PTY output to this device only.
    private(set) var clientID: String?

    /// When anything last arrived — a relay message or a bare pong frame. The
    /// single source of truth for "is this socket alive".
    private(set) var lastInboundAt: Date?

    // MARK: - Internals

    private let auth0: Auth0Manager
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var listenID: UInt64 = 0
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    /// Whether anyone has asked for a connection at all.
    ///
    /// Not the same as "not disconnected": before `connect()` is ever called
    /// there is nothing to restore, and a foreground or a path change must not
    /// dial on its own. (In mock mode nobody ever connects, and an unasked-for
    /// dial would fail auth and drag the whole UI into a failed state.)
    private var wantsConnection = false
    /// True between `enterBackground()` and `enterForeground()`. While set, the
    /// socket neither pings nor redials: the process is about to be frozen and
    /// any work scheduled here is either wasted or, worse, runs in the brief
    /// window the OS grants and burns radio for a screen nobody is looking at.
    private var isBackgrounded = false
    /// Invalidates in-flight probes, so a probe launched before a reconnect
    /// cannot kill the connection that replaced it.
    private var probeToken: UInt64 = 0
    private var pathMonitor: NWPathMonitor?
    private var pathToken = "unknown"
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "relay")

    init(auth0: Auth0Manager) {
        self.auth0 = auth0
    }

    // MARK: - Lifecycle

    func connect() async {
        guard !state.isConnected, state != .connecting else { return }
        wantsConnection = true
        isBackgrounded = false
        reconnectTask?.cancel()
        reconnectTask = nil
        startPathMonitoring()
        await open()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPing()
        stopPathMonitoring()
        probeToken &+= 1
        listenID &+= 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        clientID = nil
        lastInboundAt = nil
        state = .disconnected
    }

    /// Manual retry from the UI after a failure. Deliberately impatient — a
    /// person tapping "Reconnect" has already waited.
    func retry() async {
        guard wantsConnection else { return }
        reconnectAttempts = 0
        await open()
    }

    // MARK: - App lifecycle
    //
    // iOS suspends the process seconds after backgrounding, so there is no such
    // thing as keeping this socket warm. The design accepts that: die quietly,
    // resync fast on return. Backgrounded pushes arrive over APNs, which the OS
    // batches for free.

    func enterBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        // Stop everything that could wake the radio. The socket itself is left
        // in place: a three-second app switch should not cost a full re-dial
        // and re-handshake, and while suspended an idle task costs nothing.
        stopPing()
        reconnectTask?.cancel()
        reconnectTask = nil
        probeToken &+= 1
        stopPathMonitoring()
    }

    /// Never trusts the socket it went to sleep with. Either there is no task
    /// at all (dial afresh) or there is one of unknown health (probe it, and
    /// redial at once if it does not answer).
    func enterForeground() {
        guard isBackgrounded else { return }
        isBackgrounded = false
        guard wantsConnection else { return }

        startPathMonitoring()

        guard task != nil, state.isConnected || state == .connecting else {
            reconnectNow()
            return
        }
        startPing()
        probe(timeout: ConnectionHealth.probeTimeout, reason: "foreground", redialImmediately: true)
    }

    private func open() async {
        guard wantsConnection, !isBackgrounded else { return }

        probeToken &+= 1
        listenID &+= 1
        let dial = listenID
        stopPing()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastInboundAt = nil
        state = .connecting

        guard let token = await auth0.getValidToken() else {
            guard dial == listenID else { return }
            state = .failed("Not signed in")
            scheduleReconnect()
            return
        }
        // Fetching a token suspends, and a path change or a foreground probe
        // can start a newer dial while we are gone. Without this the older one
        // would return and quietly overwrite `task` with a socket nobody is
        // listening to — a zombie that looks connected and delivers nothing.
        guard dial == listenID else { return }

        guard let url = URL(string: RelayConfig.clientURL(token: token)) else {
            state = .failed("Bad relay URL")
            return
        }

        let task = session.webSocketTask(with: url)
        // A staged screenshot travels as base64 in one message, which the 1 MiB
        // default does not reliably fit. The host raised its ceiling to match.
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()

        listen(id: dial)
        startPing()

        // `resume()` proves nothing — it succeeds against an unreachable relay
        // just as happily as a reachable one. A protocol-level ping is answered
        // by any compliant server, so its pong is what promotes us to
        // `.connected`; until then the UI honestly says "Connecting…".
        probe(timeout: ConnectionHealth.connectTimeout, reason: "connect", redialImmediately: false)
    }

    /// Redial immediately, ignoring backoff. For the cases where waiting is
    /// plainly wrong: the user asked, or the network just came back.
    private func reconnectNow() {
        guard wantsConnection, !isBackgrounded else { return }
        reconnectTask?.cancel()
        reconnectAttempts = 0
        reconnectTask = Task { @MainActor [weak self] in
            await self?.open()
        }
    }

    private func scheduleReconnect() {
        guard wantsConnection, !isBackgrounded else { return }
        // No network means nothing to dial. Stay quiet and let the path monitor
        // wake us — a phone in a tunnel must not retry for the whole tunnel.
        guard pathToken != "none" else {
            log.info("relay reconnect deferred — no network path")
            return
        }
        reconnectTask?.cancel()
        let delay = ConnectionHealth.backoffDelay(attempt: reconnectAttempts)
        reconnectAttempts += 1
        log.info("relay reconnect in \(Int(delay))s (attempt \(self.reconnectAttempts))")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.wantsConnection, !self.isBackgrounded else { return }
            await self.open()
        }
    }

    /// The socket is not coming back. Tear it down and decide how soon to redial.
    private func declareDead(_ reason: String, redialImmediately: Bool) {
        log.error("relay dead: \(reason)")
        probeToken &+= 1
        listenID &+= 1
        stopPing()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        clientID = nil
        lastInboundAt = nil
        state = .failed(reason)
        if redialImmediately { reconnectNow() } else { scheduleReconnect() }
    }

    // MARK: - Sending

    /// Sends at the relay-protocol level: `pair_request`, `set_active_instance`,
    /// `register_device`, `ping`.
    @discardableResult
    func sendRaw(_ message: [String: Any]) -> Bool {
        guard let task, state.isConnected else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let str = String(data: data, encoding: .utf8) else { return false }
        let dial = listenID
        task.send(.string(str)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                // Late errors from a socket we have already replaced are noise;
                // acting on them would kill the connection that succeeded it.
                guard let self, dial == self.listenID else { return }
                // A send that fails is proof of death, and the only such proof
                // this API ever volunteers. Do not merely log it.
                self.declareDead("send failed: \(error.localizedDescription)",
                                 redialImmediately: false)
            }
        }
        return true
    }

    /// Wraps `payload` for delivery to one host instance.
    @discardableResult
    func sendPayload(_ payload: [String: Any], to instanceID: String) -> Bool {
        sendRaw([
            "type": "relay",
            "instanceId": instanceID,
            "payload": payload,
        ])
    }

    /// Registers this device's APNs token so the relay can push when the app
    /// is backgrounded (WS-2b).
    func attentionPresence(sessionID: String?, instanceID: String?) {
        var payload: [String: Any] = ["type": "attention_presence"]
        if let sessionID, let instanceID { payload["sessionId"] = sessionID; payload["instanceId"] = instanceID }
        sendRaw(payload)
    }

    func registerDeviceToken(_ token: String) {
        sendRaw(["type": "register_device", "deviceToken": token])
    }

    func subscribe(to instanceID: String) {
        sendRaw(["type": "set_active_instance", "instanceId": instanceID])
    }

    /// Subscribe to every machine at once.
    ///
    /// `set_active_instance` clears the relay's subscription set, which is what
    /// pinned this client to one machine at a time. `subscribe_instances` sets
    /// the whole set instead, so the fleet arrives as one list and a session
    /// stays reachable on whichever box is running it.
    func subscribe(to instanceIDs: [String]) {
        sendRaw(["type": "subscribe_instances", "instanceIds": instanceIDs])
    }

    func requestPairing(with instanceID: String) {
        sendRaw([
            "type": "pair_request",
            "instanceId": instanceID,
            "pairingToken": "auto-pair-from-mobile-v1",
        ])
    }

    // MARK: - Receiving

    private func listen(id: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while id == self.listenID, let task = self.task {
                do {
                    let message = try await task.receive()
                    guard id == self.listenID else { return }
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        self.noteInbound()
                    }
                } catch {
                    guard id == self.listenID else { return }
                    self.declareDead(error.localizedDescription, redialImmediately: false)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        // Recorded before parsing: even a message we do not understand is proof
        // the wire is alive, which is all the watchdog cares about.
        noteInbound()

        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "pong":
            return
        case "relay":
            // The relay stamps the source instance onto forwarded messages.
            guard let payload = json["payload"] as? [String: Any] else { return }
            let instanceID = (json["instanceId"] as? String) ?? ""
            if let cid = payload["clientId"] as? String { clientID = cid }
            onPayload?(payload, instanceID)
        default:
            onRelayDirect?(json)
        }
    }

    /// The one place liveness is established. Promotes a dial to `.connected`,
    /// which is also the only place the backoff counter is allowed to reset —
    /// resetting it on `resume()` is what made the old backoff never escalate.
    private func noteInbound() {
        lastInboundAt = Date()
        if state == .connecting {
            state = .connected
            reconnectAttempts = 0
        }
    }

    // MARK: - Keepalive

    private func startPing() {
        stopPing()
        guard !isBackgrounded else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: ConnectionHealth.pingInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Nothing here needs to be punctual. Letting the OS coalesce this with
        // other wake-ups is free battery.
        timer.tolerance = ConnectionHealth.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// One wake-up serving two jobs: notice death, and only then spend a frame
    /// on a keepalive. A busy session satisfies `shouldPing` on its own traffic
    /// and sends nothing at all.
    private func tick() {
        guard !isBackgrounded else { return }
        let now = Date()

        if ConnectionHealth.isDead(lastInboundAt: lastInboundAt, now: now) {
            declareDead("relay went quiet for \(Int(ConnectionHealth.silenceLimit))s",
                        redialImmediately: false)
            return
        }
        if ConnectionHealth.shouldPing(lastInboundAt: lastInboundAt, now: now) {
            sendRaw(["type": "ping"])
        }
    }

    /// Asks the socket to prove itself within `timeout`.
    ///
    /// Uses a protocol-level ping rather than the relay's JSON `ping` so the
    /// answer does not depend on application code being alive at the far end —
    /// this has to work even when the relay is wedged.
    private func probe(timeout: TimeInterval, reason: String, redialImmediately: Bool) {
        guard let task else { return }
        probeToken &+= 1
        let token = probeToken
        let start = Date()

        task.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, token == self.probeToken else { return }
                if let error {
                    self.declareDead("\(reason) probe failed: \(error.localizedDescription)",
                                     redialImmediately: redialImmediately)
                } else {
                    self.noteInbound()
                }
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, token == self.probeToken else { return }
            // Any traffic since the probe began proves the point; the pong is
            // not special, it is just the cheapest thing to ask for.
            if let last = self.lastInboundAt, last >= start { return }
            self.declareDead("\(reason) probe timed out after \(Int(timeout))s",
                             redialImmediately: redialImmediately)
        }
    }

    // MARK: - Network path
    //
    // Event-driven, not polled: the monitor costs nothing while the network is
    // steady, and earns its keep twice over — it redials the instant coverage
    // returns, and it lets `scheduleReconnect` stay silent while there is none.

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            // Reduce to a Sendable token on the monitor's own queue rather than
            // ferrying NWPath across actors.
            let token: String
            if path.status != .satisfied { token = "none" }
            else if path.usesInterfaceType(.wifi) { token = "wifi" }
            else if path.usesInterfaceType(.cellular) { token = "cell" }
            else if path.usesInterfaceType(.wiredEthernet) { token = "wired" }
            else { token = "other" }

            Task { @MainActor [weak self] in self?.handlePath(token) }
        }
        monitor.start(queue: DispatchQueue(label: "\(AppConfig.logSubsystem).relay.path"))
        pathMonitor = monitor
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePath(_ token: String) {
        let previous = pathToken
        pathToken = token
        guard previous != token else { return }
        // The monitor reports the current path as soon as it starts. That first
        // report is not a change — acting on it would tear down the dial that
        // `connect()` had just started, on every single launch.
        guard previous != "unknown" else { return }
        log.info("network path \(previous) → \(token)")
        guard wantsConnection, !isBackgrounded else { return }

        guard token != "none" else {
            // Offline. Stop the churn; the next path update is our wake-up.
            reconnectTask?.cancel()
            reconnectTask = nil
            stopPing()
            return
        }

        // Coverage returned, or we moved between Wi-Fi and cellular. Either way
        // any existing socket is bound to a path that no longer exists and will
        // never report the fact. Start over, without waiting out a backoff.
        reconnectNow()
    }
}
