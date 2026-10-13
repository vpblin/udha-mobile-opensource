import Foundation

// MARK: - Build configuration

/// Values that identify *your* deployment, read from Info.plist, which takes
/// them from Udha.xcconfig / Local.xcconfig. Empty when unset.
nonisolated enum AppConfig {
    static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Unified-logging subsystem for every `Logger` in the app.
    static let logSubsystem = Bundle.main.bundleIdentifier ?? "udha"

    static let relayHost = string("UdhaRelayHost")
    static let auth0Domain = string("UdhaAuth0Domain")
    static let auth0ClientID = string("UdhaAuth0ClientID")
    /// The Auth0 API identifier; by convention the relay's https URL.
    static let auth0Audience: String = {
        let explicit = string("UdhaAuth0Audience")
        return explicit.isEmpty ? "https://\(relayHost)" : explicit
    }()

    /// True once a relay and an Auth0 tenant are configured — without them the
    /// app can only drive the simulator's mock host.
    static var isRelayConfigured: Bool {
        !relayHost.isEmpty && !auth0Domain.isEmpty && !auth0ClientID.isEmpty
    }
}

// MARK: - Relay configuration

enum RelayConfig {
    static var url: String { "wss://\(AppConfig.relayHost)" }
    static let clientPath = "/client"

    static func clientURL(token: String) -> String {
        "\(url)\(clientPath)?token=\(token)"
    }
}

// MARK: - Protocol version

enum BridgeProtocolVersion {
    /// What this client speaks. Sent in `hello`; a desktop that doesn't
    /// understand `hello` simply never replies and we stay on v1 semantics.
    static let current = 2

    /// Everything this client can handle. The desktop intersects this with its
    /// own list and only pushes what both sides agreed on, so an old desktop
    /// paired with a new phone degrades feature-by-feature instead of breaking.
    static let capabilities = ["delta", "actions", "terminal", "pty", "diff", "push", "resize",
                               "rename", "reorder", "videos", "stats", "attachments", "attention_events",
                               "folders", "accounts"]
}

/// One choice on a Claude dialog.
struct DialogOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The digit the dialog is listening for. Not an array index — Claude
    /// numbers from 1, and pressing the wrong digit answers the wrong question.
    var number: Int
    var label: String
    /// The row Claude has highlighted.
    var isSelected: Bool

    var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number = "n"
        case label
        case isSelected = "selected"
    }

    init(number: Int, label: String, isSelected: Bool) {
        self.number = number
        self.label = label
        self.isSelected = isSelected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = (try? c.decode(Int.self, forKey: .number)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        isSelected = (try? c.decode(Bool.self, forKey: .isSelected)) ?? false
    }
}

/// What a session is doing, as one word and one colour.
///
/// Foundation-only on purpose: the *tone* is an abstract role, not a `Color`,
/// so the rule that decides it can be asserted in tests without a UI, and the
/// palette stays the theme's business. `UdhaTheme.color(for:)` resolves it.
struct SessionStatus: Equatable, Sendable {
    /// Five roles, because that is how many distinctions are worth making at a
    /// glance on a phone: act now, something broke, it is running, it is
    /// waiting on nothing, it is over.
    enum Tone: String, Equatable, Sendable, CaseIterable {
        /// Blocked on you — approval or an answer.
        case needsYou
        /// Crashed or errored. Also yours to deal with, but a different kind of
        /// problem, and worth telling apart from a question at a glance.
        case error
        /// Claude is doing something right now.
        case working
        /// Alive, nothing in flight, nobody waiting.
        case idle
        /// Over, or long enough abandoned to be treated that way.
        case dormant

        /// Whether this tone is asking for the user.
        var demandsAttention: Bool { self == .needsYou || self == .error }
    }

    var label: String
    var tone: Tone
}

// MARK: - Session enums (mirror the desktop's Sessions/SessionState.swift)

/// Coarse process state. Unchanged from protocol v1 — the desktop's voice
/// engine, tool handlers and menu bar all switch on this, so it stays stable.
enum SessionState: String, Codable, Hashable, Sendable, CaseIterable {
    case starting, idle, working, needsInput, errored, completed, exited, crashed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionState(rawValue: raw) ?? .unknown
    }
}

/// Fine-grained "what is it doing right now", orthogonal to `SessionState`.
/// The distinction that matters: `.idle` (nothing happened) vs `.awaitingReply`
/// (Claude finished and the ball is in your court).
enum SessionPhase: String, Codable, Hashable, Sendable {
    case starting
    case thinking          // reasoning, no tool call on screen yet
    case planning          // plan mode, streaming
    case usingTool         // a tool is running; `phaseDetail` names it
    case awaitingApproval  // permission / plan / trust dialog on screen
    case awaitingReply     // turn ended — waiting on the user
    case idle              // nothing in flight, no turn to review
    case finished          // exited or crashed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionPhase(rawValue: raw) ?? .unknown
    }

    var isBlockedOnUser: Bool {
        self == .awaitingApproval || self == .awaitingReply
    }
}

/// Kanban grouping. Derived on the **desktop** (from `SessionSnapshot.attention`)
/// rather than here, so the iPad columns and the Mac overlay always agree — the
/// desktop's rule already accounts for silent and long-abandoned turns.
enum SessionAttention: String, Codable, Hashable, Sendable, CaseIterable {
    case needsYou
    case working
    case quiet

    /// Column header on the fleet board.
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working:  return "Working"
        case .quiet:    return "Quiet"
        }
    }

    var systemImage: String {
        switch self {
        case .needsYou: return "exclamationmark.bubble.fill"
        case .working:  return "gearshape.2.fill"
        case .quiet:    return "moon.zzz.fill"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionAttention(rawValue: raw) ?? .quiet
    }
}

enum SessionPriority: String, Codable, Hashable, Sendable {
    case low, normal, high
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionPriority(rawValue: raw) ?? .unknown
    }
}

// MARK: - Session row

/// One session as it arrives over the wire, from either `sessions_full` or
/// `sessions_delta` — the desktop serializes both through a single function so
/// the two can't drift.
///
/// Optional fields are genuinely optional: a v1 desktop, a non-Claude session,
/// or a session with no statusLine sidecar will omit them, and every consumer
/// must render without them.
struct SessionRow: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var label: String
    var directory: String

    // v1 fields
    var state: SessionState
    var stateEnteredSecAgo: Int
    var priority: SessionPriority
    var hasPendingPrompt: Bool

    // v2 fields
    var phase: SessionPhase
    var phaseDetail: String?
    var phaseEnteredSecAgo: Int
    var attention: SessionAttention
    var stale: Bool
    var subagentCount: Int
    var contextPercent: Int?
    /// Whole cents, deliberately not a Double — the desktop's statusLine feed
    /// reports a drifting float, and quantizing upstream is what keeps idle
    /// sessions from emitting a delta every few seconds.
    var costCents: Int?
    /// What Claude asked before ending its turn, so a "Ready" card says what it
    /// actually wants instead of just how long it's been waiting.
    var attentionState = SessionAttentionState()
    var supportsAttentionEvents = false
    var lastQuestion: String?
    /// The choices on the dialog covering this pane, when the host reads any.
    /// Empty means fall back to a plain approve / deny — an older host, or a
    /// prompt whose shape could not be parsed with confidence.
    var dialogOptions: [DialogOption]
    /// False for a plain shell session — the card hides Claude-specific chrome.
    var isClaudeTUI: Bool
    /// The model Claude reports for itself — "Opus 5", "Sonnet 5". Read from the
    /// statusLine sidecar on every tick, so switching model mid-session shows.
    /// Nil for a session with no sidecar, and never guessed at.
    var model: String?
    /// The machine this session runs on, when it is not the host we are talking
    /// to. The Mac holds devbox's sessions alongside its own, so a phone
    /// paired to the Mac sees both — this is what separates them.
    var host: String?
    /// The Claude login this session runs under — `work-2`, the config dir's
    /// short name. The host only sends it when the session's tree has more
    /// than one login, which is exactly when there is something to switch to.
    var account: String?

    /// The folder this session is filed in on its own machine, or nil for a
    /// loose row. Ids never cross machines: the folder itself rides in the
    /// `folders` list beside `sessions_full`, and an id the list does not
    /// carry reads as loose — a `delete_folder` lands as a row delta and a
    /// folder push that can arrive in either order.
    var folderID: String?
    /// Hidden rows are still sent, so "Unhide all" can count them; the list
    /// simply does not draw them.
    var hidden: Bool

    /// The instance that served this row. Stamped on ingest, never on the wire.
    ///
    /// `host` is a *display name* and is only present on a row one machine
    /// forwarded about another — so it cannot say which socket a reply should
    /// go down. With the client subscribed to several machines at once, that is
    /// exactly what every action needs to know.
    var instanceID: String?

    // Worktree provenance (WS-4)
    var repo: String?
    var branch: String?
    var isWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case id, label, directory, state, stateEnteredSecAgo, priority, hasPendingPrompt
        case phase, phaseDetail, phaseEnteredSecAgo, attention, stale, subagentCount
        // The wire calls it `options`; the property says whose options they are.
        case dialogOptions = "options"
        case contextPercent, costCents, lastQuestion, isClaudeTUI, model, host, account
        case repo, branch, isWorktree, attentionState
        case folderID = "folder"
        case hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? "session"
        directory = (try? c.decode(String.self, forKey: .directory)) ?? ""

        state = (try? c.decode(SessionState.self, forKey: .state)) ?? .unknown
        stateEnteredSecAgo = (try? c.decode(Int.self, forKey: .stateEnteredSecAgo)) ?? 0
        priority = (try? c.decode(SessionPriority.self, forKey: .priority)) ?? .normal
        hasPendingPrompt = (try? c.decode(Bool.self, forKey: .hasPendingPrompt)) ?? false

        // A v1 desktop sends none of the following. Derive what we can from
        // `state` so the kanban still groups sensibly against an old host.
        let decodedPhase = try? c.decode(SessionPhase.self, forKey: .phase)
        phase = decodedPhase ?? SessionRow.inferPhase(from: state, hasPrompt: hasPendingPrompt)
        phaseDetail = try? c.decode(String.self, forKey: .phaseDetail)
        phaseEnteredSecAgo = (try? c.decode(Int.self, forKey: .phaseEnteredSecAgo)) ?? stateEnteredSecAgo
        attention = (try? c.decode(SessionAttention.self, forKey: .attention))
            ?? SessionRow.inferAttention(from: phase, state: state)
        stale = (try? c.decode(Bool.self, forKey: .stale)) ?? false
        subagentCount = (try? c.decode(Int.self, forKey: .subagentCount)) ?? 0
        contextPercent = try? c.decode(Int.self, forKey: .contextPercent)
        costCents = try? c.decode(Int.self, forKey: .costCents)
        supportsAttentionEvents = c.contains(.attentionState)
        attentionState = (try? c.decode(SessionAttentionState.self, forKey: .attentionState)) ?? SessionAttentionState()
        lastQuestion = try? c.decode(String.self, forKey: .lastQuestion)
        dialogOptions = (try? c.decode([DialogOption].self, forKey: .dialogOptions)) ?? []
        isClaudeTUI = (try? c.decode(Bool.self, forKey: .isClaudeTUI)) ?? true
        model = try? c.decode(String.self, forKey: .model)
        host = try? c.decode(String.self, forKey: .host)
        account = try? c.decode(String.self, forKey: .account)
        folderID = try? c.decode(String.self, forKey: .folderID)
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false

        repo = try? c.decode(String.self, forKey: .repo)
        branch = try? c.decode(String.self, forKey: .branch)
        isWorktree = (try? c.decode(Bool.self, forKey: .isWorktree)) ?? false
    }

    /// v1 fallback: the old protocol only had `state`, so map it onto the
    /// closest phase rather than showing every session as "unknown".
    private static func inferPhase(from state: SessionState, hasPrompt: Bool) -> SessionPhase {
        if hasPrompt { return .awaitingApproval }
        switch state {
        case .starting:            return .starting
        case .working:             return .thinking
        case .needsInput:          return .awaitingReply
        case .idle, .completed:    return .idle
        case .exited, .crashed:    return .finished
        case .errored:             return .awaitingReply
        case .unknown:             return .unknown
        }
    }

    private static func inferAttention(from phase: SessionPhase, state: SessionState) -> SessionAttention {
        switch state {
        case .errored, .crashed: return .needsYou
        case .exited:            return .quiet
        default: break
        }
        switch phase {
        case .awaitingApproval, .awaitingReply:        return .needsYou
        case .thinking, .planning, .usingTool, .starting: return .working
        case .idle, .finished, .unknown:               return .quiet
        }
    }
}

// MARK: - Folders

/// A named group of sessions on one machine — the desktop's `SessionFolder`,
/// as it arrives in the `folders` list beside `sessions_full`.
///
/// Owned by the machine that supervises the sessions, exactly like a
/// session's label and its place in the list: the host persists it, publishes
/// it on the wire, and every edit from here goes back through the bridge's
/// folder verbs. Nothing about a folder lives on this device except whether
/// it is folded shut, which is a matter of screen space, not of the folder.
struct SessionFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    /// A hidden folder hides every session filed in it. Rides only when true.
    var hidden: Bool

    init(id: String, name: String, hidden: Bool = false) {
        self.id = id
        self.name = name
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Folder"
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if hidden { try c.encode(true, forKey: .hidden) }
    }

    /// Move `moving` one place up or down in `ids`; unchanged at either end.
    static func nudged(_ ids: [String], moving: String, up: Bool) -> [String] {
        guard let i = ids.firstIndex(of: moving) else { return ids }
        let j = up ? i - 1 : i + 1
        guard ids.indices.contains(j) else { return ids }
        var out = ids
        out.swapAt(i, j)
        return out
    }
}

// MARK: - Row display helpers

extension SessionRow {
    /// The model, or what assistant this is when it is not Claude — so a Codex
    /// or Qwen session is never mistaken on the list for a Claude one. Nil when
    /// there is no sidecar to report a model: a dash would read as a reading.
    var modelBadge: String? {
        if let model, !model.isEmpty { return model }
        return isClaudeTUI ? nil : "shell"
    }

    /// Everything the row puts on screen, plus the machine and the folder — the
    /// filter should find a session by whatever you happen to remember about it.
    func matches(_ lowercasedQuery: String) -> Bool {
        let haystack = [label, statusLabel, statusDetail ?? "", directory,
                        repo ?? "", branch ?? "", model ?? "", host ?? "",
                        lastQuestion ?? ""]
        return haystack.contains { $0.lowercased().contains(lowercasedQuery) }
    }

    /// Headline verb for the card: "Thinking", "Ready", "Needs approval".
    /// Mirrors the desktop's `SessionStatusPresentation` so both surfaces read
    /// the same way.
    var statusLabel: String { status.label }

    /// Label and colour together, from one derivation.
    ///
    /// They used to be computed in different places from different inputs, and
    /// the result was a board where "Ready" was red on one row and the same
    /// grey as "Thinking" on the next with nothing on screen explaining the
    /// difference. The cause: the *word* came from `phase` alone, while the
    /// *colour* came from `attention` — and the host only calls an
    /// `awaitingReply` session `needsYou` when Claude actually left a question
    /// behind. Two genuinely different situations wearing one word.
    ///
    /// So the two cases are named apart now — "Needs reply" when you have been
    /// asked something, "Ready" when the turn simply ended — and both the word
    /// and the colour come from this one value. They cannot drift again.
    var status: SessionStatus {
        switch state {
        case .crashed: return SessionStatus(label: "Crashed", tone: .error)
        case .errored: return SessionStatus(label: "Error", tone: .error)
        case .exited:  return SessionStatus(label: "Exited", tone: .dormant)
        default: break
        }
        if let event = attentionState.visibleEvents.first(where: { $0.kind.needsAction }) {
            return SessionStatus(label: event.kind.label, tone: .needsYou)
        }
        switch phase {
        case .starting:  return SessionStatus(label: "Starting", tone: .working)
        case .thinking:  return SessionStatus(label: "Thinking", tone: .working)
        case .planning:  return SessionStatus(label: "Planning", tone: .working)
        case .usingTool: return SessionStatus(label: phaseDetail ?? "Working", tone: .working)

        case .awaitingApproval:
            return SessionStatus(label: "Needs approval", tone: .needsYou)

        case .awaitingReply:
            // Keyed off the host's own `attention` rather than re-deriving the
            // rule here. The board's "needs you" count comes from that field,
            // so reading it directly is what keeps the row, the badge and the
            // column agreeing about the same session.
            if attention == .needsYou {
                return SessionStatus(label: "Needs reply", tone: .needsYou)
            }
            return stale
                ? SessionStatus(label: "Stale", tone: .dormant)
                : SessionStatus(label: "Ready", tone: .idle)

        case .idle:      return SessionStatus(label: "Idle", tone: .idle)
        case .finished:  return SessionStatus(label: "Done", tone: .idle)
        case .unknown:   return SessionStatus(label: state.rawValue.capitalized, tone: .idle)
        }
    }

    /// Secondary line. `usingTool` already puts its detail in the headline, so
    /// it falls through to the subagent note instead of repeating itself.
    var statusDetail: String? {
        switch phase {
        case .usingTool:        return subagentNote
        case .awaitingApproval: return phaseDetail ?? lastQuestion
        case .awaitingReply:    return supportsAttentionEvents ? attentionState.visibleEvents.first?.summary : (lastQuestion ?? phaseDetail)
        default:                return phaseDetail ?? subagentNote
        }
    }

    var subagentNote: String? {
        guard subagentCount > 0 else { return nil }
        return subagentCount == 1 ? "1 subagent" : "\(subagentCount) subagents"
    }

    var costDisplay: String? {
        guard let costCents, costCents > 0 else { return nil }
        return String(format: "$%.2f", Double(costCents) / 100.0)
    }

    /// Whether Claude is actually waiting on a person right now.
    ///
    /// Not simply `phase == .awaitingReply`. That phase is also the ordinary
    /// resting state of a finished turn — "Ready" and "Stale" both live under
    /// it — so treating it as blocked pins a permanent card above the composer
    /// on every session that is not mid-tool-call, with nothing to dismiss
    /// because there was never a question. Only the host's own `attention`
    /// separates "Claude asked you something" from "Claude simply stopped",
    /// which is the same field `status` keys off and the same one the board
    /// counts.
    var isBlocking: Bool {
        if supportsAttentionEvents { return attentionState.visibleEvents.contains(where: { $0.kind.needsAction }) }
        if phase == .awaitingApproval { return true }
        return phase == .awaitingReply && attention == .needsYou
    }

    /// The status label with long absolute paths collapsed to their leaf.
    ///
    /// `usingTool` puts the command Claude is running in the headline, which is
    /// the right call — but a real one is mostly path:
    ///
    ///     Running S=/tmp/claude-1000/-home-dev-projects-acme-…/node_modules/.bin/jest --runInBand
    ///
    /// Truncating that to a row's width keeps "Running S=/tmp/cla…", which is
    /// the half that says nothing. Collapsing each long path token to its last
    /// component first leaves "Running S=jest --runInBand" — the half you were
    /// reading the row for.
    var compactStatusLabel: String {
        SessionRow.collapsePaths(in: status.label)
    }

    /// Any whitespace-delimited token that looks like a path and is long enough
    /// to be a problem becomes its own last component. Short paths are left
    /// alone: "src/App.swift" is already the useful form.
    static func collapsePaths(in text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { token -> Substring in
            guard token.count > 18, token.contains("/") else { return token }
            // Keep whatever precedes the path — "S=", "--out=" — so the flag
            // the command was given survives the collapse.
            guard let slash = token.firstIndex(of: "/") else { return token }
            let prefix = token[token.startIndex..<slash]
            let path = token[slash...]
            guard let leaf = path.split(separator: "/").last, !leaf.isEmpty else { return token }
            return Substring(prefix + leaf)
        }
        .joined(separator: " ")
    }

    /// Last path component — the full directory is too long for a card.
    var directoryName: String {
        (directory as NSString).lastPathComponent
    }

    var isTerminal: Bool {
        state == .exited || state == .crashed
    }

    /// "4m", "2h" — compact age for the status line.
    static func compactAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    var phaseAge: String { SessionRow.compactAge(phaseEnteredSecAgo) }
}

// MARK: - Instances

/// A host (Mac or headless Linux daemon) visible to this client. Discovered via
/// the relay's `paired_instances` list on connect and `instance_online` events.
struct BridgeInstance: Identifiable, Codable, Equatable, Sendable {
    let id: String              // instanceId
    var name: String
    var machineName: String?
    var isOnline: Bool
    /// "udha-desktop" or "udha-headless". Only known after `hello_ack`; the
    /// relay's pairing metadata carries it too when the host supplies it.
    var kind: String?

    var displayName: String {
        if let machineName, !machineName.isEmpty { return machineName }
        return name
    }

    var isHeadless: Bool { kind == "udha-headless" }

    var systemImage: String {
        isHeadless ? "server.rack" : "laptopcomputer"
    }
}

// MARK: - Directory listing (folder picker for new sessions)

struct DirectoryListing: Codable, Equatable, Sendable {
    let path: String
    let parent: String          // "" at filesystem root
    let entries: [Entry]
    let error: String?

    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let name: String
        let path: String
        /// Whether this folder is a git repo. Hand-decoded with a default
        /// because a host that predates the flag omits it entirely — and
        /// Swift's *synthesised* decoder ignores default values, which is
        /// exactly how a missing `truncated` once blanked the diff viewer.
        var isRepo: Bool = false
        var id: String { path }

        init(name: String, path: String, isRepo: Bool = false) {
            self.name = name
            self.path = path
            self.isRepo = isRepo
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            path = (try? c.decode(String.self, forKey: .path)) ?? ""
            isRepo = (try? c.decode(Bool.self, forKey: .isRepo)) ?? false
        }

        enum CodingKeys: String, CodingKey { case name, path, isRepo }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        parent = (try? c.decode(String.self, forKey: .parent)) ?? ""
        entries = (try? c.decode([Entry].self, forKey: .entries)) ?? []
        error = try? c.decode(String.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey { case path, parent, entries, error }
}

/// Which CLI a new session runs. Mirrors the Mac's `SessionTool` case for case
/// — the raw value is the wire contract and becomes the command the host spawns.
///
/// The host has always accepted `tool` on `create_session` and defaulted to
/// Claude when it was absent; this client simply never sent one, so every
/// session started from a phone came up as Claude whatever you wanted.
enum SessionTool: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case qwen

    var id: String { rawValue }

    /// `codex` is the CLI you sign into with a ChatGPT account, and ChatGPT is
    /// the name on that account. `qwen` runs against a model on the box's own
    /// GPU, so it is named for the model — there is no account.
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "ChatGPT"
        case .qwen:   return "Qwen"
        }
    }

    /// True when the model runs on the machine itself: no network, no spend.
    var isLocal: Bool { self == .qwen }

    /// The four rungs this tool's CLI actually has.
    ///
    /// They are four everywhere, but they are not the *same* four: Codex says
    /// "workspace-write" where Claude says "acceptEdits". Sending Claude's name
    /// to a Codex session is not an error — the host falls back to that tool's
    /// default — it just quietly gives you something other than what the picker
    /// said, which is worse than an error.
    var modes: [PermissionMode] {
        switch self {
        case .claude: return [.acceptEdits, .ask, .plan, .bypass]
        case .codex:  return [.workspaceWrite, .ask, .readOnly, .bypass]
        case .qwen:   return [.autoEdit, .ask, .plan, .yolo]
        }
    }

    /// What the host would pick on its own, which is what the picker opens on.
    var defaultMode: PermissionMode { modes[0] }
}

/// How much the agent may do without asking. Mirrors the Mac's three ladders —
/// `ClaudePermissionMode`, `CodexApprovalMode`, `QwenApprovalMode` — as one
/// enum, because the raw values are the wire contract and the host maps them to
/// that tool's CLI flags. Kept as a plain mirror rather than a shared module
/// because the two repos deliberately compile separately.
enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
    // Claude
    case acceptEdits
    case plan
    case bypass
    // ChatGPT (Codex)
    case workspaceWrite
    case readOnly
    // Qwen
    case autoEdit
    case yolo
    // Every tool has this rung under the same name.
    case ask

    var id: String { rawValue }

    /// Short form for the picker chips; the Mac's dropdown has room for more.
    var shortLabel: String {
        switch self {
        case .acceptEdits, .autoEdit: return "Accept edits"
        case .workspaceWrite:         return "Edit in workspace"
        case .ask:                    return "Ask each time"
        case .plan:                   return "Plan only"
        case .readOnly:               return "Read only"
        case .bypass, .yolo:          return "Bypass all"
        }
    }

    /// Worded for the tool that is actually going to run, because the same rung
    /// means slightly different things to each CLI.
    func detail(for tool: SessionTool) -> String {
        switch self {
        case .acceptEdits, .autoEdit:
            return "Auto-applies file edits; still prompts for riskier actions."
        case .workspaceWrite:
            return "Writes inside the project without asking; asks to step outside it."
        case .ask:
            return tool == .codex
                ? "Sandboxed to reading; asks before every write or command."
                : "\(tool.label) prompts for every action (standard behavior)."
        case .plan:
            return "\(tool.label) plans only and makes no changes."
        case .readOnly:
            return "Reads and plans only, and never stops to ask."
        case .bypass, .yolo:
            return "Runs every command and edit with no prompts. Use with care."
        }
    }

    /// The one worth a warning colour: it is the only mode that can act
    /// destructively with nobody watching, which is a different proposition
    /// from a phone than from the machine itself.
    var isDangerous: Bool { self == .bypass || self == .yolo }
}

/// Branches of the repo behind a chosen folder, for the worktree picker.
struct BranchListing: Equatable, Sendable {
    var directory: String
    /// The repo's checked-out branch, offered as the default base.
    var current: String?
    var names: [String]
    var error: String?

    /// Current branch first, then the rest in the order git reported them —
    /// local before remote, which is the order you want to pick from.
    var ordered: [String] {
        guard let current, names.contains(current) else { return names }
        return [current] + names.filter { $0 != current }
    }
}

// MARK: - Quick commands

/// A one-tap snippet pushed by the desktop (`quick_commands`). Read-only on the
/// client for v1 — editing lives in Mac Settings.
struct QuickCommand: Identifiable, Codable, Hashable, Sendable {
    let label: String
    /// Literal text to submit. Mutually exclusive with `keys`.
    var text: String?
    /// Raw tmux key names to send in order, e.g. `["Down","Enter"]`.
    var keys: [String]?
    var isDestructive: Bool

    var id: String { label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "command"
        text = try? c.decode(String.self, forKey: .text)
        keys = try? c.decode([String].self, forKey: .keys)
        isDestructive = (try? c.decode(Bool.self, forKey: .isDestructive)) ?? false
    }

    init(label: String, text: String? = nil, keys: [String]? = nil, isDestructive: Bool = false) {
        self.label = label
        self.text = text
        self.keys = keys
        self.isDestructive = isDestructive
    }

    /// Shown before the desktop pushes its own set, so the composer is never
    /// empty on first launch.
    static let fallback: [QuickCommand] = [
        QuickCommand(label: "Continue", text: "continue"),
        QuickCommand(label: "Run tests", text: "Run the tests and show output"),
        QuickCommand(label: "/compact", text: "/compact"),
        QuickCommand(label: "Commit", text: "Commit and summarize"),
    ]
}

// MARK: - Diff

struct DiffResult: Codable, Equatable, Sendable {
    let sessionID: String
    let mode: DiffMode
    let stat: String
    let files: [DiffFile]
    let truncated: Bool

    struct DiffFile: Identifiable, Codable, Equatable, Sendable {
        let path: String
        let patch: String
        let additions: Int
        let deletions: Int
        var truncated: Bool

        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }

        enum CodingKeys: String, CodingKey { case path, patch, additions, deletions, truncated }

        /// Hand-written because Swift's synthesised decoder ignores default
        /// values — a missing `truncated` (which the protocol marks optional,
        /// and hosts omit for un-truncated files) made the whole entry throw,
        /// which silently emptied `files` and rendered a blank diff.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            patch = (try? c.decode(String.self, forKey: .patch)) ?? ""
            additions = (try? c.decode(Int.self, forKey: .additions)) ?? 0
            deletions = (try? c.decode(Int.self, forKey: .deletions)) ?? 0
            truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case mode, stat, files, truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? c.decode(String.self, forKey: .sessionID)) ?? ""
        mode = (try? c.decode(DiffMode.self, forKey: .mode)) ?? .working
        stat = (try? c.decode(String.self, forKey: .stat)) ?? ""
        files = (try? c.decode([DiffFile].self, forKey: .files)) ?? []
        truncated = (try? c.decode(Bool.self, forKey: .truncated)) ?? false
    }
}

enum DiffMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case working, staged, branch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .working: return "Working"
        case .staged:  return "Staged"
        case .branch:  return "Branch"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DiffMode(rawValue: raw) ?? .working
    }
}

// MARK: - Claude logins

/// One Claude login on a host, as that host's `accounts` message describes it:
/// the config dir that names it, who it is signed in as, and how much of its
/// five-hour and weekly windows are spent. Mirrors the desktop's
/// `ClaudeLoginOverview` wire shape.
struct ClaudeLogin: Hashable, Sendable, Identifiable {
    /// The config dir — the pool's key, and what `rotate_account` names.
    var dir: String
    /// `work-2` — what a row's `account` carries.
    var name: String
    var email: String?
    var fiveHour: Int?
    var fiveHourResetsAt: Date?
    var sevenDay: Int?
    var sevenDayResetsAt: Date?
    /// The model-scoped weekly window ("Fable"), when the host has probed it.
    var scoped: Int?
    var scopedLabel: String?
    var limitedUntil: Date?
    var needsSignIn: Bool

    var id: String { dir }
    var displayName: String { email ?? name }

    func isLimited(at now: Date = Date()) -> Bool { limitedUntil.map { $0 > now } ?? false }

    /// "5h 26% · 7d 7%", "limited until 4:30 PM", "sign in again" or "no reading".
    func headroom(at now: Date = Date()) -> String {
        if let until = limitedUntil, until > now {
            return "limited until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if needsSignIn { return "sign in again" }
        var parts: [String] = []
        if let p = fiveHour, fiveHourResetsAt.map({ $0 > now }) ?? true { parts.append("5h \(p)%") }
        if let p = sevenDay, sevenDayResetsAt.map({ $0 > now }) ?? true { parts.append("7d \(p)%") }
        if let p = scoped { parts.append("\(scopedLabel ?? "model") \(p)%") }
        return parts.isEmpty ? "no reading" : parts.joined(separator: " · ")
    }

    init(dir: String, name: String) {
        self.dir = dir
        self.name = name
        self.needsSignIn = false
    }

    init?(wire r: [String: Any]) {
        guard let dir = r["dir"] as? String, let name = r["name"] as? String else { return nil }
        func seconds(_ key: String) -> Date? {
            ((r[key] as? Double) ?? (r[key] as? Int).map(Double.init)).map { Date(timeIntervalSince1970: $0) }
        }
        func percent(_ key: String) -> Int? { (r[key] as? Int) ?? (r[key] as? Double).map { Int($0.rounded()) } }
        self.dir = dir
        self.name = name
        email = r["email"] as? String
        fiveHour = percent("fiveHour")
        fiveHourResetsAt = seconds("fiveHourResetsAt")
        sevenDay = percent("sevenDay")
        sevenDayResetsAt = seconds("sevenDayResetsAt")
        scoped = percent("scoped")
        scopedLabel = r["scopedLabel"] as? String
        limitedUntil = seconds("limitedUntil")
        needsSignIn = (r["needsSignIn"] as? Bool) ?? false
    }
}

/// One directory tree's logins on a host, primary first.
struct ClaudeLoginPool: Hashable, Sendable {
    /// The tree as the host spells it, so a row's `directory` matches by prefix.
    var pathPrefix: String
    var members: [ClaudeLogin]

    func covers(_ directory: String) -> Bool {
        directory == pathPrefix || directory.hasPrefix(pathPrefix + "/")
    }

    init?(wire r: [String: Any]) {
        guard let prefix = r["pathPrefix"] as? String else { return nil }
        pathPrefix = prefix
        members = ((r["members"] as? [[String: Any]]) ?? []).compactMap(ClaudeLogin.init(wire:))
    }
}

/// Everything one host said in its last `accounts` message.
struct HostLogins: Sendable {
    var pools: [ClaudeLoginPool]
    var defaultLogin: ClaudeLogin?

    /// The deepest tree that holds `directory`.
    func pool(for directory: String) -> ClaudeLoginPool? {
        pools.filter { $0.covers(directory) }.max { $0.pathPrefix.count < $1.pathPrefix.count }
    }
}
