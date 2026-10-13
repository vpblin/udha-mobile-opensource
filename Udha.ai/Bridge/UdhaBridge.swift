import Foundation
import Observation
import os

/// The app's protocol-v2 client: instance discovery, the capability handshake,
/// fleet state, and every action verb.
///
/// Owns a `RelaySocket` for transport and a `VoiceSession` for the audio stack,
/// but holds no audio or UI logic itself. State is `@Observable`, so views read
/// `fleet` directly and SwiftUI tracks only the properties each view touches.
@MainActor
@Observable
final class UdhaBridge {

    enum Status: Equatable {
        case disconnected
        case connecting
        case awaitingHost        // relay up, no host online
        case pairing
        case ready               // host paired + handshake complete
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    // MARK: - Connection

    private(set) var status: Status = .disconnected
    private(set) var lastError: String?

    /// Every host the relay knows about, online or not.
    private(set) var instances: [BridgeInstance] = []
    /// The host currently subscribed to. All payloads route here.
    private(set) var activeInstanceID: String?
    /// The host the user *chose*, as distinct from the one currently paired.
    ///
    /// Intent, so it survives a socket drop: a reconnect must return to the
    /// same machine rather than silently landing on whichever host answers
    /// first. `activeInstanceID` is the confirmed half and gets cleared on
    /// every disconnect; this half does not.
    private(set) var preferredInstanceID: String?

    var activeInstance: BridgeInstance? {
        guard let activeInstanceID else { return nil }
        return instances.first { $0.id == activeInstanceID }
    }

    /// What one host is telling us.
    ///
    /// A fleet is several machines, and every one of them keeps its own
    /// sessions, its own capabilities and its own delta sequence. Holding a
    /// single set of those is what forced "one machine at a time": the Sessions
    /// list could only ever contain one host's work, so reaching the other one
    /// meant switching and losing sight of the first.
    struct HostFeed {
        var sessions: [SessionRow] = []
        /// This machine's folders, in its own order. Only `sessions_full`
        /// carries them: a folder edit on the host is a full push.
        var folders: [SessionFolder] = []
        var handshake: HelloAck?
        /// Per host: two machines interleaving their sequence numbers in one
        /// counter would read as a permanent gap and resync forever.
        var lastSeq: Int?
        var syncedAt: Date?
    }

    /// Keyed by instance id. Only subscribed, online machines have one.
    private(set) var feeds: [String: HostFeed] = [:]

    /// Each machine's Claude logins, from its last `accounts` message. Keyed by
    /// instance id like `feeds`: a login pool is one machine's config dirs.
    private(set) var hostLogins: [String: HostLogins] = [:]

    /// Rebuild the flat fleet the views read, from every subscribed host.
    ///
    /// Owned rows win over forwarded ones. The Mac keeps devbox's sessions in
    /// its own store and forwards them tagged with `host`, so with both
    /// machines subscribed the same session arrives twice under one id — and
    /// the copy worth keeping is the one from the machine actually running it,
    /// because that is the only host that will answer `attach_terminal` for it.
    /// A forwarded row is still kept when its owner is *not* subscribed, so a
    /// box this device cannot reach is listed rather than silently missing.
    private func rebuildSessions() {
        var merged: [SessionRow] = []
        var seen = Set<String>()

        func take(_ wantForwarded: Bool) {
            for instance in instances {
                guard let rows = feeds[instance.id]?.sessions else { continue }
                for row in rows where (row.host != nil) == wantForwarded {
                    guard seen.insert(row.id).inserted else { continue }
                    var tagged = row
                    tagged.instanceID = instance.id
                    merged.append(tagged)
                }
            }
        }
        take(false)   // owned
        take(true)    // forwarded, only where the owner is not subscribed
        sessions = merged
        NotificationManager.shared.reconcileAttention(sessions: merged)
    }

    /// The machine a row runs on, in the words the user would use for it.
    func machineName(for row: SessionRow) -> String {
        if let host = row.host, !host.isEmpty { return host }
        if let id = row.instanceID, let instance = instances.first(where: { $0.id == id }) {
            return instance.displayName
        }
        return activeInstance?.displayName ?? "This host"
    }

    /// Whether this client can act on a row rather than merely list it.
    ///
    /// A forwarded row belongs to a machine we are not subscribed to; its host
    /// will refuse `attach_terminal` and say so. Better to know before tapping.
    func canDrive(_ row: SessionRow) -> Bool { row.host == nil }

    /// What the machine running this session can do.
    ///
    /// Capabilities are per host: the Mac and a headless box are different
    /// builds. Asking the *active* host whether a rename will land is the kind
    /// of question that silently answers for the wrong computer once the fleet
    /// is merged.
    func handshake(for row: SessionRow) -> HelloAck? {
        guard let id = row.instanceID else { return handshake }
        return feeds[id]?.handshake
    }

    func canRename(_ row: SessionRow) -> Bool {
        (handshake(for: row)?.supportsRename ?? false) && canDrive(row)
    }

    /// Whether to offer MATCH for this session.
    ///
    /// Optimistic on purpose. This used to be `supportsResize ?? false`, which
    /// hides the control in two cases that are not a refusal: a machine whose
    /// `hello_ack` has not landed yet, and a v1 host that never answers `hello`
    /// at all. Hiding it there is the worse failure — you are only ever driving
    /// one device, so wherever you press MATCH is by definition the screen the
    /// pane should fit, and a host that genuinely cannot resize simply ignores
    /// the verb. Only positive evidence of "no resize" takes it away.
    func canUseAttention(_ row: SessionRow) -> Bool {
        canDrive(row) && row.supportsAttentionEvents
    }

    func changeAttention(_ id: String, action: String, eventID: String? = nil, enabled: Bool = false) {
        guard let row = session(id: id), canUseAttention(row) else { return }
        send(.attentionAction(id: id, action: action, eventID: eventID, enabled: enabled), forSession: id)
    }

    func attentionPresence(_ id: String?) {
        socket.attentionPresence(sessionID: id, instanceID: id.flatMap { instanceID(forSession: $0) })
    }

    func canResize(_ row: SessionRow) -> Bool {
        guard canDrive(row) else { return false }   // no pane, nothing to fit
        guard let ack = handshake(for: row) else { return true }
        return ack.supportsResize
    }

    /// The same question for the session the terminal is currently attached to.
    private var attachedCanResize: Bool {
        guard let id = desiredSessionID else { return false }
        guard let row = session(id: id) else { return true }
        return canResize(row)
    }

    /// Which socket a session's actions go down.
    private func instanceID(forSession id: String) -> String? {
        sessions.first { $0.id == id }?.instanceID ?? activeInstanceID
    }

    /// Result of the capability handshake with the active host. `nil` means the
    /// host never answered `hello` — treat it as protocol 1 and poll.
    ///
    /// The *active* host specifically: meetings, videos, agents and new
    /// sessions all belong to the machine the user chose, even though sessions
    /// now arrive from all of them.
    var handshake: HelloAck? {
        guard let activeInstanceID else { return nil }
        return feeds[activeInstanceID]?.handshake
    }

    var isProtocolV2: Bool { (handshake?.protocolVersion ?? 1) >= 2 }

    /// Whether the paired host implements `rename_session`. The control stays
    /// off screen against an older desktop rather than offering a rename that
    /// would quietly go nowhere.
    var canRenameSessions: Bool { handshake?.supportsRename ?? false }
    /// Whether the active host reports its own vitals.
    var canReportStats: Bool { canReportStats(activeInstanceID) }

    /// The active host's vitals, as of the last `fetch_stats`.
    var machineStats: MachineStats? { stats(for: activeInstanceID) }

    /// Every connected host's vitals, keyed by instance id. Vitals used to
    /// belong to the active host only, so a machine you were plainly connected
    /// to read "not connected" the moment the active one moved elsewhere.
    /// Host-owned: a host's reading dies with its connection rather than
    /// lingering beside a machine that has gone away.
    private(set) var hostStats: [String: MachineStats] = [:]
    private var statsLoadingIDs: Set<String> = []

    /// Whether this client holds a live, handshaken connection to a machine.
    func isConnected(_ id: String?) -> Bool {
        guard let id, instances.contains(where: { $0.id == id && $0.isOnline }) else { return false }
        return feeds[id]?.handshake != nil
    }

    func canReportStats(_ id: String?) -> Bool {
        guard let id else { return false }
        return feeds[id]?.handshake?.supportsStats ?? false
    }

    func stats(for id: String?) -> MachineStats? {
        guard let id else { return nil }
        return hostStats[id]
    }

    func isLoadingStats(_ id: String?) -> Bool {
        guard let id else { return false }
        return statsLoadingIDs.contains(id)
    }

    /// Every reading the Machines screen has caused, so it can draw a shape
    /// rather than a number. Nothing extra is collected for it.
    let history = MachineHistory()

    /// Open Machines screens. The poll runs while at least one is watching and
    /// stops the moment the last leaves — collecting vitals shells out to
    /// `nvidia-smi` and `docker ps` on the host, which is not something to do
    /// behind a screen nobody is looking at.
    private var statsViewers = 0
    private var statsPoll: Task<Void, Never>?

    /// Whether the paired host serves its video library.
    var videoHosts: [BridgeInstance] {
        instances.filter { $0.isOnline && feeds[$0.id]?.handshake?.supportsVideos == true }
    }
    private var preferredVideoHostID: String?
    private(set) var videoHostID: String?
    private(set) var videosLoading = false
    private(set) var videoLibraryError: String?
    private var videoLoadTimeout: Task<Void, Never>?
    var videoHost: BridgeInstance? { instances.first { $0.id == videoHostID } }
    var canBrowseVideos: Bool { videoHosts.contains { $0.id == videoHostID } }
    var checkingVideoSupport: Bool {
        instances.contains { $0.isOnline && feeds[$0.id]?.handshake == nil }
    }
    var hasOnlineMac: Bool { instances.contains { $0.isOnline && !$0.isHeadless } }

    func selectVideoHost(_ id: String) {
        guard videoHosts.contains(where: { $0.id == id }) else { return }
        preferredVideoHostID = id
        syncVideoHost()
    }

    private func syncVideoHost() {
        let next = VideoLibraryRouting.hostID(preferred: preferredVideoHostID, current: videoHostID,
            active: activeInstanceID, capable: videoHosts.map(\.id))
        guard next != videoHostID else { return }
        videoHostID = next
        videos = []
        videoTitleRollback.removeAll()
        videoDeleteRollback.removeAll()
        videoLibraryError = nil
        videoLoadTimeout?.cancel()
        videosLoading = false
        if next != nil { listVideos() }
    }
    /// Whether the paired host will stage an image for a session.
    var canStageAttachments: Bool { handshake?.supportsAttachments ?? false }

    /// Images staged for the next message, by session id. Keyed by session
    /// because you pick a screenshot while looking at one pane, and leaving a
    /// session must not carry its attachment into the next one.
    private(set) var attachments: [String: [SessionAttachment]] = [:]

    // MARK: - Fleet

    private(set) var sessions: [SessionRow] = []
    private(set) var quickCommands: [QuickCommand] = QuickCommand.fallback
    private(set) var recentDirectories: [String] = []
    private(set) var directoryListing: DirectoryListing?
    private(set) var branchListing: BranchListing?
    private(set) var lastSessionError: String?
    /// True between `create_session` / `duplicate_session` and the host's
    /// answer, so the sheet can disable its button instead of letting a
    /// double-tap spawn two sessions.
    private(set) var isCreatingSession = false
    /// Id the host reported for the session it just made. The shell selects it
    /// once the matching row actually arrives — `session_created` and the
    /// `sessions_full` carrying the row are separate messages.
    private(set) var lastCreatedSessionID: String?
    /// Time of the last state we received, for the "as of" footer.
    private(set) var lastSyncedAt: Date?

    /// Delta sequence tracking. A gap means we missed a push and must resync
    /// rather than render a fleet that silently drifted from reality.

    /// Labels displaced by an optimistic rename, by session id, kept until the
    /// host answers so a refused rename can be undone.
    private var renameRollback: [String: String] = [:]

    /// The same, for the video library: titles displaced by a rename, and
    /// whole rows removed by a delete, held until the host confirms.
    private var videoTitleRollback: [String: String] = [:]
    private var videoDeleteRollback: [String: (index: Int, video: VideoItem)] = [:]

    func sessions(in attention: SessionAttention) -> [SessionRow] {
        sessions.filter { $0.attention == attention }
    }

    var needsYouCount: Int { sessions.count { $0.attention == .needsYou } }

    func session(id: String) -> SessionRow? {
        sessions.first { $0.id == id }
    }

    // MARK: - Action feedback

    /// Most recent failed action, surfaced as a toast then cleared.
    private(set) var lastActionError: String?
    /// Session ids with an action in flight, so cards can show a spinner and
    /// refuse to double-fire.
    private(set) var pendingActions: Set<String> = []

    // MARK: - Meetings

    private(set) var meetings: [Meeting] = []
    private(set) var agents: [BridgeAgent] = []
    /// The host's video library, newest first as the host orders it.
    private(set) var videos: [VideoItem] = []
    /// The host recording currently in flight, if any.
    private(set) var liveMeetingID: String?
    private(set) var liveElapsedSec: Int = 0
    private(set) var liveTranscript: [TranscriptSegment] = []
    private(set) var askThread: [MeetingAskTurn] = []
    private(set) var askPending = false
    /// Which meeting `askThread` belongs to, so switching meetings does not
    /// show you the previous call's answers.
    private(set) var askMeetingID: String?
    private var askTimeout: Task<Void, Never>?

    var liveMeeting: Meeting? {
        guard let liveMeetingID else { return nil }
        return meetings.first { $0.id == liveMeetingID }
    }

    func meeting(id: String) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func agent(id: String) -> BridgeAgent? {
        agents.first { $0.id == id }
    }

    func video(id: String) -> VideoItem? {
        videos.first { $0.id == id }
    }

    // MARK: - Deep links

    /// Set when a push notification or `udha://session/<uuid>` URL asks for a
    /// specific session. The fleet observes this and pushes the detail view.
    /// Cleared once consumed so the same tap can't re-navigate on every render.
    var deepLinkSessionID: String?

    /// Honour a deep link even if it lands before the fleet has synced — the
    /// id is held until a matching row shows up.
    func openSession(id: String) {
        deepLinkSessionID = id
        if !status.isReady { return }
        if session(id: id) == nil { refresh() }
    }

    func consumeDeepLink() { deepLinkSessionID = nil }

    // MARK: - Diff

    private(set) var diff: DiffResult?
    private(set) var diffLoading = false

    // MARK: - Terminal

    /// The session the host has been asked to stream. Confirmed state: cleared
    /// whenever the host connection resets, because the far end has forgotten.
    private(set) var attachedSessionID: String?
    /// The session the *view* is showing. Intent: survives a reconnect, and is
    /// what `reattachTerminalIfNeeded()` restores from.
    ///
    /// Splitting these is the fix for the frozen pane. Previously a reconnect
    /// cleared `attachedSessionID`, and nothing ever set it again — the detail
    /// view attaches from `.task(id: sessionID)`, and `sessionID` had not
    /// changed, so the pane sat on its last frame forever.
    private(set) var desiredSessionID: String?
    private(set) var terminalANSI: String = ""
    private(set) var terminalSeq: Int = 0
    /// Pages of history above the live pane, nearest-first. Index 0 is the
    /// screenful immediately above what you can see; the last element is the
    /// oldest fetched. The view renders them reversed.
    private(set) var scrollbackPages: [ScrollbackChunk] = []
    private(set) var scrollbackHasMore = true
    /// A fetch is outstanding. Gates the view's scroll-triggered loading, so
    /// dragging at the top edge asks once rather than once per frame.
    private(set) var scrollbackLoading = false
    private var scrollbackTimeout: Task<Void, Never>?
    /// When the last frame arrived, for the "as of" label.
    private(set) var lastFrameAt: Date?
    /// The grid the host reports it is drawing at, once it says so.
    private(set) var hostGrid: (cols: Int, rows: Int)?
    /// The grid this device wants, and the debounce that stops a pinch gesture
    /// from firing one SIGWINCH per frame at the Mac.
    private var desiredGrid: (cols: Int, rows: Int)?
    private var resizeDebounce: Task<Void, Never>?
    /// A resize the dialog guard turned away. Without this the pane would open
    /// desk-sized on a session that was blocked at attach time and stay that
    /// way forever — approving the dialog is exactly when it becomes safe to
    /// resize, and exactly when nothing else would think to try again.
    private var resizeDeferred = false
    /// When the outstanding `attach_terminal` went out, and whether it is still
    /// outstanding. An unanswered attach is the only sound evidence that a pane
    /// is broken rather than merely idle.
    private var lastAttachAt: Date?
    private var awaitingFirstFrame = false
    private var terminalWatchdog: Task<Void, Never>?

    /// True when the pane on screen cannot be trusted to be current: either the
    /// host connection is down, or an attach went out and nothing came back.
    ///
    /// Stored rather than computed on demand, because the interesting
    /// transition is *time passing* and nothing else. A computed property
    /// reading `Date()` would re-evaluate only when some other observed value
    /// changed — which, in a frozen pane, is precisely never.
    private(set) var terminalIsStale = false

    /// "12s", "8m" — how far behind the pane is.
    var terminalAge: String {
        ConnectionHealth.ageLabel(since: lastFrameAt, now: Date())
    }

    private func updateTerminalStaleness() {
        let stale: Bool
        if desiredSessionID == nil {
            stale = false
        } else if !status.isReady {
            stale = true
        } else if !awaitingFirstFrame {
            // A frame arrived. That, and only that, clears the judgement.
            stale = false
        } else if terminalIsStale {
            // Sticky on purpose. A re-attach resets `lastAttachAt`, so
            // recomputing from scratch here would clear the flag the instant
            // the watchdog retried — the bar would blink out of existence and
            // the give-up counter, which counts consecutive stale ticks, would
            // never reach its limit. Retrying is not evidence of health.
            stale = true
        } else {
            stale = ConnectionHealth.attachIsUnanswered(sentAt: lastAttachAt, now: Date())
        }
        if stale != terminalIsStale { terminalIsStale = stale }
    }

    // MARK: - Components

    let voice: VoiceSession
    let meetingStore: MeetingStore
    private let socket: RelaySocket
    private let auth0: Auth0Manager
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "bridge")
    private var handshakeTimeout: Task<Void, Never>?

    init(auth0: Auth0Manager, meetingStore: MeetingStore) {
        self.auth0 = auth0
        self.meetingStore = meetingStore
        self.socket = RelaySocket(auth0: auth0)
        self.voice = VoiceSession()
        // Anything recorded on this device is known before a host ever answers;
        // the list must not start empty and fill in only if a Mac shows up.
        self.meetings = meetingStore.localMeetings

        socket.onStateChange = { [weak self] state in self?.handleSocketState(state) }
        socket.onPayload = { [weak self] payload, instanceID in
            self?.handlePayload(payload, from: instanceID)
        }
        socket.onRelayDirect = { [weak self] json in self?.handleRelayDirect(json) }

        // The voice layer needs a way back onto the wire for tool calls.
        voice.onToolCall = { [weak self] callID, name, params in
            self?.send(.toolCall(callID: callID, name: name, parameters: params))
        }
        voice.onEnded = { [weak self] in
            self?.send(.voiceRelease)
        }
    }

    // MARK: - Lifecycle

    func connect() async {
        await socket.connect()
    }

    func disconnect() {
        socket.disconnect()
        voice.teardown()
        forgetTerminalIntent()
        resetHostState()
        status = .disconnected
    }

    func retry() async {
        lastError = nil
        await socket.retry()
    }

    /// The user-facing "this is stuck, fix it" lever. Throws away the socket
    /// and everything derived from it and starts over, without waiting out a
    /// backoff — someone tapping this has already waited.
    func hardReconnect() async {
        lastError = nil
        resetHostState()
        status = .connecting
        await socket.retry()
    }

    // MARK: - App lifecycle
    //
    // The app holds no connection while backgrounded — iOS suspends the process
    // within seconds regardless, so pretending otherwise only costs battery for
    // the brief windows the OS does hand back. Everything here is about
    // returning cleanly: prove the socket, then restore what the user was
    // looking at.

    func appDidEnterBackground() {
        attentionPresence(nil)
        terminalWatchdog?.cancel()
        terminalWatchdog = nil
        socket.enterBackground()
    }

    func appWillEnterForeground() {
        socket.enterForeground()
        // If the socket turns out to be fine, nothing above will fire a state
        // change, so resync from here: fifteen minutes of deltas were missed
        // whether or not the connection survived.
        if status.isReady {
            refresh()
            reattachTerminalIfNeeded()
        }
        updateTerminalStaleness()
        startTerminalWatchdogIfNeeded()
    }

    private func handleSocketState(_ state: RelaySocket.State) {
        switch state {
        case .disconnected:
            status = .disconnected
            resetHostState()
        case .connecting:
            // A fresh socket means the relay has forgotten our subscription and
            // the host has forgotten our handshake. Drop the confirmed state so
            // the pairing flow runs again from the top; the intent fields
            // (`preferredInstanceID`, `desiredSessionID`) deliberately survive.
            status = .connecting
            resetHostState()
        case .connected:
            if activeInstanceID == nil { status = .awaitingHost }
        case .failed(let message):
            status = .failed(message)
            lastError = message
            voice.teardown()
            resetHostState()
        }
        updateTerminalStaleness()
    }

    /// Clears everything the *host* is authoritative for. Never touches intent:
    /// what the user picked has to outlive the connection that served it.
    private func resetHostState() {
        activeInstanceID = nil
        // Every host's feed goes: capabilities, sequences and sessions all
        // belonged to a connection that no longer exists.
        feeds.removeAll()
        videoHostID = nil
        videos = []
        videosLoading = false
        videoLibraryError = nil
        videoLoadTimeout?.cancel()
        videoTitleRollback.removeAll()
        videoDeleteRollback.removeAll()
        sessions = []
        hostStats.removeAll()
        statsLoadingIDs.removeAll()
        attachedSessionID = nil
        lastFrameAt = nil
        lastAttachAt = nil
        awaitingFirstFrame = false
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
    }

    // MARK: - Instance selection

    /// Switch hosts (MacBook ⇄ forge). Re-subscribes at the relay, clears fleet
    /// state and redoes the handshake — sessions from one host must never leak
    /// into another's board.
    func selectInstance(_ id: String) {
        guard id != activeInstanceID else { return }
        guard instances.contains(where: { $0.id == id && $0.isOnline }) else { return }

        if let attachedSessionID { send(.detachTerminal(id: attachedSessionID), forSession: attachedSessionID) }
        sessions = []
        diff = nil
        terminalANSI = ""
        // Paths belong to the machine that owns them. Leaving the Mac's recents
        // on screen while pointed at the box is not a cosmetic lag: tapping one
        // would start a session in a directory the box has never heard of.
        recentDirectories = []
        directoryListing = nil
        branchListing = nil
        // Libraries are host-owned too; `refresh()` refills them after the
        // handshake, and until then showing nothing beats showing the last
        // machine's.
        meetings = []
        videos = []
        agents = []
        // The pane's session belongs to the host we are leaving, so this one
        // intent does not survive — there is nothing on the new host to restore.
        desiredSessionID = nil
        terminalWatchdog?.cancel()
        terminalWatchdog = nil
        resetHostState()

        preferredInstanceID = id
        activeInstanceID = id
        status = .pairing
        socket.requestPairing(with: id)
    }

    private func handleRelayDirect(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "paired_instances":
            let list = (json["instances"] as? [[String: Any]]) ?? []
            instances = list.compactMap { entry in
                guard let id = entry["instanceId"] as? String else { return nil }
                return BridgeInstance(
                    id: id,
                    name: (entry["name"] as? String) ?? id,
                    machineName: entry["machineName"] as? String,
                    isOnline: (entry["isOnline"] as? Bool) ?? false,
                    kind: entry["kind"] as? String
                )
            }
            adoptFirstOnlineInstanceIfNeeded()
            syncSubscriptions()

        case "instance_online":
            guard let id = json["instanceId"] as? String else { return }
            let metadata = json["metadata"] as? [String: Any]
            upsertInstance(
                id: id,
                name: (metadata?["name"] as? String) ?? id,
                machineName: metadata?["machineName"] as? String,
                kind: metadata?["kind"] as? String,
                isOnline: true
            )
            adoptFirstOnlineInstanceIfNeeded()
            syncSubscriptions()

        case "instance_offline":
            guard let id = json["instanceId"] as? String else { return }
            if let idx = instances.firstIndex(where: { $0.id == id }) {
                instances[idx].isOnline = false
            }
            hostStats[id] = nil
            statsLoadingIDs.remove(id)
            syncVideoHost()
            if id == activeInstanceID {
                voice.teardown()
                resetHostState()
                sessions = []
                status = .awaitingHost
                adoptFirstOnlineInstanceIfNeeded()
                syncSubscriptions()
            }

        case "pair_success":
            // Any machine, not just the chosen one: the fleet is the unit now.
            // This used to answer with `set_active_instance`, which clears the
            // relay's whole subscription set — so pairing the second machine
            // silently unsubscribed the first, which is the single line that
            // made "one machine at a time" true.
            guard let id = json["instanceId"] as? String else { return }
            log.info("paired with \(id)")
            syncSubscriptions()

        case "pair_failed":
            let message = (json["error"] as? String) ?? "pairing failed"
            lastError = message
            status = .failed(message)

        case "active_instance_set":
            beginHandshake()

        case "device_registered":
            log.info("APNs device token registered with relay")

        case "error":
            lastError = (json["data"] as? String) ?? "relay error"

        default:
            break
        }
    }

    private func upsertInstance(id: String, name: String, machineName: String?, kind: String?, isOnline: Bool) {
        // A box that left the relay loses its charts. Resuming the line from
        // before the gap would draw a flat stretch across time nothing was
        // measured in, which is exactly the lie these charts exist to avoid.
        if !isOnline { history.forget(id: id) }
        if let idx = instances.firstIndex(where: { $0.id == id }) {
            // Never trade a name for an id. The relay's `instance_online`
            // broadcast carries `metadata: null`, so `name` arrives as the bare
            // instanceId — and overwriting with it renamed devbox to
            // "udha-00b891" the moment the agent restarted. The machine then
            // read as a stranger in the strip and in Machines, which looks
            // exactly like the box having disappeared.
            if name != id || instances[idx].name.isEmpty { instances[idx].name = name }
            instances[idx].isOnline = isOnline
            if let machineName { instances[idx].machineName = machineName }
            if let kind { instances[idx].kind = kind }
        } else {
            instances.append(BridgeInstance(id: id, name: name, machineName: machineName,
                                            isOnline: isOnline, kind: kind))
        }
    }

    /// v1 behaviour preserved: with nothing selected, adopt the first online
    /// host so a single-Mac setup needs no picker interaction.
    ///
    /// After a reconnect this is also the re-pairing path, which is why it
    /// prefers the host the user actually chose. Falling through to "first
    /// online" would quietly move a two-machine user to the wrong Mac every
    /// time their train went through a tunnel.
    private func adoptFirstOnlineInstanceIfNeeded() {
        guard activeInstanceID == nil else { return }
        let preferred = preferredInstanceID.flatMap { id in
            instances.first { $0.id == id && $0.isOnline }
        }
        guard let target = preferred ?? instances.first(where: { $0.isOnline }) else { return }
        // Only record a preference we did not already have. Overwriting it here
        // meant a host going offline rewrote the user's choice to whatever was
        // left, so closing the Mac for an hour permanently repointed a phone
        // that had deliberately picked the forge. Choosing is `selectInstance`'s
        // job; this path only fills the blank.
        if preferredInstanceID == nil { preferredInstanceID = target.id }
        activeInstanceID = target.id
        status = .pairing
        socket.requestPairing(with: target.id)
        // Everything else online is paired too. Sessions are the fleet's, not
        // one machine's, and a session you can see but not open is worse than
        // one you have to go and find.
        for other in instances where other.isOnline && other.id != target.id {
            socket.requestPairing(with: other.id)
        }
    }

    /// Tell the relay we want every machine, and greet each of them.
    ///
    /// Called whenever the fleet's membership changes. `subscribe_instances`
    /// replaces the relay's whole subscription set, so this is idempotent.
    private func syncSubscriptions() {
        let online = instances.filter(\.isOnline).map(\.id)
        guard !online.isEmpty else { return }
        socket.subscribe(to: online)
        // Drop feeds for machines that went away, so their sessions leave the
        // list with them rather than lingering as rows nothing can answer for.
        feeds = feeds.filter { online.contains($0.key) }
        hostLogins = hostLogins.filter { online.contains($0.key) }
        syncVideoHost()
        for id in online where feeds[id] == nil {
            feeds[id] = HostFeed()
            // Each machine gets its own handshake: capabilities differ, and a
            // headless box is not a Mac.
            send(.hello, to: id)
            send(.listSessionsFull, to: id)
        }
        rebuildSessions()
    }

    // MARK: - Handshake

    private func beginHandshake() {
        send(.hello)
        // A v1 desktop ignores `hello` entirely, so nothing will come back.
        // Fall forward after a beat rather than hanging on "Connecting…".
        handshakeTimeout?.cancel()
        handshakeTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.handshake == nil, self.activeInstanceID != nil else { return }
            self.log.info("no hello_ack — treating host as protocol 1")
            self.status = .ready
            self.refresh()
            self.reattachTerminalIfNeeded()
            self.updateTerminalStaleness()
        }
    }

    private func completeHandshake(_ ack: HelloAck, from instanceID: String) {
        var feed = feeds[instanceID] ?? HostFeed()
        feed.handshake = ack
        feed.lastSeq = nil
        feeds[instanceID] = feed

        if let idx = instances.firstIndex(where: { $0.id == instanceID }) {
            instances[idx].kind = ack.instanceKind
        }
        syncVideoHost()
        if ack.supportsAccounts { send(.fetchAccounts, to: instanceID.isEmpty ? nil : instanceID) }
        // A second machine answering does not change what the screen is doing;
        // only the host the user chose drives status and the initial refresh.
        guard instanceID.isEmpty || instanceID == activeInstanceID else {
            log.info("hello_ack from \(instanceID) caps=\(ack.capabilities.sorted().joined(separator: ","))")
            send(.listSessionsFull, to: instanceID)
            return
        }
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        status = .ready
        log.info("hello_ack protocol=\(ack.protocolVersion) caps=\(ack.capabilities.sorted().joined(separator: ","))")
        refresh()
        // The pane the user is looking at is part of "restore what was there",
        // not a separate concern the view will notice on its own.
        reattachTerminalIfNeeded()
        updateTerminalStaleness()
    }

    // MARK: - Sending

    private func send(_ message: BridgeOutbound) {
        #if DEBUG
        if let mockOutbound {
            mockOutbound(message.json)
            return
        }
        #endif
        guard let activeInstanceID else {
            log.debug("dropping \(String(describing: message)) — no active instance")
            return
        }
        socket.sendPayload(message.json, to: activeInstanceID)
    }

    /// Send to a named host rather than the active one.
    ///
    /// Every session-scoped verb goes through here now: with the fleet merged
    /// from several machines, the row decides the destination, not the tab.
    private func send(_ message: BridgeOutbound, to instanceID: String?) {
        guard let instanceID else { send(message); return }
        #if DEBUG
        if let mockOutbound {
            mockOutbound(message.json)
            return
        }
        #endif
        socket.sendPayload(message.json, to: instanceID)
    }

    /// Send to whichever machine is running this session.
    private func send(_ message: BridgeOutbound, forSession id: String) {
        send(message, to: instanceID(forSession: id))
    }

    func registerDeviceToken(_ token: String) {
        socket.registerDeviceToken(token)
    }

    /// Full resync. Also the v1 poll path and the delta-gap recovery path.
    func refresh() {
        guard status.isReady else { return }
        // Sessions from every machine; recents, meetings, videos and agents
        // from the one the user chose, because those are that machine's.
        for id in feeds.keys { send(.listSessionsFull, to: id) }
        if feeds.isEmpty { send(.listSessionsFull) }
        send(.listRecentDirs)
        send(.listMeetings)
        listVideos()
        send(.listAgents)
        // Connect, foreground and pull-to-refresh all land here, which makes
        // this the one place a backlog of phone recordings reliably drains.
        flushOutbox()
    }

    /// Asks every connected host that reports vitals for them.
    ///
    /// Deliberately not part of `refresh()`: collecting them shells out to
    /// `nvidia-smi`, `docker ps` and friends on the host, which is far too much
    /// work to run on every foreground. The Machines screen asks when it opens
    /// and when you pull it down, and nothing else asks at all.
    func refreshStats() {
        guard status.isReady else { return }
        #if DEBUG
        if mockOutbound != nil {
            if let id = activeInstanceID { statsLoadingIDs.insert(id) }
            send(.fetchStats)
            return
        }
        #endif
        for instance in instances where isConnected(instance.id) && canReportStats(instance.id) {
            statsLoadingIDs.insert(instance.id)
            send(.fetchStats, to: instance.id)
        }
    }

    /// Called by a Machines view appearing. Balanced by `removeStatsViewer`.
    ///
    /// Five seconds: fast enough that a sparkline has shape by the time you have
    /// read the numbers under it, slow enough that a box is not collecting
    /// vitals more often than it would for its own desktop.
    func addStatsViewer() {
        statsViewers += 1
        guard statsPoll == nil else { return }
        refreshStats()
        statsPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.statsViewers > 0 else { return }
                self.refreshStats()
            }
        }
    }

    func removeStatsViewer() {
        statsViewers = max(statsViewers - 1, 0)
        guard statsViewers == 0 else { return }
        statsPoll?.cancel()
        statsPoll = nil
    }

    // MARK: - Inbound

    private func handlePayload(_ payload: [String: Any], from instanceID: String) {
        // The source host, resolved once. An empty id means the mock or a relay
        // frame that predates per-instance tagging: treat it as the active one.
        let source = instanceID.isEmpty ? (activeInstanceID ?? "") : instanceID
        // Sessions arrive from every subscribed machine; everything else is the
        // active host's business and is ignored from anywhere else, so a second
        // machine cannot overwrite the meetings or vitals you are looking at.
        let isActive = source.isEmpty || source == activeInstanceID

        switch BridgeDecoder.decode(payload: payload) {
        case .helloAck(let ack):
            completeHandshake(ack, from: source)

        case .sessionsFull(let rows, let folders):
            var feed = feeds[source] ?? HostFeed()
            feed.sessions = rows
            feed.folders = folders
            feed.lastSeq = nil
            feed.syncedAt = Date()
            feeds[source] = feed
            lastSyncedAt = feed.syncedAt
            rebuildSessions()
            retryDeferredResizeIfPossible()

        case .sessionsDelta(let seq, let changed, let removed):
            applyDelta(from: source, seq: seq, changed: changed, removed: removed)

        case .quickCommands(let commands):
            if !commands.isEmpty { quickCommands = commands }

        case .sessionCreated(let id, _, _):
            lastSessionError = nil
            isCreatingSession = false
            lastCreatedSessionID = id.isEmpty ? nil : id

        case .sessionCreateFailed(let error):
            lastSessionError = error
            isCreatingSession = false

        case .sessionClosed(let id):
            for key in feeds.keys { feeds[key]?.sessions.removeAll { $0.id == id } }
            rebuildSessions()
            // The session is gone for good, so the *intent* to watch it goes
            // too — otherwise every later reconnect would re-attach to a
            // session the host has already forgotten.
            if attachedSessionID == id { attachedSessionID = nil }
            if desiredSessionID == id { forgetTerminalIntent() }

        case .sessionCloseFailed(let error):
            lastSessionError = error

        case .directoryListing(let listing):
            directoryListing = listing

        case .recentDirs(let dirs):
            recentDirectories = dirs

        case .branches(let listing):
            branchListing = listing

        case .actionResult(let result):
            if ["rename_video", "delete_video"].contains(result.action), source != videoHostID { return }
            handleActionResult(result)

        case .diffResult(let result):
            diffLoading = false
            diff = result

        case .terminalFrame(let frame):
            guard frame.sessionID == attachedSessionID else { return }
            terminalANSI = frame.ansi
            terminalSeq = frame.seq
            // The attach has been answered: the pane is live again, and the
            // watchdog can go back to sleep.
            lastFrameAt = Date()
            awaitingFirstFrame = false
            if let cols = frame.cols, let rows = frame.rows {
                hostGrid = (cols, rows)
            }
            updateTerminalStaleness()

        case .scrollbackChunk(let chunk):
            guard chunk.sessionID == attachedSessionID else { return }
            scrollbackLoading = false
            scrollbackTimeout?.cancel()
            scrollbackTimeout = nil
            // An empty page means we have reached the top of what tmux kept.
            if !chunk.ansi.isEmpty { scrollbackPages.append(chunk) }
            scrollbackHasMore = chunk.more && !chunk.ansi.isEmpty
            log.info("scrollback page offset=\(chunk.offset) pages=\(self.scrollbackPages.count) more=\(self.scrollbackHasMore)")

        case .ptyAttached, .ptyOutput, .ptyExited:
            // WS-3 §4.3 — the PTY channel lands with the SwiftTerm view.
            break

        case .meetingsFull(let list):
            rebuildMeetings(hostList: list)
            liveMeetingID = list.first { $0.isRecording }?.id

        case .meetingDetail(let meeting):
            applyHostDetail(meeting)

        case .meetingLive(let id, let elapsed, let segments):
            liveMeetingID = id
            liveElapsedSec = elapsed
            liveTranscript.append(contentsOf: segments)

        case .meetingStopped(let id):
            if liveMeetingID == id {
                liveMeetingID = nil
                liveElapsedSec = 0
                liveTranscript = []
            }
            send(.listMeetings)

        case .meetingAskReply(_, let text):
            askPending = false
            askTimeout?.cancel()
            askTimeout = nil
            askThread.append(MeetingAskTurn(role: .udha, text: text))

        case .localMeetingAck(let id, let ok, let error):
            if ok {
                meetingStore.setSyncState(.synced, for: id)
                upsertSyncState(.synced, for: id)
                // The host summarises on receipt; ask for the result rather
                // than waiting for the next full list.
                send(.fetchMeeting(id: id))
            } else {
                log.error("host rejected meeting \(id): \(error ?? "no reason given")")
                meetingStore.setSyncState(.failed, for: id)
                upsertSyncState(.failed, for: id)
            }

        case .videosFull(let list):
            guard source == videoHostID else { return }
            videos = list
            videosLoading = false
            videoLibraryError = nil
            videoLoadTimeout?.cancel()

        case .agentsFull(let list):
            agents = list

        case .agentStarted:
            send(.listSessionsFull)

        case .accounts(let hostLogins):
            self.hostLogins[source] = hostLogins

        case .stats(let stats):
            guard !source.isEmpty else { return }
            statsLoadingIDs.remove(source)
            hostStats[source] = stats
            history.record(stats, for: source)

        case .attachmentStaged(let sessionID, let token, let path, let name, let error):
            applyAttachmentStaged(sessionID: sessionID, token: token,
                                  path: path, name: name, error: error)

        case .homeInfo(let name, let machineName, let kind):
            guard let id = activeInstanceID else { return }
            upsertInstance(id: id, name: name ?? id, machineName: machineName,
                           kind: kind, isOnline: true)

        case .voiceClaimResponse(let result):
            voice.handleClaimResponse(result)

        case .voiceState:
            break

        case .toolResult(let callID, let result, let isError):
            voice.deliverToolResult(callID: callID, result: result, isError: isError)

        case .unknown(let type):
            log.debug("unhandled payload type=\(type)")
        }
    }

    /// Merge a delta into the fleet, resyncing if the sequence skipped.
    private func applyDelta(from instanceID: String,
                            seq: Int, changed: [SessionRow], removed: [String]) {
        var feed = feeds[instanceID] ?? HostFeed()
        if let last = feed.lastSeq, seq != last + 1 {
            log.info("delta gap on \(instanceID): expected \(last + 1), got \(seq) — resyncing")
            feed.lastSeq = nil
            feeds[instanceID] = feed
            send(.listSessionsFull, to: instanceID)
            return
        }
        feed.lastSeq = seq
        feed.syncedAt = Date()

        for row in changed {
            if let idx = feed.sessions.firstIndex(where: { $0.id == row.id }) {
                // In place: replacing keeps the host's ordering. Removing and
                // re-appending would drift the list on every phase change.
                feed.sessions[idx] = row
            } else {
                // Genuinely new — the host appends too, so the tail matches.
                feed.sessions.append(row)
            }
        }
        if !removed.isEmpty {
            let goneHere = Set(removed)
            feed.sessions.removeAll { goneHere.contains($0.id) }
        }
        feeds[instanceID] = feed
        lastSyncedAt = feed.syncedAt
        rebuildSessions()
        retryDeferredResizeIfPossible()

        if !removed.isEmpty {
            let gone = Set(removed)
            if let attachedSessionID, gone.contains(attachedSessionID) {
                self.attachedSessionID = nil
            }
            if let desiredSessionID, gone.contains(desiredSessionID) {
                forgetTerminalIntent()
            }
        }
    }

    private func handleActionResult(_ result: ActionResult) {
        if let id = result.sessionID { pendingActions.remove(id) }
        if result.action == "rename_session", let id = result.sessionID,
           let previous = renameRollback.removeValue(forKey: id), !result.ok,
           let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].label = previous
        }
        if result.action == "rename_video", let id = result.sessionID,
           let previous = videoTitleRollback.removeValue(forKey: id), !result.ok,
           let index = videos.firstIndex(where: { $0.id == id }) {
            videos[index].title = previous
        }
        if result.action == "delete_video", let id = result.sessionID,
           let undo = videoDeleteRollback.removeValue(forKey: id), !result.ok,
           !videos.contains(where: { $0.id == id }) {
            videos.insert(undo.video, at: min(undo.index, videos.count))
        }
        if result.ok {
            lastActionError = nil
        } else {
            lastActionError = result.error ?? "\(result.action) failed"
            log.error("action \(result.action) failed: \(result.error ?? "unknown")")
        }
    }

    func clearActionError() { lastActionError = nil }

    // MARK: - Session management

    func createSession(
        directory: String,
        label: String?,
        prompt: String? = nil,
        tool: SessionTool? = nil,
        permission: PermissionMode? = nil,
        worktree: BridgeOutbound.WorktreeSpec? = nil,
        folder: String? = nil
    ) {
        guard status.isReady else {
            lastSessionError = "Not connected to a host"
            return
        }
        lastSessionError = nil
        lastCreatedSessionID = nil
        isCreatingSession = true
        send(.createSession(directory: directory, label: label, prompt: prompt, tool: tool,
                            permission: permission, worktree: worktree, folder: folder))
    }

    func duplicateSession(id: String) {
        guard status.isReady else {
            lastSessionError = "Not connected to a host"
            return
        }
        lastSessionError = nil
        lastCreatedSessionID = nil
        isCreatingSession = true
        send(.duplicateSession(id: id), forSession: id)
    }

    /// Renames a session on the host, and here at once so the list does not
    /// sit on the old name for a round trip.
    ///
    /// The host stays the authority: its delta overwrites this a moment later,
    /// and it may come back with a *different* name than the one asked for —
    /// the Mac appends a numeric suffix when the label is already taken, which
    /// is what keeps renaming from breaking voice matching by label. A refusal
    /// puts the old name back rather than leaving one on screen that only this
    /// device believes in.
    func renameSession(id: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let previous = sessions[index].label
        guard !trimmed.isEmpty, trimmed != previous else { return }
        guard status.isReady else {
            lastActionError = "Not connected to a host"
            return
        }
        guard canRenameSessions else {
            lastActionError = "This host is too old to rename sessions"
            return
        }
        renameRollback[id] = previous
        sessions[index].label = trimmed
        markPending(id)
        send(.renameSession(id: id, label: trimmed), forSession: id)
    }

    /// Removes the session outright — kills it and deletes it from the Mac's
    /// session list. `killSession` is the softer one that keeps the label.
    func closeSession(id: String) {
        send(.closeSession(id: id), forSession: id)
    }

    /// Kills the process but leaves the entry, matching the Mac's "Terminate".
    func killSession(id: String) {
        markPending(id)
        send(.killSession(id: id, confirm: true), forSession: id)
    }

    // MARK: - Folders + hidden + order

    // Every edit here is applied to the local feed first and sent second, so
    // the list moves under your finger rather than a round trip later. The
    // host stays the authority: each verb is answered by a coalesced
    // `sessions_full` that overwrites the local copy, and a refusal comes
    // back as an `action_result` the ordinary error path surfaces. Nothing
    // is rolled back by hand — the next full push *is* the rollback.

    /// The folders a machine keeps, in that machine's order. Nil means the
    /// active host, which is what a machine group with no rows of its own is.
    func folders(onInstance instanceID: String?) -> [SessionFolder] {
        guard let id = instanceID ?? activeInstanceID else { return [] }
        return feeds[id]?.folders ?? []
    }

    /// The folders on the machine running `row`.
    func folders(for row: SessionRow) -> [SessionFolder] {
        guard canDrive(row) else { return [] }
        return folders(onInstance: row.instanceID)
    }

    func folder(id: String, onInstance instanceID: String?) -> SessionFolder? {
        folders(onInstance: instanceID).first { $0.id == id }
    }

    /// Whether folder actions are offered on a machine: the Mac always, a box
    /// only once its agent speaks `folders`. Optimistic before the handshake
    /// lands, for the same reason MATCH is.
    func canUseFolders(onInstance instanceID: String?) -> Bool {
        guard let id = instanceID ?? activeInstanceID else { return false }
        guard let ack = feeds[id]?.handshake else { return true }
        return ack.supportsFolders
    }

    func canUseFolders(_ row: SessionRow) -> Bool {
        canDrive(row) && canUseFolders(onInstance: row.instanceID)
    }

    // MARK: - Claude logins

    /// The login a session runs under and every login its tree has, read from
    /// the machine that owns the pool. Nil for a non-Claude session, or one
    /// whose host has said nothing about logins. A host that has not answered
    /// `fetch_accounts` yet still gets a name-only entry from the row.
    func logins(for row: SessionRow) -> (current: ClaudeLogin?, members: [ClaudeLogin])? {
        guard row.isClaudeTUI else { return nil }
        let host = hostLogins[row.instanceID ?? activeInstanceID ?? ""]
        if let pool = host?.pool(for: row.directory), !pool.members.isEmpty {
            let current = pool.members.first { $0.name == row.account } ?? (row.account == nil ? pool.members.first : nil)
            return (current, pool.members)
        }
        if let login = host?.defaultLogin, row.account == nil || row.account == login.name {
            return (login, [login])
        }
        guard let account = row.account else { return nil }
        let only = ClaudeLogin(dir: account, name: account)
        return (only, [only])
    }

    /// Whether this session can be moved to another Claude login from here.
    func canSwitchLogin(_ row: SessionRow) -> Bool {
        canDrive(row) && (handshake(for: row)?.supportsAccounts ?? false)
            && (logins(for: row)?.members.count ?? 0) > 1
    }

    /// Moves a session to another login in its pool, keeping the conversation.
    /// `dir` nil lets the host pick the emptiest. The row's `account` echoes
    /// the result; a refusal comes back as an `action_result` error.
    func switchLogin(sessionID: String, to dir: String?) {
        guard status.isReady else {
            lastActionError = "Not connected to a host"
            return
        }
        markPending(sessionID)
        send(.rotateAccount(id: sessionID, to: dir), forSession: sessionID)
    }

    /// Re-asks every machine that keeps login pools for fresh headroom.
    func refreshLogins() {
        for (id, feed) in feeds where feed.handshake?.supportsAccounts == true {
            send(.fetchAccounts, to: id)
        }
    }

    /// Hidden itself, or filed in a hidden folder. A `folderID` the machine's
    /// list does not know reads as loose, the same rule the desktop applies.
    func isVisible(_ row: SessionRow) -> Bool {
        if row.hidden { return false }
        guard let f = row.folderID else { return true }
        return !(folder(id: f, onInstance: row.instanceID)?.hidden ?? false)
    }

    /// The fleet minus what is hidden — what the list draws.
    var visibleSessions: [SessionRow] { sessions.filter(isVisible) }

    /// What the "N folders and M sessions hidden" footer counts, across every
    /// machine: hidden folders, plus every session out of sight for either
    /// reason.
    var hiddenCounts: (folders: Int, sessions: Int) {
        (feeds.values.flatMap(\.folders).filter(\.hidden).count,
         sessions.count - visibleSessions.count)
    }

    /// Which folders are folded shut on this device. Screen space is this
    /// device's business, so it never goes on the wire — the desktop keeps its
    /// own in its own config for the same reason.
    private(set) var collapsedFolderIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "udha.collapsedFolders") ?? [])

    func isExpanded(_ folder: SessionFolder) -> Bool { !collapsedFolderIDs.contains(folder.id) }

    func toggle(_ folder: SessionFolder) {
        if collapsedFolderIDs.contains(folder.id) { collapsedFolderIDs.remove(folder.id) }
        else { collapsedFolderIDs.insert(folder.id) }
        UserDefaults.standard.set(Array(collapsedFolderIDs), forKey: "udha.collapsedFolders")
    }

    private func expand(_ folderID: String) {
        guard collapsedFolderIDs.remove(folderID) != nil else { return }
        UserDefaults.standard.set(Array(collapsedFolderIDs), forKey: "udha.collapsedFolders")
    }

    /// Edit one machine's feed in place and rebuild the fleet from it.
    private func mutateFeed(_ instanceID: String?, _ edit: (inout HostFeed) -> Void) {
        guard let id = instanceID ?? activeInstanceID else { return }
        var feed = feeds[id] ?? HostFeed()
        edit(&feed)
        feeds[id] = feed
        rebuildSessions()
    }

    /// File a session in a folder on its own machine; nil takes it out.
    func setFolder(sessionID id: String, folderID: String?) {
        guard let row = session(id: id), canUseFolders(row) else { return }
        if let folderID, folder(id: folderID, onInstance: row.instanceID) == nil { return }
        guard row.folderID != folderID else { return }
        mutateFeed(row.instanceID) { feed in
            if let i = feed.sessions.firstIndex(where: { $0.id == id }) { feed.sessions[i].folderID = folderID }
        }
        // Filing something into a folded folder and then not seeing it land
        // reads as the move having failed.
        if let folderID { expand(folderID) }
        send(.setSessionFolder(id: id, folder: folderID), forSession: id)
    }

    func setHidden(sessionID id: String, hidden: Bool) {
        guard let row = session(id: id), canUseFolders(row) else { return }
        mutateFeed(row.instanceID) { feed in
            if let i = feed.sessions.firstIndex(where: { $0.id == id }) { feed.sessions[i].hidden = hidden }
        }
        send(.setSessionHidden(id: id, hidden: hidden), forSession: id)
    }

    /// Make a folder at the top of a machine's list, the way the desktop
    /// does, and answer with its id so the caller can file something in it
    /// before the host's push arrives.
    @discardableResult
    func createFolder(name: String, onInstance instanceID: String?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, status.isReady, canUseFolders(onInstance: instanceID) else { return nil }
        let id = UUID().uuidString
        mutateFeed(instanceID) { $0.folders.insert(SessionFolder(id: id, name: name), at: 0) }
        send(.createFolder(id: id, name: name), to: instanceID ?? activeInstanceID)
        return id
    }

    func renameFolder(id: String, to name: String, onInstance instanceID: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let current = folder(id: id, onInstance: instanceID), current.name != name else { return }
        mutateFeed(instanceID) { feed in
            if let i = feed.folders.firstIndex(where: { $0.id == id }) { feed.folders[i].name = name }
        }
        send(.renameFolder(id: id, name: name), to: instanceID ?? activeInstanceID)
    }

    /// "Ungroup": the folder goes and its sessions land loose, in the places
    /// they already held in the machine's order.
    func deleteFolder(id: String, onInstance instanceID: String?) {
        guard folder(id: id, onInstance: instanceID) != nil else { return }
        mutateFeed(instanceID) { feed in
            feed.folders.removeAll { $0.id == id }
            for i in feed.sessions.indices where feed.sessions[i].folderID == id { feed.sessions[i].folderID = nil }
        }
        send(.deleteFolder(id: id), to: instanceID ?? activeInstanceID)
    }

    func setFolderHidden(id: String, hidden: Bool, onInstance instanceID: String?) {
        guard folder(id: id, onInstance: instanceID) != nil else { return }
        mutateFeed(instanceID) { feed in
            if let i = feed.folders.firstIndex(where: { $0.id == id }) { feed.folders[i].hidden = hidden }
        }
        send(.setFolderHidden(id: id, hidden: hidden), to: instanceID ?? activeInstanceID)
    }

    /// Move a folder one place up or down in its machine's list. The whole
    /// order goes back, the same way the desktop's drag sends it.
    func nudgeFolder(id: String, up: Bool, onInstance instanceID: String?) {
        let ids = folders(onInstance: instanceID).map(\.id)
        let next = SessionFolder.nudged(ids, moving: id, up: up)
        guard next != ids else { return }
        mutateFeed(instanceID) { feed in
            let byID = Dictionary(uniqueKeysWithValues: feed.folders.map { ($0.id, $0) })
            feed.folders = next.compactMap { byID[$0] }
        }
        send(.reorderFolders(order: next), to: instanceID ?? activeInstanceID)
    }

    /// Move a session one place up or down among the rows it is listed with —
    /// the other members of its folder, or the other loose rows. The order
    /// sent back is the machine's whole list, with only those two swapped,
    /// so nothing else on the board moves.
    func nudgeSession(id: String, up: Bool) {
        guard let row = session(id: id), canDrive(row),
              let instanceID = row.instanceID, let feed = feeds[instanceID] else { return }
        let all = feed.sessions.map(\.id)
        let siblings = feed.sessions.filter { $0.folderID == row.folderID && isVisible($0) }.map(\.id)
        let moved = SessionFolder.nudged(siblings, moving: id, up: up)
        guard moved != siblings, let j = moved.firstIndex(of: id) else { return }
        // Swap the two in the full list so folder members and loose rows keep
        // their interleaving.
        let other = siblings[j]
        guard let a = all.firstIndex(of: id), let b = all.firstIndex(of: other) else { return }
        var next = all
        next.swapAt(a, b)
        mutateFeed(instanceID) { feed in
            let byID = Dictionary(uniqueKeysWithValues: feed.sessions.map { ($0.id, $0) })
            feed.sessions = next.compactMap { byID[$0] }
        }
        send(.reorderSessions(order: next), to: instanceID)
    }

    /// Bring back every hidden folder and session, on every machine that
    /// keeps folders.
    func unhideAll() {
        for id in feeds.keys where canUseFolders(onInstance: id) {
            mutateFeed(id) { feed in
                for i in feed.folders.indices { feed.folders[i].hidden = false }
                for i in feed.sessions.indices { feed.sessions[i].hidden = false }
            }
            send(.unhideAll, to: id)
        }
    }

    func listDirectory(path: String, showHidden: Bool = false) {
        send(.listDirectory(path: path, showHidden: showHidden))
    }

    func listRecentDirectories() {
        send(.listRecentDirs)
    }

    /// Branches of the repo behind `directory`, for the worktree base picker.
    func listBranches(in directory: String) {
        branchListing = nil
        send(.listBranches(directory: directory))
    }

    func clearSessionError() { lastSessionError = nil }

    /// Called once the shell has navigated to the newly created session, so a
    /// later fleet refresh doesn't yank the user back to it.
    func clearLastCreated() { lastCreatedSessionID = nil }

    // MARK: - Actions (WS-2)

    func sendInput(to id: String, text: String, submit: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        markPending(id)
        send(.sendInput(id: id, text: trimmed, submit: submit), forSession: id)
    }

    /// Raw tmux keys. Validated here so an obviously bad sequence never leaves
    /// the device; the host re-validates because a client is not a trust boundary.
    // MARK: - Attachments

    func attachments(for sessionID: String) -> [SessionAttachment] {
        attachments[sessionID] ?? []
    }

    /// True while any image for this session is still being staged. The send
    /// control reads it: a prompt naming a path the host has not written yet
    /// reaches Claude as a missing file.
    func isStagingAttachment(for sessionID: String) -> Bool {
        attachments(for: sessionID).contains { $0.isInFlight }
    }

    /// Shrink, encode and send one picked image. The chip appears immediately in
    /// its in-flight state — the encode happens off the main actor, and a
    /// screenshot from a phone library is big enough that doing it inline would
    /// drop frames on the sheet dismissing behind it.
    func stageAttachment(for sessionID: String, data: Data, name: String) {
        guard canStageAttachments else {
            lastActionError = "This host cannot take images. Update Udha on it."
            return
        }
        let token = UUID().uuidString
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                (image: AttachmentEncoder.prepare(data, name: name),
                 thumb: AttachmentEncoder.thumbnail(data))
            }.value
            guard let image = prepared.image else {
                self.lastActionError = "That file is not an image this app can read."
                return
            }
            self.attachments[sessionID, default: []].append(
                SessionAttachment(id: token,
                                  sessionID: sessionID,
                                  name: image.name,
                                  thumbnail: prepared.thumb,
                                  byteCount: image.data.count)
            )
            self.log.info("staging \(image.name) — \(image.data.count) bytes for \(sessionID)")
            self.send(.putAttachment(id: sessionID,
                                     token: token,
                                     name: image.name,
                                     mime: image.mime,
                                     base64: image.data.base64EncodedString()))
            self.failAttachmentIfUnanswered(token: token, in: sessionID)
        }
    }

    /// A chip that never hears back must not sit there spinning with Send
    /// disabled behind it. The send itself is fire-and-forget — a socket that
    /// died mid-upload reports through its own path, not this one — so the only
    /// honest way to end the wait is to time it.
    private func failAttachmentIfUnanswered(token: String, in sessionID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self,
                  let index = self.attachments[sessionID]?.firstIndex(where: { $0.id == token }),
                  self.attachments[sessionID]?[index].isInFlight == true
            else { return }
            self.attachments[sessionID]?[index].failure = "the host never answered — tap × and try again"
            self.log.error("attachment \(token) timed out waiting for the host")
        }
    }

    func removeAttachment(_ token: String, from sessionID: String) {
        attachments[sessionID]?.removeAll { $0.id == token }
        if attachments[sessionID]?.isEmpty == true { attachments[sessionID] = nil }
    }

    /// Called once the prompt carrying these paths has gone to the session.
    func clearAttachments(for sessionID: String) {
        attachments[sessionID] = nil
    }

    private func applyAttachmentStaged(sessionID: String?, token: String,
                                      path: String?, name: String?, error: String?) {
        // The reply carries the session, but a failure before the host could
        // resolve one does not — so fall back to finding the token wherever it
        // is, rather than dropping the answer and leaving a chip spinning.
        let key = sessionID ?? attachments.first { $0.value.contains { $0.id == token } }?.key
        guard let key, let index = attachments[key]?.firstIndex(where: { $0.id == token }) else {
            log.debug("attachment_staged for an unknown token")
            return
        }
        if let error {
            attachments[key]?[index].failure = error
            lastActionError = "Image not staged: \(error)"
            log.error("attachment staging failed: \(error)")
        } else if let path {
            attachments[key]?[index].path = path
            log.info("attachment staged at \(path)")
        }
        _ = name
    }

    func sendKeys(to id: String, keys: [String]) {
        guard TmuxKey.validate(keys) else {
            lastActionError = "Invalid key sequence"
            return
        }
        markPending(id)
        send(.sendKeys(id: id, keys: keys), forSession: id)
    }

    func interrupt(_ id: String) {
        markPending(id)
        send(.interrupt(id: id), forSession: id)
    }

    /// Only meaningful while a dialog is on screen. The host rejects it
    /// otherwise, which is what stops a stale card from firing keystrokes into
    /// a session that has already moved on.
    func approve(_ id: String, option: Int? = nil) {
        markPending(id)
        send(.approve(id: id, option: option), forSession: id)
    }

    func deny(_ id: String) {
        markPending(id)
        send(.deny(id: id), forSession: id)
    }

    func run(_ command: QuickCommand, on id: String) {
        if let keys = command.keys, !keys.isEmpty {
            sendKeys(to: id, keys: keys)
        } else if let text = command.text, !text.isEmpty {
            sendInput(to: id, text: text)
        }
    }

    private func markPending(_ id: String) {
        pendingActions.insert(id)
        // Nothing guarantees an `action_result` from a v1 host, so expire the
        // spinner rather than leaving a card stuck mid-action forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.pendingActions.remove(id)
        }
    }

    // MARK: - Diff

    func fetchDiff(for id: String, mode: DiffMode) {
        diffLoading = true
        diff = nil
        send(.fetchDiff(id: id, mode: mode, path: nil), forSession: id)
    }

    func clearDiff() {
        diff = nil
        diffLoading = false
    }

    // MARK: - Terminal

    func attachTerminal(to id: String) {
        if let attachedSessionID, attachedSessionID != id {
            send(.detachTerminal(id: attachedSessionID), forSession: attachedSessionID)
        }
        desiredSessionID = id
        attachedSessionID = id
        terminalANSI = ""
        terminalSeq = 0
        scrollbackPages = []
        scrollbackHasMore = true
        scrollbackLoading = false
        scrollbackTimeout?.cancel()
        scrollbackTimeout = nil
        lastFrameAt = nil
        lastAttachAt = Date()
        awaitingFirstFrame = true
        // Opening a pane is a fresh question, so the previous verdict — which
        // is otherwise sticky — is retired here.
        terminalIsStale = false
        // Carry the grid on the attach itself: the host applies it there, so a
        // pane opens at the right width instead of arriving wrong and being
        // corrected a beat later.
        let grid = attachGrid()
        send(.attachTerminal(id: id, cols: grid?.cols, rows: grid?.rows), forSession: id)
        updateTerminalStaleness()
        startTerminalWatchdogIfNeeded()
    }

    func detachTerminal() {
        terminalWatchdog?.cancel()
        terminalWatchdog = nil
        desiredSessionID = nil
        lastFrameAt = nil
        lastAttachAt = nil
        awaitingFirstFrame = false
        hostGrid = nil
        resizeDeferred = false
        resizeDebounce?.cancel()
        resizeDebounce = nil
        updateTerminalStaleness()
        guard let attachedSessionID else { return }
        send(.detachTerminal(id: attachedSessionID), forSession: attachedSessionID)
        self.attachedSessionID = nil
        terminalANSI = ""
        scrollbackPages = []
        scrollbackLoading = false
        scrollbackTimeout?.cancel()
        scrollbackTimeout = nil
    }

    // MARK: - Terminal sizing

    /// Tell the host what character grid this device can show.
    ///
    /// Sizing the Mac to the phone is the only way the text comes out right.
    /// The alternative — take a pane laid out for 362 columns and re-wrap it
    /// here — cannot work: the TUI has already drawn its boxes, columns and
    /// alignment for the width it was given, and re-wrapping rendered output
    /// produces rubble.
    ///
    /// Safe to call on every layout pass. Nothing leaves the device unless the
    /// integer grid actually changed, and even then not for `resizeSettleDelay`.
    func setTerminalGrid(cols: Int, rows: Int) {
        // Record first, gate second. The grid is a property of *this screen*,
        // not of whatever session happens to be attached — and the view reports
        // it from `onAppear`, which SwiftUI runs before the detail view's
        // `.task` has attached anything. Guarding the measurement on a session
        // threw away the only reading we ever got, so the pane opened at the
        // fallback size and nothing later corrected it.
        //
        // Optionals of tuples have no ==, so compare the unwrapped pair.
        let grid = (cols: cols, rows: rows)
        if let current = desiredGrid, current == grid { return }
        desiredGrid = grid

        guard matchHostToScreen,
              attachedCanResize,
              desiredSessionID != nil else { return }

        // A pinch gesture changes the grid on every frame. Coalesce, because
        // each resize the host applies is a SIGWINCH and a full TUI repaint at
        // the other end — the Mac would strobe.
        resizeDebounce?.cancel()
        resizeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ConnectionHealth.resizeSettleDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flushTerminalGrid()
        }
    }

    private func flushTerminalGrid() {
        guard let grid = desiredGrid, let id = desiredSessionID, status.isReady else { return }
        // The machine running this session, not whichever one the app is
        // pointed at: a devbox pane was gated on the Mac's capabilities, so
        // MATCH could be on and still silently do nothing.
        guard attachedCanResize else { return }
        // Resizing repaints the TUI. Doing that under a permission dialog the
        // user is reaching for is how a "yes" lands on the wrong option — the
        // host refuses too, but not sending it keeps the intent honest.
        guard session(id: id)?.phase != .awaitingApproval else {
            resizeDeferred = true
            log.info("deferring resize to \(grid.cols)x\(grid.rows) — dialog on screen")
            return
        }
        resizeDeferred = false
        log.info("requesting host grid \(grid.cols)x\(grid.rows)")
        send(.resizeTerminal(id: id, cols: grid.cols, rows: grid.rows), forSession: id)
    }

    /// Whether this device asks the host to match its screen. Off by default:
    /// it reshapes a window on someone's desk, which is not something to do
    /// because an app was merely opened.
    var matchHostToScreen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.matchScreenKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.matchScreenKey)
            if newValue {
                // Re-send whatever the view last measured; `setTerminalGrid`
                // short-circuits on an unchanged grid, so clear it first.
                let grid = desiredGrid
                desiredGrid = nil
                if let grid { setTerminalGrid(cols: grid.cols, rows: grid.rows) }
            } else if let id = desiredSessionID, status.isReady {
                // Give the Mac its window back immediately rather than at
                // detach — the toggle going off is the whole request.
                desiredGrid = nil
                send(.detachTerminal(id: id), forSession: id)
                reattachTerminalIfNeeded()
            }
        }
    }

    private static let matchScreenKey = "terminal.matchHostToScreen"

    /// Drops the intent to watch a pane without sending a detach — for when the
    /// session itself has gone away and there is nothing left to detach from.
    private func forgetTerminalIntent() {
        terminalWatchdog?.cancel()
        terminalWatchdog = nil
        desiredSessionID = nil
        lastAttachAt = nil
        lastFrameAt = nil
        awaitingFirstFrame = false
        updateTerminalStaleness()
    }

    /// Retry a resize the dialog guard turned away, once the dialog is gone.
    /// Called from the fleet-update paths, which is where a phase change lands.
    private func retryDeferredResizeIfPossible() {
        guard resizeDeferred, let id = desiredSessionID else { return }
        guard session(id: id)?.phase != .awaitingApproval else { return }
        flushTerminalGrid()
    }

    /// What to put on an `attach_terminal`, or nil to ask for no resize at all.
    ///
    /// Nil rather than a default is the point: the host treats a grid on an
    /// attach as an instruction, so shipping a fallback would reshape the Mac's
    /// window every time a pane was opened — including on the attach that
    /// follows turning MATCH *off*, which is meant to hand the window back.
    private func attachGrid() -> (cols: Int, rows: Int)? {
        guard matchHostToScreen else { return nil }
        return desiredGrid
    }

    /// Re-asks the host to stream the pane the user is already looking at.
    ///
    /// Called after every handshake and on return to the foreground. Keeps the
    /// existing frame on screen while it waits: blanking the pane to prove we
    /// are working would destroy the one thing the user came back to read.
    func reattachTerminalIfNeeded() {
        guard status.isReady, let id = desiredSessionID else { return }
        attachedSessionID = id
        lastAttachAt = Date()
        awaitingFirstFrame = true
        let grid = attachGrid()
        send(.attachTerminal(id: id, cols: grid?.cols, rows: grid?.rows), forSession: id)
        updateTerminalStaleness()
        startTerminalWatchdogIfNeeded()
    }

    /// One low-frequency wake-up, alive only while a pane is on screen and the
    /// app is in front. It reads a timestamp; it touches the network only on
    /// the rare occasion the host has genuinely stopped talking.
    ///
    /// Attaching returns the current capture, so a healthy host answers a
    /// re-attach with a frame and the streak resets. A host that answers
    /// nothing twice running is not going to answer a third time either — at
    /// that point the watchdog stands down and the stale bar hands the decision
    /// to the user, rather than quietly retrying at 2am for an hour.
    private func startTerminalWatchdogIfNeeded() {
        guard desiredSessionID != nil, terminalWatchdog == nil else { return }
        let interval = ConnectionHealth.attachTimeout / 2
        terminalWatchdog = Task { @MainActor [weak self] in
            var unanswered = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.desiredSessionID != nil else { return }
                // The tick exists to let time itself change the answer.
                self.updateTerminalStaleness()
                guard self.status.isReady, self.terminalIsStale else {
                    unanswered = 0
                    continue
                }
                unanswered += 1
                guard unanswered <= ConnectionHealth.terminalResyncAttempts else {
                    self.log.info("terminal still silent after \(unanswered - 1) re-attaches — standing down")
                    self.terminalWatchdog = nil
                    return
                }
                self.log.info("terminal silent — re-attaching \(self.desiredSessionID ?? "?")")
                self.reattachTerminalIfNeeded()
            }
        }
    }

    /// Ask the host for the next page of history above what we already hold.
    ///
    /// Everything this needs existed on both sides already — the host pages
    /// `capture-pane` backwards perfectly well — and no view had ever called
    /// it, which is why the pane could not be scrolled past its last screenful.
    func fetchMoreScrollback(lines: Int = 500) {
        guard let attachedSessionID, scrollbackHasMore, !scrollbackLoading else { return }
        scrollbackLoading = true
        let offset = scrollbackPages.reduce(0) { $0 + $1.lines }
        send(.fetchScrollback(id: attachedSessionID, lines: lines, offset: offset), forSession: attachedSessionID)

        // Nothing guarantees an answer — a v1 host has no such verb. Expire the
        // flag rather than wedging the pane against loading forever.
        scrollbackTimeout?.cancel()
        scrollbackTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.scrollbackLoading = false
        }
    }

    // MARK: - Meetings

    /// Combines what the Mac knows with what this device recorded.
    ///
    /// The host's list is authoritative about host meetings and nothing else.
    /// It has never heard of a recording still sitting in the outbox, so
    /// letting it replace the array wholesale — which is what this used to do —
    /// deleted meetings the user had just made.
    private func rebuildMeetings(hostList: [Meeting]) {
        var merged: [Meeting] = hostList.map { incoming in
            // Preserve any detail already fetched: the list payload is metadata
            // only, and clobbering it would blank an open detail pane.
            guard let existing = meetings.first(where: { $0.id == incoming.id }),
                  existing.hasDetail, !incoming.hasDetail else { return incoming }
            var row = incoming
            row.summary = existing.summary
            row.decisions = existing.decisions
            row.actionItems = existing.actionItems
            row.transcript = existing.transcript
            row.userNotes = existing.userNotes
            row.notesMarkdown = existing.notesMarkdown
            return row
        }

        let hostIDs = Set(merged.map(\.id))
        for local in meetingStore.localMeetings {
            if hostIDs.contains(local.id) {
                // The host has it now; the local copy's job is done except for
                // remembering that this device is where it came from.
                if let idx = merged.firstIndex(where: { $0.id == local.id }) {
                    merged[idx].origin = .local
                    merged[idx].syncState = .synced
                    if merged[idx].transcript == nil { merged[idx].transcript = local.transcript }
                    if merged[idx].userNotes == nil { merged[idx].userNotes = local.userNotes }
                }
                if local.syncState != .synced {
                    meetingStore.setSyncState(.synced, for: local.id)
                }
            } else {
                merged.append(local)
            }
        }

        meetings = merged.sorted { $0.createdAt > $1.createdAt }
    }

    private func applyHostDetail(_ meeting: Meeting) {
        var row = meeting
        // A host detail for a meeting this phone recorded is the notes pass
        // landing: keep the local provenance, drop the provisional flag.
        if let local = meetingStore.meeting(id: meeting.id) {
            row.origin = .local
            row.syncState = .synced
            row.provisionalSummary = false
            if row.transcript == nil { row.transcript = local.transcript }
            if row.userNotes == nil { row.userNotes = local.userNotes }
            meetingStore.saveQuietly(row)
        }
        if let idx = meetings.firstIndex(where: { $0.id == row.id }) {
            meetings[idx] = row
        } else {
            meetings.insert(row, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
    }

    func loadMeeting(id: String) {
        guard meeting(id: id)?.hasDetail != true else { return }
        // A local meeting the host has never received has no detail to fetch;
        // asking would just leave the pane spinning on "Loading notes…".
        if let local = meetingStore.meeting(id: id), local.syncState != .synced { return }
        send(.fetchMeeting(id: id))
    }

    func startHostRecording(mode: MeetingMode = .standard) {
        liveTranscript = []
        liveElapsedSec = 0
        send(.startMeeting(mode: mode))
    }

    func stopHostRecording() {
        send(.stopMeeting)
    }

    /// Asks the host about one of *its* meetings. Questions about a recording
    /// made on this phone are answered on-device instead — see
    /// `MeetingAskEngine`; the host cannot answer about a call it never heard.
    func askAboutMeeting(id: String, question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        beginAsk(for: id)
        askThread.append(MeetingAskTurn(role: .you, text: trimmed))
        guard status.isReady else {
            askThread.append(MeetingAskTurn(role: .udha, text: "Not connected to the Mac that recorded this call."))
            return
        }
        askPending = true
        send(.askMeeting(id: id, question: trimmed))
        // A host that never answers used to leave this spinning on "thinking"
        // for the rest of the session.
        askTimeout?.cancel()
        askTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled, self.askPending else { return }
            self.askPending = false
            self.askThread.append(MeetingAskTurn(role: .udha, text: "No answer came back. Try again?"))
        }
    }

    /// Resets the thread when the question is about a different meeting.
    func beginAsk(for id: String) {
        guard askMeetingID != id else { return }
        clearAsk()
        askMeetingID = id
    }

    func appendAskTurn(_ turn: MeetingAskTurn) {
        askThread.append(turn)
    }

    func setAskPending(_ pending: Bool) {
        askPending = pending
    }

    func clearAsk() {
        askTimeout?.cancel()
        askTimeout = nil
        askThread = []
        askPending = false
        askMeetingID = nil
    }

    /// Optimistic toggle — the checkbox must feel instant, and the host echoes
    /// the authoritative list back on the next fetch.
    func toggleActionItem(meetingID: String, itemID: String) {
        guard let mIdx = meetings.firstIndex(where: { $0.id == meetingID }),
              var items = meetings[mIdx].actionItems,
              let iIdx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[iIdx].done.toggle()
        meetings[mIdx].actionItems = items
        meetingStore.mutate(id: meetingID) { $0.actionItems = items }
        send(.setActionItemDone(meetingID: meetingID, itemID: itemID, done: items[iIdx].done))
    }

    /// Saves edited notes for a meeting. Applied locally first so typing never
    /// stutters waiting on a round trip; the host echoes the stored value back
    /// on the next fetch.
    func saveMeetingNotes(id: String, notes: String) {
        if let idx = meetings.firstIndex(where: { $0.id == id }) {
            meetings[idx].userNotes = notes
        }
        // Also to disk for a meeting this device owns. Sending alone would lose
        // the edit whenever the Mac is not there — which is exactly when a
        // phone recording is being written up.
        meetingStore.mutate(id: id) { $0.userNotes = notes }
        send(.updateMeetingNotes(id: id, notes: notes))
    }

    /// Publishes a meeting recorded on this device so the host can summarise it.
    ///
    /// Queues rather than sends. The old version dropped the push on the floor
    /// when the Mac was offline, which is precisely when a phone recording is
    /// most likely to happen, so the meeting never got summarised and nobody
    /// was told why.
    func uploadLocalMeeting(_ meeting: Meeting) {
        var queued = meeting
        queued.syncState = .queued
        meetingStore.saveQuietly(queued)
        upsertMeeting(queued)
        flushOutbox()
    }

    /// Sends everything the host still owes us a home for. Safe to call often —
    /// it runs on every `refresh()`, which covers connect, foreground and
    /// pull-to-refresh.
    func flushOutbox() {
        guard status.isReady else { return }
        for meeting in meetingStore.pendingUploads {
            guard let payload = meeting.wirePayload else {
                log.error("meeting \(meeting.id) is not serialisable; leaving it queued")
                continue
            }
            meetingStore.setSyncState(.uploading, for: meeting.id)
            upsertSyncState(.uploading, for: meeting.id)
            send(.pushLocalMeeting(meeting: payload))
        }
    }

    /// A summary the phone produced itself. Shown immediately; replaced without
    /// ceremony when the host's own pass arrives for the same id.
    func applyLocalSummary(_ meeting: Meeting) {
        upsertMeeting(meeting)
    }

    private func upsertMeeting(_ meeting: Meeting) {
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.createdAt > $1.createdAt }
        }
    }

    private func upsertSyncState(_ state: MeetingSyncState, for id: String) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[idx].syncState = state
    }

    // MARK: - Videos

    func listVideos() {
        guard let hostID = videoHostID, canBrowseVideos else { return }
        videosLoading = true
        videoLibraryError = nil
        send(.listVideos, to: hostID)
        videoLoadTimeout?.cancel()
        videoLoadTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.videoHostID == hostID, self.videosLoading else { return }
            self.videosLoading = false
            self.videoLibraryError = "The Mac did not answer. Check that Udha is connected, then try again."
        }
    }

    /// Retitles a video on the host, and here at once.
    ///
    /// Same bargain as renaming a session: the host is the authority and its
    /// next `videos_full` overwrites this, but the list must not sit on the old
    /// title for a round trip. A published video also has its public page
    /// retitled by the host — the title on the phone, the Mac and the share
    /// link are one thing, or the feature is a lie.
    func renameVideo(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let previous = videos[index].title
        guard !trimmed.isEmpty, trimmed != previous else { return }
        guard status.isReady, canBrowseVideos else {
            lastActionError = "This host cannot manage videos"
            return
        }
        videoTitleRollback[id] = previous
        videos[index].title = trimmed
        send(.renameVideo(id: id, title: trimmed), to: videoHostID)
    }

    /// Deletes a video and its folder on the host. Irreversible there, so the
    /// UI asks first; here it disappears immediately and comes back if the
    /// host refuses — which it does while the video is still being captured
    /// or rendered.
    func deleteVideo(id: String) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        guard status.isReady, canBrowseVideos else {
            lastActionError = "This host cannot manage videos"
            return
        }
        videoDeleteRollback[id] = (index, videos[index])
        videos.remove(at: index)
        send(.deleteVideo(id: id), to: videoHostID)
    }

    // MARK: - Agents

    func runAgent(_ agent: BridgeAgent, directory: String? = nil) {
        send(.runAgent(id: agent.id, directory: directory ?? agent.directory))
    }

    // MARK: - Debug seam (mock host)

    #if DEBUG
    /// When set, outbound messages go here instead of the relay. Installed only
    /// by `MockHost` under the `--udha-mock` launch argument.
    var mockOutbound: (([String: Any]) -> Void)?

    /// Feeds a payload in as though the active host had sent it.
    func mockInject(_ payload: [String: Any]) {
        handlePayload(payload, from: activeInstanceID ?? "mock")
    }

    /// Inject as a *named* machine, so the mock can speak for a second host and
    /// the merged fleet is reachable without two real computers.
    func mockInject(_ payload: [String: Any], from instanceID: String) {
        handlePayload(payload, from: instanceID)
    }

    /// Brings the bridge to a paired state with no relay and no Auth0, then
    /// runs the real handshake against the mock.
    func mockActivate(instance: BridgeInstance, alongside others: [BridgeInstance] = []) {
        instances = [instance] + others
        activeInstanceID = instance.id
        feeds[instance.id] = HostFeed()
        for other in others { feeds[other.id] = HostFeed() }
        status = .pairing
        beginHandshake()
    }
    #endif

    // MARK: - Voice

    func claimVoice() {
        guard status.isReady else { return }
        voice.beginClaim()
        send(.voiceClaim)
    }

    func releaseVoice() {
        voice.release()
        send(.voiceRelease)
    }
}
