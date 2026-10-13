import Foundation

// MARK: - Outbound

/// Everything this client can say to a host. Modelled as an enum so call sites
/// are typed and the wire encoding lives in exactly one place — the previous
/// version scattered `["type": "..."]` dictionary literals across the app and
/// three of them referred to verbs the desktop had never implemented.
enum BridgeOutbound {
    // Handshake
    case hello
    case attentionAction(id: String, action: String, eventID: String?, enabled: Bool)

    // Session list
    case listSessionsFull
    case listRecentDirs
    case listDirectory(path: String, showHidden: Bool = false)
    case listBranches(directory: String)
    case createSession(directory: String, label: String?, prompt: String?,
                       tool: SessionTool?, permission: PermissionMode?, worktree: WorktreeSpec?,
                       folder: String? = nil)
    case duplicateSession(id: String)
    /// Renames a session on the host. The label is the Mac's own — the same
    /// one its sidebar and voice matching use — so a rename here is a rename
    /// there, not a nickname this device keeps to itself.
    case renameSession(id: String, label: String)
    case closeSession(id: String)
    case killSession(id: String, confirm: Bool)
    /// The whole list of one machine's session ids in the order wanted, the
    /// same way the desktop's drag sends it. The host persists it, so it is
    /// the order every later `sessions_full` reports.
    case reorderSessions(order: [String])

    // Folders + hidden. `id` is the folder's for the folder verbs; the host
    // answers each with `action_result` and follows with a full push, the
    // only message that carries the folder list.
    case setSessionFolder(id: String, folder: String?)
    case setSessionHidden(id: String, hidden: Bool)
    /// The id is minted here so the row can be selected before the push lands.
    case createFolder(id: String, name: String)
    case renameFolder(id: String, name: String)
    /// "Ungroup": the folder goes, its sessions land loose.
    case deleteFolder(id: String)
    case setFolderHidden(id: String, hidden: Bool)
    case reorderFolders(order: [String])
    case unhideAll

    // Actions (WS-2)
    case sendInput(id: String, text: String, submit: Bool)
    case sendKeys(id: String, keys: [String])
    case interrupt(id: String)
    case approve(id: String, option: Int?)
    case deny(id: String)

    // Diff review
    case fetchDiff(id: String, mode: DiffMode, path: String?)

    // Terminal — frames (WS-3)
    /// `cols`/`rows` are omitted when this device is not asking the host to
    /// match its screen. Sending a size is a *request to resize*, so a default
    /// one would reshape someone's Mac window merely because a pane was opened.
    case attachTerminal(id: String, cols: Int?, rows: Int?)
    case resizeTerminal(id: String, cols: Int, rows: Int)
    case detachTerminal(id: String)
    case fetchScrollback(id: String, lines: Int, offset: Int)

    // Terminal — PTY (WS-3 §4.3)
    case ptyAttach(id: String)
    case ptyInput(id: String, base64: String)
    case ptyDetach(id: String)

    // Meetings (WS-6)
    case listMeetings
    case fetchMeeting(id: String)
    case startMeeting(mode: MeetingMode)
    case stopMeeting
    case askMeeting(id: String, question: String)
    case setActionItemDone(meetingID: String, itemID: String, done: Bool)
    /// Free-text notes edited on the device, saved back to the host's
    /// meeting folder alongside the AI-generated ones.
    case updateMeetingNotes(id: String, notes: String)
    /// Uploads a meeting this device recorded so the host can summarise it with
    /// the same Claude pipeline it uses for its own recordings.
    case pushLocalMeeting(meeting: [String: Any])

    // Videos — the host's recording library. Read, rename, delete: recording
    // and joining stay on the Mac, where the camera and the encoder are.
    case listVideos
    case renameVideo(id: String, title: String)
    case deleteVideo(id: String)

    // Agents (WS-7)
    case listAgents
    case runAgent(id: String, directory: String?)

    // Voice (unchanged from v1)
    case voiceClaim
    case voiceRelease
    case toolCall(callID: String, name: String, parameters: [String: Any])

    /// A screenshot from the phone, staged on the machine that will read it.
    /// `token` comes back on the reply: two images can be in flight for one
    /// session, and the chip that shows "staging…" has to know which path is
    /// its own.
    case putAttachment(id: String, token: String, name: String, mime: String, base64: String)

    /// Asks the host for its own vital signs. Answered with `stats`; gated on
    /// the `stats` capability, which protocol-1 hosts do not advertise.
    case fetchStats

    /// Asks the host for its Claude logins and their headroom. Answered with
    /// `accounts`, which the host also pushes whenever a reading changes.
    case fetchAccounts
    /// Moves a session to another Claude login in its tree's pool, keeping the
    /// conversation. `to` is the login's config dir; nil lets the host pick
    /// the one with the most headroom.
    case rotateAccount(id: String, to: String?)

    case ping

    struct WorktreeSpec {
        var branch: String
        /// Ref the new branch is cut from. Ignored when `isNewBranch` is false.
        var base: String
        /// False attaches the worktree to a branch that already exists —
        /// `worktree add <path> <branch>` rather than `worktree add -b`.
        var isNewBranch: Bool = true
    }

    var json: [String: Any] {
        switch self {
        case .attentionAction(let id, let action, let eventID, let enabled):
            var payload: [String: Any] = ["type": "attention_action", "id": id, "action": action, "enabled": enabled]
            if let eventID { payload["eventID"] = eventID }
            return payload
        case .hello:
            return [
                "type": "hello",
                "protocol": BridgeProtocolVersion.current,
                "capabilities": BridgeProtocolVersion.capabilities,
            ]

        case .listSessionsFull:
            return ["type": "list_sessions_full"]
        case .listRecentDirs:
            return ["type": "list_recent_dirs"]
        case .listDirectory(let path, let showHidden):
            return ["type": "list_directory", "path": path, "showHidden": showHidden]
        case .listBranches(let directory):
            return ["type": "list_branches", "directory": directory]

        case .createSession(let directory, let label, let prompt, let tool, let permission, let worktree, let folder):
            var p: [String: Any] = ["type": "create_session", "directory": directory]
            // "New session here" on a folder. Omitted when loose, and an id the
            // host no longer knows lands loose there too — never a failed create.
            if let folder, !folder.isEmpty { p["folder"] = folder }
            if let label, !label.isEmpty { p["label"] = label }
            if let prompt, !prompt.isEmpty { p["prompt"] = prompt }
            // The host has always read this and defaulted to Claude without it.
            if let tool { p["tool"] = tool.rawValue }
            // Omitted when nil so a host that predates this keeps its own
            // default rather than being handed a mode it cannot read.
            if let permission { p["permission"] = permission.rawValue }
            if let worktree {
                p["worktree"] = [
                    "branch": worktree.branch,
                    "base": worktree.base,
                    "newBranch": worktree.isNewBranch,
                ]
            }
            return p

        case .duplicateSession(let id):
            return ["type": "duplicate_session", "id": id]

        case .renameSession(let id, let label):
            return ["type": "rename_session", "id": id, "label": label]

        case .closeSession(let id):
            return ["type": "close_session", "id": id]
        case .killSession(let id, let confirm):
            return ["type": "kill_session", "id": id, "confirm": confirm]
        case .reorderSessions(let order):
            return ["type": "reorder_sessions", "order": order]

        case .setSessionFolder(let id, let folder):
            var p: [String: Any] = ["type": "set_session_folder", "id": id]
            // Absent means loose, which is what the host reads "" and null as too.
            if let folder { p["folder"] = folder }
            return p
        case .setSessionHidden(let id, let hidden):
            return ["type": "set_session_hidden", "id": id, "hidden": hidden]
        case .createFolder(let id, let name):
            return ["type": "create_folder", "id": id, "name": name]
        case .renameFolder(let id, let name):
            return ["type": "rename_folder", "id": id, "name": name]
        case .deleteFolder(let id):
            return ["type": "delete_folder", "id": id]
        case .setFolderHidden(let id, let hidden):
            return ["type": "set_folder_hidden", "id": id, "hidden": hidden]
        case .reorderFolders(let order):
            return ["type": "reorder_folders", "order": order]
        case .unhideAll:
            return ["type": "unhide_all"]

        case .sendInput(let id, let text, let submit):
            return ["type": "send_input", "id": id, "text": text, "submit": submit]
        case .sendKeys(let id, let keys):
            return ["type": "send_keys", "id": id, "keys": keys]
        case .interrupt(let id):
            return ["type": "interrupt", "id": id]
        case .approve(let id, let option):
            var p: [String: Any] = ["type": "approve", "id": id]
            if let option { p["option"] = option }
            return p
        case .deny(let id):
            return ["type": "deny", "id": id]

        case .fetchDiff(let id, let mode, let path):
            var p: [String: Any] = ["type": "fetch_diff", "id": id, "mode": mode.rawValue]
            if let path { p["path"] = path }
            return p

        case .attachTerminal(let id, let cols, let rows):
            var out: [String: Any] = ["type": "attach_terminal", "id": id]
            if let cols, let rows {
                out["cols"] = cols
                out["rows"] = rows
            }
            return out

        case .resizeTerminal(let id, let cols, let rows):
            return ["type": "resize_terminal", "id": id, "cols": cols, "rows": rows]
        case .detachTerminal(let id):
            return ["type": "detach_terminal", "id": id]
        case .fetchScrollback(let id, let lines, let offset):
            return ["type": "fetch_scrollback", "id": id, "lines": lines, "offset": offset]

        case .ptyAttach(let id):
            return ["type": "pty_attach", "id": id]
        case .ptyInput(let id, let base64):
            return ["type": "pty_input", "id": id, "b64": base64]
        case .ptyDetach(let id):
            return ["type": "pty_detach", "id": id]

        case .listMeetings:
            return ["type": "list_meetings"]
        case .fetchMeeting(let id):
            return ["type": "fetch_meeting", "id": id]
        case .startMeeting(let mode):
            return ["type": "start_meeting", "mode": mode.rawValue]
        case .stopMeeting:
            return ["type": "stop_meeting"]
        case .askMeeting(let id, let question):
            return ["type": "meeting_ask", "id": id, "question": question]
        case .setActionItemDone(let meetingID, let itemID, let done):
            return ["type": "meeting_action_done", "id": meetingID, "itemId": itemID, "done": done]
        case .updateMeetingNotes(let id, let notes):
            return ["type": "meeting_update_notes", "id": id, "notes": notes]
        case .pushLocalMeeting(let meeting):
            return ["type": "push_local_meeting", "meeting": meeting]

        case .listVideos:
            return ["type": "list_videos"]
        case .renameVideo(let id, let title):
            return ["type": "rename_video", "id": id, "title": title]
        case .deleteVideo(let id):
            return ["type": "delete_video", "id": id]

        case .listAgents:
            return ["type": "list_agents"]
        case .runAgent(let id, let directory):
            var p: [String: Any] = ["type": "run_agent", "id": id]
            if let directory { p["directory"] = directory }
            return p

        case .voiceClaim:
            return ["type": "voice_claim"]
        case .voiceRelease:
            return ["type": "voice_release"]
        case .toolCall(let callID, let name, let parameters):
            return [
                "type": "tool_call",
                "tool_call_id": callID,
                "name": name,
                "parameters": parameters,
            ]

        case .putAttachment(let id, let token, let name, let mime, let base64):
            return ["type": "put_attachment", "id": id, "token": token,
                    "name": name, "mime": mime, "data": base64]

        case .fetchStats:
            return ["type": "fetch_stats"]

        case .fetchAccounts:
            return ["type": "fetch_accounts"]
        case .rotateAccount(let id, let to):
            var p: [String: Any] = ["type": "rotate_account", "id": id]
            if let to { p["to"] = to }
            return p

        case .ping:
            return ["type": "ping"]
        }
    }

    /// Verbs that mutate a session. Used to decide whether an `action_result`
    /// failure deserves surfacing to the user.
    var isAction: Bool {
        switch self {
        case .sendInput, .sendKeys, .interrupt, .approve, .deny, .killSession:
            return true
        default:
            return false
        }
    }
}

// MARK: - Inbound

struct HelloAck: Sendable {
    var protocolVersion: Int
    var capabilities: Set<String>
    var instanceKind: String
    var clientID: String?
    var staleAfterSec: Double

    var supportsDelta: Bool    { capabilities.contains("delta") }
    var supportsActions: Bool  { capabilities.contains("actions") }
    var supportsTerminal: Bool { capabilities.contains("terminal") }
    var supportsPTY: Bool      { capabilities.contains("pty") }
    var supportsDiff: Bool     { capabilities.contains("diff") }
    /// Whether the host will size its tmux window to this device's grid. A host
    /// without it keeps its desk-sized pane and the phone just scrolls.
    var supportsResize: Bool   { capabilities.contains("resize") }
    /// Whether the host can rename a session. Gated rather than assumed: an
    /// older desktop drops `rename_session` on the floor, and a rename control
    /// that silently does nothing is worse than one that isn't there.
    var supportsRename: Bool   { capabilities.contains("rename") }
    /// Whether the host serves its video library. Same gate as rename: an
    /// older desktop answers `list_videos` with nothing at all, and an empty
    /// tab that can never fill is worse than no tab.
    var supportsVideos: Bool   { capabilities.contains("videos") }
    /// Whether the host reports its own vitals. Gated because a host without
    /// it never answers `fetch_stats`, and a Machines screen that spins
    /// forever is worse than one that says the host cannot tell you.
    var supportsStats: Bool    { capabilities.contains("stats") }
    /// Whether the host will stage an image for a session. Gated like the rest:
    /// an older desktop drops `put_attachment` silently, and an attach button
    /// that produces nothing is worse than no button.
    var supportsAttachments: Bool { capabilities.contains("attachments") }
    /// Whether the host keeps session folders and answers the folder verbs.
    /// Gated like the rest: a box whose agent predates folders drops
    /// `create_folder` on the floor, and a folder that never appears is worse
    /// than a menu without the item.
    var supportsFolders: Bool { capabilities.contains("folders") }
    /// Whether the host persists a client-sent order.
    var supportsReorder: Bool { capabilities.contains("reorder") }
    /// Whether the host keeps Claude login pools and answers `rotate_account`.
    var supportsAccounts: Bool { capabilities.contains("accounts") }
}

struct ActionResult: Sendable {
    var action: String
    var sessionID: String?
    var ok: Bool
    var error: String?
}

struct TerminalFrame: Sendable {
    var sessionID: String
    var seq: Int
    var ansi: String
    var cursorRow: Int?
    /// The grid the host actually drew this frame at, when it says so.
    ///
    /// Not the same as the grid we asked for: tmux clamps, the host has floors
    /// of its own, and a resize is refused outright while a dialog is on
    /// screen. Trusting the request instead of the answer would leave the pane
    /// laid out for a width the text was never rendered to.
    var cols: Int?
    var rows: Int?
}

struct ScrollbackChunk: Sendable {
    var sessionID: String
    var ansi: String
    var offset: Int
    var lines: Int
    var more: Bool
}

struct VoiceClaimGrant: Sendable {
    var signedURL: URL
    var context: String
    var voiceID: String?
}

/// One decoded message from a host. Unknown types decode to `.unknown` rather
/// than throwing — the desktop is developed in parallel and will grow verbs
/// this build has never heard of.
enum BridgeInbound: Sendable {
    case helloAck(HelloAck)

    /// The folder list rides here and only here: a folder edit is a full push.
    case sessionsFull(rows: [SessionRow], folders: [SessionFolder])
    case sessionsDelta(seq: Int, changed: [SessionRow], removed: [String])
    case quickCommands([QuickCommand])

    case sessionCreated(id: String, label: String, directory: String?)
    case sessionCreateFailed(error: String)
    case sessionClosed(id: String)
    case sessionCloseFailed(error: String)
    case directoryListing(DirectoryListing)
    case recentDirs([String])
    case branches(BranchListing)

    case actionResult(ActionResult)
    case diffResult(DiffResult)

    case terminalFrame(TerminalFrame)
    case scrollbackChunk(ScrollbackChunk)
    case ptyAttached(sessionID: String, cols: Int, rows: Int)
    case ptyOutput(sessionID: String, seq: Int, base64: String)
    case ptyExited(sessionID: String, reason: String)

    case meetingsFull([Meeting])
    case meetingDetail(Meeting)
    /// Pushed while a host recording is in flight.
    case meetingLive(id: String, elapsedSec: Int, newSegments: [TranscriptSegment])
    case meetingStopped(id: String)
    case meetingAskReply(id: String, text: String)
    /// The host confirming it stored a meeting this device pushed. Without it
    /// an upload has no completion, so the outbox cannot tell "sent" from
    /// "arrived" and would either re-send forever or forget too early.
    case localMeetingAck(id: String, ok: Bool, error: String?)
    case videosFull([VideoItem])
    case agentsFull([BridgeAgent])
    case agentStarted(sessionID: String)

    case stats(MachineStats)
    case accounts(HostLogins)

    /// Answer to `put_attachment`: where the file landed on the machine that
    /// will read it, or why it did not.
    case attachmentStaged(sessionID: String?, token: String, path: String?, name: String?, error: String?)

    case homeInfo(name: String?, machineName: String?, kind: String?)
    case voiceClaimResponse(Result<VoiceClaimGrant, BridgeError>)
    case voiceState(by: String)
    case toolResult(callID: String, result: String, isError: Bool)

    case unknown(type: String)
}

struct BridgeError: Error, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Decoding

enum BridgeDecoder {
    /// Decodes a payload dictionary (already unwrapped from the relay envelope).
    ///
    /// Takes `[String: Any]` rather than `Data` because the relay hands us the
    /// payload nested inside its own envelope, and re-serializing just to run
    /// `JSONDecoder` over it would be wasteful. Row-shaped members still go
    /// through `Codable` via `decode(_:from:)`.
    static func decode(payload: [String: Any]) -> BridgeInbound {
        guard let type = payload["type"] as? String else { return .unknown(type: "<missing>") }

        switch type {
        case "hello_ack":
            let caps = (payload["capabilities"] as? [String]) ?? []
            return .helloAck(HelloAck(
                protocolVersion: (payload["protocol"] as? Int) ?? 1,
                capabilities: Set(caps),
                instanceKind: (payload["instanceKind"] as? String) ?? "udha-desktop",
                clientID: payload["clientId"] as? String,
                staleAfterSec: (payload["staleAfterSec"] as? Double) ?? 1800
            ))

        case "sessions_full":
            return .sessionsFull(rows: rows(payload["sessions"]),
                                 folders: reencode(payload["folders"], as: [SessionFolder].self) ?? [])

        case "sessions_delta":
            return .sessionsDelta(
                seq: (payload["seq"] as? Int) ?? 0,
                changed: rows(payload["changed"]),
                removed: (payload["removed"] as? [String]) ?? []
            )

        case "quick_commands":
            return .quickCommands(reencode(payload["commands"], as: [QuickCommand].self) ?? [])

        case "session_created":
            return .sessionCreated(
                id: (payload["id"] as? String) ?? "",
                label: (payload["label"] as? String) ?? "",
                directory: payload["directory"] as? String
            )
        case "session_create_failed":
            return .sessionCreateFailed(error: (payload["error"] as? String) ?? "create failed")
        case "session_closed":
            return .sessionClosed(id: (payload["id"] as? String) ?? "")
        case "session_close_failed":
            return .sessionCloseFailed(error: (payload["error"] as? String) ?? "close failed")

        case "directory_listing":
            if let listing = reencode(payload, as: DirectoryListing.self) {
                return .directoryListing(listing)
            }
            return .unknown(type: type)

        case "recent_dirs":
            return .recentDirs((payload["directories"] as? [String]) ?? [])

        case "branches":
            return .branches(BranchListing(
                directory: (payload["directory"] as? String) ?? "",
                current: payload["current"] as? String,
                names: (payload["branches"] as? [String]) ?? [],
                error: payload["error"] as? String
            ))

        case "action_result":
            return .actionResult(ActionResult(
                action: (payload["action"] as? String) ?? "",
                sessionID: payload["id"] as? String,
                ok: (payload["ok"] as? Bool) ?? false,
                error: payload["error"] as? String
            ))

        case "diff_result":
            if let diff = reencode(payload, as: DiffResult.self) {
                return .diffResult(diff)
            }
            return .unknown(type: type)

        case "terminal_frame":
            return .terminalFrame(TerminalFrame(
                sessionID: (payload["id"] as? String) ?? "",
                seq: (payload["seq"] as? Int) ?? 0,
                ansi: (payload["ansi"] as? String) ?? "",
                cursorRow: payload["cursorRow"] as? Int,
                cols: payload["cols"] as? Int,
                rows: payload["rows"] as? Int
            ))

        case "scrollback_chunk":
            return .scrollbackChunk(ScrollbackChunk(
                sessionID: (payload["id"] as? String) ?? "",
                ansi: (payload["ansi"] as? String) ?? "",
                offset: (payload["offset"] as? Int) ?? 0,
                lines: (payload["lines"] as? Int) ?? 0,
                more: (payload["more"] as? Bool) ?? false
            ))

        case "pty_attached":
            return .ptyAttached(
                sessionID: (payload["id"] as? String) ?? "",
                cols: (payload["cols"] as? Int) ?? 80,
                rows: (payload["rows"] as? Int) ?? 24
            )
        case "pty_output":
            return .ptyOutput(
                sessionID: (payload["id"] as? String) ?? "",
                seq: (payload["seq"] as? Int) ?? 0,
                base64: (payload["b64"] as? String) ?? ""
            )
        case "pty_exited":
            return .ptyExited(
                sessionID: (payload["id"] as? String) ?? "",
                reason: (payload["reason"] as? String) ?? "detached"
            )

        case "meetings_full":
            return .meetingsFull(reencode(payload["meetings"], as: [Meeting].self) ?? [])

        case "meeting_detail":
            if let m = reencode(payload["meeting"], as: Meeting.self) { return .meetingDetail(m) }
            return .unknown(type: type)

        case "meeting_live":
            return .meetingLive(
                id: (payload["id"] as? String) ?? "",
                elapsedSec: (payload["elapsedSec"] as? Int) ?? 0,
                newSegments: reencode(payload["segments"], as: [TranscriptSegment].self) ?? []
            )

        case "meeting_stopped":
            return .meetingStopped(id: (payload["id"] as? String) ?? "")

        case "meeting_ask_reply":
            return .meetingAskReply(
                id: (payload["id"] as? String) ?? "",
                text: (payload["text"] as? String) ?? ""
            )

        case "push_local_meeting_ack":
            return .localMeetingAck(
                id: (payload["id"] as? String) ?? "",
                ok: (payload["ok"] as? Bool) ?? false,
                error: payload["error"] as? String
            )

        case "videos_full":
            return .videosFull(reencode(payload["videos"], as: [VideoItem].self) ?? [])

        case "agents_full":
            return .agentsFull(reencode(payload["agents"], as: [BridgeAgent].self) ?? [])

        case "agent_started":
            return .agentStarted(sessionID: (payload["sessionId"] as? String) ?? "")

        case "stats":
            return .stats(MachineStats(wire: (payload["stats"] as? [String: Any]) ?? [:]))

        case "accounts":
            return .accounts(HostLogins(
                pools: ((payload["pools"] as? [[String: Any]]) ?? []).compactMap(ClaudeLoginPool.init(wire:)),
                defaultLogin: (payload["default"] as? [String: Any]).flatMap(ClaudeLogin.init(wire:))
            ))

        case "attachment_staged":
            return .attachmentStaged(
                sessionID: payload["id"] as? String,
                token: (payload["token"] as? String) ?? "",
                path: payload["path"] as? String,
                name: payload["name"] as? String,
                error: payload["error"] as? String
            )

        case "home_info":
            return .homeInfo(
                name: payload["name"] as? String,
                machineName: payload["machineName"] as? String,
                kind: payload["kind"] as? String
            )

        case "voice_claim_response":
            let ok = (payload["ok"] as? Bool) ?? false
            guard ok else {
                let msg = (payload["error"] as? String) ?? "voice claim rejected"
                return .voiceClaimResponse(.failure(BridgeError(message: msg)))
            }
            guard let raw = payload["signed_url"] as? String, let url = URL(string: raw) else {
                return .voiceClaimResponse(.failure(BridgeError(message: "malformed signed_url")))
            }
            return .voiceClaimResponse(.success(VoiceClaimGrant(
                signedURL: url,
                context: (payload["context"] as? String) ?? "",
                voiceID: payload["voice_id"] as? String
            )))

        case "voice_state":
            return .voiceState(by: (payload["by"] as? String) ?? "none")

        case "tool_result":
            return .toolResult(
                callID: (payload["tool_call_id"] as? String) ?? "",
                result: (payload["result"] as? String) ?? "",
                isError: (payload["is_error"] as? Bool) ?? false
            )

        default:
            return .unknown(type: type)
        }
    }

    private static func rows(_ raw: Any?) -> [SessionRow] {
        reencode(raw, as: [SessionRow].self) ?? []
    }

    /// Bridges the untyped relay payload into `Codable`. The relay hands us
    /// `[String: Any]` from `JSONSerialization`; round-tripping through `Data`
    /// is the cheapest way to reuse the row decoders rather than maintaining a
    /// second hand-written unpacker for every field.
    private static func reencode<T: Decodable>(_ raw: Any?, as type: T.Type) -> T? {
        guard let raw, JSONSerialization.isValidJSONObject(raw) || raw is [Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - send_keys validation

/// Mirrors the desktop's validator. Enforced client-side too so a malformed
/// sequence is caught before it costs a round trip — the desktop still
/// re-validates, because a client is never the security boundary.
enum TmuxKey {
    private static let named: Set<String> = [
        "Up", "Down", "Left", "Right", "Enter", "Escape", "Tab", "BTab", "Space",
        "PPage", "NPage", "Home", "End", "BSpace", "DC", "IC",
    ]

    static func isValid(_ key: String) -> Bool {
        if key.count == 1, let c = key.first, c.isLetter || c.isNumber { return true }
        if named.contains(key) { return true }
        // Modifier chords: C-c, M-x, S-Tab
        if key.count >= 3 {
            let parts = key.split(separator: "-", maxSplits: 1)
            if parts.count == 2, ["C", "M", "S"].contains(String(parts[0])) { return true }
        }
        // Function keys F1–F12
        if key.hasPrefix("F"), key.count <= 3, Int(key.dropFirst()) != nil { return true }
        return false
    }

    static func validate(_ keys: [String]) -> Bool {
        !keys.isEmpty && keys.allSatisfy(isValid)
    }
}
