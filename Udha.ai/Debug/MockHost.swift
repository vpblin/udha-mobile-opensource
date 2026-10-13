#if DEBUG
import Foundation
import os

/// A fake desktop that speaks protocol v2, for testing the client with no
/// relay, no Auth0 and no Mac.
///
/// It drives the **real** `UdhaBridge` through its normal inbound path, so what
/// gets exercised is the actual decoder, delta merge, sequence-gap recovery and
/// action plumbing — not a parallel test-only implementation. Activated solely
/// by the `--udha-mock` launch argument; the whole file compiles out of release.
@MainActor
final class MockHost {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--udha-mock")
    }

    /// Drops the fleet into states that are otherwise hard to reach on demand.
    enum Scenario: String {
        case standard      // a realistic mixed fleet
        case empty         // no sessions
        case allBlocked    // everything needs a human
        /// Every string as long and as ugly as the real fleet makes them.
        ///
        /// The polite fixtures above are why a row that refused to truncate
        /// shipped: "Running npm test" fits anywhere, and a real `usingTool`
        /// detail is `S=/tmp/claude-1000/-home-dev-projects-acme…`.
        /// Layout is only tested when the data fights back.
        case longform
    }

    static var scenario: Scenario {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--udha-scenario=") {
            let raw = String(argument.dropFirst("--udha-scenario=".count))
            if let parsed = Scenario(rawValue: raw) { return parsed }
        }
        return .standard
    }

    /// `--udha-mute-terminal` makes the host accept `attach_terminal` and then
    /// answer nothing — the shape of a pane that has silently died. It is the
    /// one failure the client cannot manufacture for itself, and the only way
    /// to see the stale bar without unplugging a real Mac.
    static var muteTerminal: Bool {
        ProcessInfo.processInfo.arguments.contains("--udha-mute-terminal")
    }

    /// `--udha-select=N` opens the Nth session (0-based) instead of the first.
    /// The seeded fleet's first session is deliberately blocked on a dialog, so
    /// without this there is no way to reach a *running* session's pane from a
    /// launch argument — and several behaviours (terminal resize among them)
    /// only apply when no dialog is on screen.
    static var autoSelectIndex: Int? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--udha-select=") {
            return Int(argument.dropFirst("--udha-select=".count))
        }
        return nil
    }

    /// `--udha-screen=diff|terminal|new|voice` opens that screen on launch.
    /// Synthetic clicks don't reach SwiftUI inside the Simulator, so this is how
    /// screens behind a tap get exercised and screenshotted.
    static var autoScreen: String? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--udha-screen=") {
            return String(argument.dropFirst("--udha-screen=".count))
        }
        return nil
    }

    private unowned let bridge: UdhaBridge
    private var rows: [String: [String: Any]] = [:]
    /// A library with one of each shape worth designing against: shared,
    /// local-only, still rendering, and one that failed.
    private var videoRows: [[String: Any]] = [
        ["id": "v1", "title": "Intake demo — v3",
         "createdAt": Date().addingTimeInterval(-86_400).timeIntervalSince1970,
         "durationSec": 192.0, "stage": "ready",
         "hasCamera": true, "hasMic": true, "hasSystemAudio": true,
         "orientations": ["landscape", "portrait"],
         "shareURL": "https://example.com/v/intake-demo-v3",
         "isPasswordProtected": true,
         "publishedAt": Date().addingTimeInterval(-80_000).timeIntervalSince1970,
         "busy": false],
        ["id": "v2", "title": "Worktree walkthrough",
         "createdAt": Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970,
         "durationSec": 634.0, "stage": "ready",
         "hasCamera": false, "hasMic": true, "hasSystemAudio": false,
         "orientations": ["landscape"], "busy": false],
        ["id": "v3", "title": "Relay retry explainer",
         "createdAt": Date().addingTimeInterval(-1_800).timeIntervalSince1970,
         "durationSec": 88.0, "stage": "composing",
         "hasCamera": true, "hasMic": true, "hasSystemAudio": false,
         "orientations": [] as [String], "busy": true],
        ["id": "v4", "title": "Recording Aug 12, 09:14",
         "createdAt": Date().addingTimeInterval(-18 * 86_400).timeIntervalSince1970,
         "durationSec": 12.0, "stage": "failed",
         "failureReason": "Recording stopped unexpectedly before any video was written.",
         "hasCamera": false, "hasMic": false, "hasSystemAudio": false,
         "orientations": [] as [String], "busy": false],
    ]
    private var order: [String] = []
    /// This machine's folders, in board order — the same shape the desktop
    /// publishes beside `sessions_full`.
    private var folders: [[String: Any]] = []
    private var seq = 0
    private var ticker: Task<Void, Never>?
    /// The host recording this mock is pretending to run, if any.
    private var mockLiveID: String?
    private var liveTicker: Task<Void, Never>?
    /// Last grid the client asked for, echoed back on every frame.
    private var grid: (cols: Int, rows: Int)?
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "mock")

    init(bridge: UdhaBridge) {
        self.bridge = bridge
        seed()
        bridge.mockOutbound = { [weak self] payload in
            // Hop off the current call stack so the bridge finishes its own
            // send before the "host" answers — the real transport is async too,
            // and a synchronous reply would mask reentrancy bugs.
            Task { @MainActor in self?.handle(payload) }
        }
    }

    private var statsTick = 0

    func start() {
        let mac = BridgeInstance(
            id: "mock-macbook",
            name: "MacBook",
            machineName: "Alex's MacBook Pro",
            isOnline: true,
            kind: "udha-desktop"
        )
        // A second machine under `longform`, because "one list, every machine"
        // is not a thing a single-host mock can show is working.
        let box = BridgeInstance(
            id: "mock-devbox",
            name: "devbox",
            machineName: "devbox",
            isOnline: true,
            kind: "udha-headless"
        )
        let fleet = MockHost.scenario == .longform ? [box] : []
        bridge.mockActivate(instance: mac, alongside: fleet)
        guard !fleet.isEmpty else { return }
        // The box answers for itself: its own handshake and its own sessions,
        // exactly as a second relay subscription delivers them.
        bridge.mockInject([
            "type": "hello_ack",
            "protocol": 2,
            "capabilities": ["delta", "actions", "terminal", "diff", "rename", "stats", "resize"],
            "instanceKind": "udha-headless",
            "staleAfterSec": 1800,
        ], from: box.id)
        bridge.mockInject(["type": "sessions_full", "sessions": boxRows()], from: box.id)
    }

    /// What devbox reports about itself — untagged, because these are its own.
    private func boxRows() -> [[String: Any]] {
        [
            makeRow(id: "box-1", label: "acme-platform",
                    directory: "/home/dev/projects/acme/acme-platform",
                    phase: "thinking", attention: "working", detail: "reading the schema"),
            makeRow(id: "box-2", label: "whisper-stt",
                    directory: "/home/dev/whisper-stt",
                    phase: "awaitingApproval", attention: "needsYou",
                    detail: "Restart the systemd --user unit?"),
            {
                var asked = makeRow(id: "box-4", label: "search-agent",
                                    directory: "/home/dev/projects/work/search-agent",
                                    phase: "awaitingReply", attention: "needsYou",
                                    detail: nil, state: "idle")
                // Deliberately a stray line of pane output, which is what the
                // host actually hands over when its question parse misfires.
                asked["lastQuestion"] = "184 -     private var lastSeq: Int?"
                return asked
            }(),
            makeRow(id: "box-3", label: "billing main",
                    directory: "/home/dev/projects/work/billing/main",
                    phase: "idle", attention: "quiet", detail: nil, state: "idle"),
        ]
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Inbound from the client

    private func handle(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        let id = payload["id"] as? String

        switch type {
        case "hello":
            bridge.mockInject([
                "type": "hello_ack",
                "protocol": 2,
                "capabilities": ["delta", "actions", "terminal", "pty", "diff", "push", "resize",
                                 "rename", "reorder", "videos", "stats", "folders"],
                "instanceKind": "udha-desktop",
                "clientId": "mock-client-1",
                "staleAfterSec": 1800,
            ])
            bridge.mockInject(["type": "quick_commands", "commands": [
                ["label": "Continue", "text": "continue"],
                ["label": "Run tests", "text": "Run the tests and show output"],
                ["label": "/compact", "text": "/compact"],
                ["label": "Commit", "text": "Commit and summarize"],
                ["label": "Reset --hard", "text": "git reset --hard", "isDestructive": true],
            ]])

        case "list_sessions_full":
            sendFull()
            startTicking()

        case "fetch_stats":
            sendStats()

        case "list_recent_dirs":
            bridge.mockInject(["type": "recent_dirs", "directories": [
                "/Users/alex/code/health-tracker",
                "/Users/alex/code/udha-mobile",
                "/Users/alex/code/site-builder",
            ]])

        case "list_directory":
            let path = (payload["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/Users/alex"
            // Under ~/code everything is a repo; elsewhere nothing is. Enough
            // to exercise both sides of the badge.
            let inCode = path.hasSuffix("/code")
            let names = inCode
                ? ["health-tracker", "udha-mobile", "site-builder"]
                : ["code", "Documents", "Downloads"]
            bridge.mockInject([
                "type": "directory_listing",
                "path": path,
                "parent": (path as NSString).deletingLastPathComponent,
                "entries": names.map {
                    ["name": $0,
                     "path": (path as NSString).appendingPathComponent($0),
                     "isRepo": inCode]
                },
            ])

        case "list_branches":
            let dir = (payload["directory"] as? String) ?? ""
            bridge.mockInject([
                "type": "branches",
                "directory": dir,
                "current": "main",
                "branches": ["main", "udha/cov-a3f2", "feature/intake", "origin/main"],
            ])

        // --- actions -------------------------------------------------------
        case "attention_action":
            guard let id, var row = rows[id], let raw = row["attentionState"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  var state = try? JSONDecoder().decode(SessionAttentionState.self, from: data) else { return }
            let action = payload["action"] as? String
            switch action {
            case "watch": state.notifyWhenDone = payload["enabled"] as? Bool ?? false
            case "reviews": state.notifyReviews = payload["enabled"] as? Bool ?? false
            case "completions": state.notifyCompletions = payload["enabled"] as? Bool ?? false
            default:
                if let i = state.events.firstIndex(where: { $0.id == payload["eventID"] as? String }) {
                    if action == "snooze" { state.events[i].snoozedUntil = Date().timeIntervalSince1970 + 900 }
                    else { state.events[i].state = .dismissed }
                }
            }
            row["attentionState"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
            rows[id] = row
            pushDelta(changed: [id])
            ack(type, id: id, ok: true)

        case "send_input", "send_keys", "interrupt", "kill_session":
            ack(type, id: id, ok: true)
            if let id { advance(id, to: "thinking", detail: "Working on your reply") }

        case "approve":
            log.info("approve option=\(String(describing: payload["option"] as? Int))")
            fallthrough

        case "deny":
            // The safety-critical guard: refuse unless a dialog is really up.
            guard let id, let row = rows[id],
                  (row["phase"] as? String) == "awaitingApproval" else {
                ack(type, id: id, ok: false, error: "no dialog visible")
                return
            }
            ack(type, id: id, ok: true)
            advance(id, to: type == "approve" ? "usingTool" : "awaitingReply",
                    detail: type == "approve" ? "Editing IntakeForm.swift" : "Denied — what next?")

        case "rename_session":
            let label = ((payload["label"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id, var row = rows[id], !label.isEmpty else {
                ack(type, id: id, ok: false, error: "unknown session")
                return
            }
            row["label"] = label
            rows[id] = row
            ack(type, id: id, ok: true)
            // The delta is what the real host sends back, and it is what the
            // client trusts over its own optimistic edit.
            pushDelta(changed: [id])

        // Folders + hidden: applied, acked, and answered with a full push —
        // which is the one message that carries the folder list, exactly as
        // the desktop does it.
        case "set_session_folder":
            let folder = payload["folder"] as? String
            guard let id, var row = rows[id], folder == nil || folderIndex(folder) != nil else {
                ack(type, id: id, ok: false, error: "unknown folder")
                return
            }
            row["folder"] = folder
            rows[id] = row
            ack(type, id: id, ok: true)
            pushDelta(changed: [id])

        case "set_session_hidden":
            guard let id, var row = rows[id] else {
                ack(type, id: id, ok: false, error: "unknown session")
                return
            }
            let hidden = (payload["hidden"] as? Bool) ?? true
            if hidden { row["hidden"] = true } else { row["hidden"] = nil }
            rows[id] = row
            ack(type, id: id, ok: true)
            pushDelta(changed: [id])

        case "create_folder":
            let name = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                ack(type, id: id, ok: false, error: "empty name")
                return
            }
            let folderID = id ?? UUID().uuidString
            if folderIndex(folderID) == nil { folders.insert(["id": folderID, "name": name], at: 0) }
            ack(type, id: folderID, ok: true)
            sendFull()

        case "rename_folder":
            let name = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let i = folderIndex(id), !name.isEmpty else {
                ack(type, id: id, ok: false, error: "unknown folder")
                return
            }
            folders[i]["name"] = name
            ack(type, id: id, ok: true)
            sendFull()

        case "delete_folder":
            guard let id, let i = folderIndex(id) else {
                ack(type, id: id, ok: false, error: "unknown folder")
                return
            }
            folders.remove(at: i)
            for key in rows.keys where (rows[key]?["folder"] as? String) == id { rows[key]?["folder"] = nil }
            ack(type, id: id, ok: true)
            sendFull()

        case "set_folder_hidden":
            guard let i = folderIndex(id) else {
                ack(type, id: id, ok: false, error: "unknown folder")
                return
            }
            let hidden = (payload["hidden"] as? Bool) ?? true
            if hidden { folders[i]["hidden"] = true } else { folders[i]["hidden"] = nil }
            ack(type, id: id, ok: true)
            sendFull()

        case "reorder_folders":
            let ids = (payload["order"] as? [String]) ?? []
            guard !ids.isEmpty else {
                ack(type, id: nil, ok: false, error: "empty order")
                return
            }
            let byID = Dictionary(uniqueKeysWithValues: folders.compactMap { f in (f["id"] as? String).map { ($0, f) } })
            var next = ids.compactMap { byID[$0] }
            let seen = Set(ids)
            next += folders.filter { !seen.contains(($0["id"] as? String) ?? "") }
            folders = next
            ack(type, id: nil, ok: true)
            sendFull()

        case "reorder_sessions":
            let ids = (payload["order"] as? [String]) ?? []
            guard !ids.isEmpty else {
                ack(type, id: nil, ok: false, error: "empty order")
                return
            }
            var next = ids.filter { rows[$0] != nil }
            next += order.filter { !next.contains($0) }
            order = next
            ack(type, id: nil, ok: true)
            sendFull()

        case "unhide_all":
            for i in folders.indices { folders[i]["hidden"] = nil }
            for key in rows.keys { rows[key]?["hidden"] = nil }
            ack(type, id: nil, ok: true)
            sendFull()

        case "close_session":
            if let id { remove(id) }

        case "fetch_diff":
            sendDiff(id: id ?? "", mode: (payload["mode"] as? String) ?? "branch")

        case "attach_terminal":
            guard !MockHost.muteTerminal else { return }
            noteGrid(payload)
            sendFrame(id: id ?? "")

        case "resize_terminal":
            noteGrid(payload)
            bridge.mockInject(["type": "action_result", "action": "resize_terminal",
                               "id": id ?? "", "ok": true])
            sendFrame(id: id ?? "")

        case "fetch_scrollback":
            let offset = (payload["offset"] as? Int) ?? 0
            let lines = (payload["lines"] as? Int) ?? 500
            bridge.mockInject([
                "type": "scrollback_chunk",
                "id": id ?? "",
                "ansi": (0..<8).map { "\u{1B}[2mhistory line \(offset + $0) — earlier output\u{1B}[0m" }
                    .joined(separator: "\n"),
                "offset": offset,
                "lines": lines,
                "more": offset < 1000,
            ])

        // --- videos ----------------------------------------------------------
        case "list_videos":
            bridge.mockInject(["type": "videos_full", "videos": videoRows])

        case "rename_video":
            let title = ((payload["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id, let index = videoRows.firstIndex(where: { $0["id"] as? String == id }),
                  !title.isEmpty else {
                ack(type, id: id, ok: false, error: "unknown video")
                return
            }
            videoRows[index]["title"] = title
            ack(type, id: id, ok: true)
            bridge.mockInject(["type": "videos_full", "videos": videoRows])

        case "delete_video":
            guard let id, let index = videoRows.firstIndex(where: { $0["id"] as? String == id })
            else {
                ack(type, id: id, ok: false, error: "unknown video")
                return
            }
            guard (videoRows[index]["busy"] as? Bool) != true else {
                ack(type, id: id, ok: false, error: "still rendering")
                return
            }
            videoRows.remove(at: index)
            ack(type, id: id, ok: true)
            bridge.mockInject(["type": "videos_full", "videos": videoRows])

        case "list_meetings":
            bridge.mockInject(["type": "meetings_full", "meetings": meetingRows()])

        case "fetch_meeting":
            guard let id, let detail = meetingDetail(id) else { break }
            bridge.mockInject(["type": "meeting_detail", "meeting": detail])

        case "list_agents":
            bridge.mockInject(["type": "agents_full", "agents": agentRows()])

        case "push_local_meeting":
            // Mirrors the real host: ack as soon as it is stored, then summarise
            // and echo the finished meeting back under *the same id* the phone
            // sent. Minting a new one here would hide the exact bug this
            // fixture exists to catch.
            guard let m = payload["meeting"] as? [String: Any],
                  let mid = m["id"] as? String else {
                bridge.mockInject(["type": "push_local_meeting_ack", "ok": false,
                                   "error": "malformed meeting payload"])
                break
            }
            bridge.mockInject(["type": "push_local_meeting_ack", "id": mid, "ok": true])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                var done = m
                done["finalized"] = true
                done["summary"] = "A short working call. The main thread was the retention "
                    + "cliff around month eleven and whether QA should sit with a dedicated "
                    + "owner rather than being spread across teams."
                done["notesMarkdown"] = """
                    ## Retention
                    The **month-11 cliff** lines up with the end of the big deliverables — \
                    the invoice does not change but the visible work does.

                    ## QA
                    Spread across teams today. A single owner was agreed.
                    """
                done["decisions"] = ["Give QA a single owner.", "Pull the month-11 cohort data."]
                done["actionItems"] = [
                    ["id": "l1", "text": "Pull retention by tenure cohort", "owner": "Me", "done": false],
                    ["id": "l2", "text": "Draft the QA ownership proposal", "owner": "Me", "done": false],
                ]
                self?.bridge.mockInject(["type": "meeting_detail", "meeting": done])
            }

        case "start_meeting":
            // A host recording the phone can watch: the list gets a live row and
            // `meeting_live` ticks feed the live pane.
            startMockHostRecording(mode: (payload["mode"] as? String) ?? "standard")

        case "stop_meeting":
            liveTicker?.cancel()
            liveTicker = nil
            let id = mockLiveID
            mockLiveID = nil
            bridge.mockInject(["type": "meeting_stopped", "id": id ?? ""])

        case "meeting_ask":
            // Only meaningful for the host's own live meeting — a phone
            // recording answers on-device and never comes through here.
            let question = (payload["question"] as? String) ?? ""
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self else { return }
                self.bridge.mockInject([
                    "type": "meeting_ask_reply",
                    "id": self.mockLiveID ?? (id ?? ""),
                    "text": self.mockLiveID == nil
                        ? "No meeting is being recorded on this Mac right now."
                        : "They committed to sending the cohort spreadsheet by Friday, and "
                          + "agreed QA needs one owner. Nothing was settled on pricing. "
                          + "(re: \"\(question)\")",
                ])
            }

        case "meeting_action_done", "run_agent":
            break

        case "detach_terminal", "voice_release", "ping":
            break

        case "create_session":
            let newID = UUID().uuidString
            let requested = (payload["directory"] as? String) ?? "/Users/alex/code/new"
            let worktree = payload["worktree"] as? [String: Any]
            let prompt = (payload["prompt"] as? String) ?? ""

            // Mirror the host's own failure so the sheet's error path is
            // reachable without a Mac: a branch already spoken for.
            if let branch = worktree?["branch"] as? String, branch == "taken" {
                bridge.mockInject([
                    "type": "session_create_failed",
                    "error": "fatal: a branch named 'taken' already exists",
                ])
                return
            }

            var directory = requested
            var branch: String? = nil
            if let worktree, let requestedBranch = worktree["branch"] as? String {
                // Same -wt/ layout and slash folding the host applies.
                let leaf = requestedBranch.replacingOccurrences(of: "/", with: "-")
                directory = "\(requested)-wt/\(leaf)"
                branch = requestedBranch
            }

            let label = (payload["label"] as? String)
                ?? (directory as NSString).lastPathComponent
            // Surfaced in the row so the picker is visibly doing something.
            let permission = (payload["permission"] as? String) ?? "acceptEdits"
            var row = makeRow(id: newID, label: label, directory: directory,
                              phase: "starting", attention: "working",
                              detail: "Booting Claude · \(permission)")
            if let branch {
                row["isWorktree"] = true
                row["branch"] = branch
                row["repo"] = (requested as NSString).lastPathComponent
            }
            // "New session here": filed if the folder still exists, loose
            // otherwise — never a failed create.
            if let folder = payload["folder"] as? String, folderIndex(folder) != nil {
                row["folder"] = folder
            }
            rows[newID] = row
            order.append(newID)
            var created: [String: Any] = ["type": "session_created", "id": newID, "label": label,
                                          "directory": directory]
            if let branch { created["branch"] = branch }
            bridge.mockInject(created)
            pushDelta(changed: [newID])
            // A first prompt makes the session start working rather than idle
            // at a prompt, which is what the real host does a beat later.
            if !prompt.isEmpty {
                advance(newID, to: "thinking", detail: String(prompt.prefix(48)))
            }

        case "duplicate_session":
            guard let id, let source = rows[id] else {
                bridge.mockInject(["type": "session_create_failed", "error": "unknown session"])
                return
            }
            let newID = UUID().uuidString
            let baseLabel = (source["label"] as? String) ?? "session"
            var row = source
            row["id"] = newID
            row["label"] = "\(baseLabel) 2"
            row["phase"] = "starting"
            row["attention"] = "working"
            row["phaseDetail"] = "Booting Claude"
            rows[newID] = row
            order.append(newID)
            bridge.mockInject(["type": "session_created", "id": newID,
                               "label": row["label"] as? String ?? ""])
            pushDelta(changed: [newID])

        default:
            break
        }
    }

    // MARK: - Outbound to the client

    private func ack(_ action: String, id: String?, ok: Bool, error: String? = nil) {
        var payload: [String: Any] = ["type": "action_result", "action": action, "ok": ok]
        if let id { payload["id"] = id }
        if let error { payload["error"] = error }
        bridge.mockInject(payload)
    }

    private func sendFull() {
        bridge.mockInject([
            "type": "sessions_full",
            "sessions": order.compactMap { rows[$0] },
            "folders": folders,
        ])
    }

    private func folderIndex(_ id: String?) -> Int? {
        guard let id else { return nil }
        return folders.firstIndex { ($0["id"] as? String) == id }
    }

    private func pushDelta(changed: [String], removed: [String] = []) {
        seq += 1
        bridge.mockInject([
            "type": "sessions_delta",
            "seq": seq,
            "changed": changed.compactMap { rows[$0] },
            "removed": removed,
        ])
    }

    private func advance(_ id: String, to phase: String, detail: String) {
        guard var row = rows[id] else { return }
        row["phase"] = phase
        row["phaseDetail"] = detail
        row["phaseEnteredSecAgo"] = 0
        row["attention"] = ["thinking", "planning", "usingTool", "starting"].contains(phase)
            ? "working" : (["awaitingApproval", "awaitingReply"].contains(phase) ? "needsYou" : "quiet")
        if let raw = row["attentionState"], let data = try? JSONSerialization.data(withJSONObject: raw),
           var inbox = try? JSONDecoder().decode(SessionAttentionState.self, from: data), phase == "thinking" || phase == "usingTool" {
            inbox.beginTurn()
            row["attentionState"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox))
        }
        row["hasPendingPrompt"] = phase == "awaitingApproval"
        rows[id] = row
        pushDelta(changed: [id])
    }

    private func remove(_ id: String) {
        rows[id] = nil
        order.removeAll { $0 == id }
        bridge.mockInject(["type": "session_closed", "id": id])
        pushDelta(changed: [], removed: [id])
    }

    private func sendDiff(id: String, mode: String) {
        bridge.mockInject([
            "type": "diff_result",
            "id": id,
            "mode": mode,
            "stat": "2 files, +34 −6",
            "truncated": false,
            "files": [
                [
                    "path": "Sources/Intake/IntakeForm.swift",
                    "additions": 28, "deletions": 4,
                    "patch": """
                    --- a/Sources/Intake/IntakeForm.swift
                    +++ b/Sources/Intake/IntakeForm.swift
                    @@ -14,7 +14,9 @@ struct IntakeForm: View {
                         @State private var name = ""
                    -    @State private var dob = Date()
                    +    @State private var dob: Date?
                    +    @State private var insurer: String = ""
                         var body: some View {
                    """,
                ],
                [
                    "path": "Tests/IntakeFormTests.swift",
                    "additions": 6, "deletions": 2,
                    "patch": """
                    --- a/Tests/IntakeFormTests.swift
                    +++ b/Tests/IntakeFormTests.swift
                    @@ -3,4 +3,8 @@ final class IntakeFormTests: XCTestCase {
                    -    func testEmpty() {}
                    +    func testMissingDOBIsAllowed() throws {
                    +        XCTAssertNil(IntakeForm.Model().dob)
                    +    }
                    """,
                ],
            ],
        ])
    }

    private func sendFrame(id: String) {
        let frame = """
        \u{1B}[1m\u{1B}[38;5;39m✻ Udha\u{1B}[0m  \u{1B}[2m~/code/health-tracker\u{1B}[0m

        \u{1B}[38;5;35m●\u{1B}[0m Editing \u{1B}[1mIntakeForm.swift\u{1B}[0m
          \u{1B}[2m  14 +    @State private var insurer: String = ""\u{1B}[0m
          \u{1B}[38;5;35m  ✓ 28 additions\u{1B}[0m  \u{1B}[38;5;203m4 deletions\u{1B}[0m

        \u{1B}[7m NORMAL \u{1B}[0m \u{1B}[2mesc to interrupt\u{1B}[0m
        """
        var out: [String: Any] = [
            "type": "terminal_frame", "id": id, "seq": seq + 1,
            "ansi": frame, "cursorRow": 8,
        ]
        if let grid {
            out["cols"] = grid.cols
            out["rows"] = grid.rows
        }
        bridge.mockInject(out)
    }

    /// Remember the grid the client asked for, so frames can report it back the
    /// way a real host does — the client is not allowed to assume it won.
    private func noteGrid(_ payload: [String: Any]) {
        if let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int {
            grid = (cols, rows)
            log.info("client grid \(cols)x\(rows)")
        }
    }

    /// A slow drip of deltas, so the board is visibly live rather than static.
    /// A plausible set of vitals, wobbling a little on every poll so the
    /// sparklines have shape within a few seconds of opening the screen.
    ///
    /// Without this the Machines screen could only ever be seen in its "this
    /// host does not report vitals" state, which is the one state that does not
    /// need looking at.
    private func sendStats() {
        statsTick += 1
        let t = Double(statsTick)
        func wobble(_ base: Double, _ amp: Double) -> Double {
            max(0, min(100, base + amp * sin(t * 0.7) + amp * 0.4 * cos(t * 1.9)))
        }
        let cpu = wobble(34, 16)
        let memUsed = UInt64((18.4 + 2.2 * sin(t * 0.5)) * 1_073_741_824)
        bridge.mockInject([
            "type": "stats",
            "stats": [
                "host": "Blins-MacBook-Pro.local",
                "os": "macOS 15.6",
                "kernel": "Darwin 24.6.0",
                "arch": "arm64",
                "cpuModel": "Apple M3 Max",
                "cpuThreads": 16,
                "uptimeSeconds": 347_000 + t * 5,
                "agentKind": "udha-desktop",
                "agentVersion": "5.0.0",
                "cpuPercent": cpu,
                "load": [2.41, 2.88, 3.10],
                "memoryUsed": memUsed,
                "memoryTotal": UInt64(36 * 1_073_741_824),
                "swapUsed": UInt64(1_073_741_824),
                "swapTotal": UInt64(4 * 1_073_741_824),
                "diskUsed": UInt64(612 * 1_073_741_824),
                "diskTotal": UInt64(1024 * 1_073_741_824),
                "diskDevice": "disk3s1s1",
                "temperatures": [
                    ["label": "CPU package", "celsius": wobble(58, 9)],
                    ["label": "NVMe composite", "celsius": wobble(41, 4)],
                    ["label": "Battery", "celsius": wobble(33, 2)],
                ],
                "gpu": [
                    "name": "Apple M3 Max GPU",
                    "utilPercent": wobble(22, 18),
                    "memUsedMB": 5_400.0,
                    "memTotalMB": 36_864.0,
                    "celsius": wobble(49, 6),
                    "watts": 21.0,
                ],
                "docker": ["running": 6, "note": "6 running"],
                "net": ["interface": "en0", "rxBytesPerSec": 18_400.0, "txBytesPerSec": 32_000.0],
                "topProcesses": [
                    ["name": "Xcode", "cpuPercent": 62.0],
                    ["name": "node", "cpuPercent": 18.5],
                ],
                "tools": [
                    ["name": "node", "version": "22.11.0"],
                    ["name": "pnpm", "version": "9.15.0"],
                    ["name": "swift", "version": "6.2"],
                    ["name": "gh", "version": "2.63.2"],
                ],
                "sessionCount": 8,
                "tmuxNote": "/private/tmp/tmux-501/default",
                "loggedInUsers": 1,
                "collector": "sysctl · host_statistics · powermetrics",
                "relay": [
                    "instanceId": "udha-mock-8891",
                    "url": "wss://relay.example.com",
                    "transport": "websocket",
                    "connectedAt": Date().timeIntervalSince1970 - 3600,
                    "rttMilliseconds": 108 + 14 * sin(t * 1.3),
                    "signedIn": true,
                ],
                "logTail": [
                    "[bridge] client mock-client-1 subscribed",
                    "[bridge] sessions_full sent (8 rows)",
                    "[stats] sample \(statsTick)",
                ],
                "errors": [],
                "sampledAt": Date().timeIntervalSince1970,
            ],
        ])
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !self.order.isEmpty else { continue }
                step += 1
                let id = self.order[step % self.order.count]
                guard var row = self.rows[id], (row["phase"] as? String) == "thinking" else { continue }
                row["contextPercent"] = min(((row["contextPercent"] as? Int) ?? 40) + 3, 99)
                row["costCents"] = ((row["costCents"] as? Int) ?? 100) + 7
                self.rows[id] = row
                self.pushDelta(changed: [id])
            }
        }
    }

    // MARK: - Seed data

    private func makeRow(id: String, label: String, directory: String,
                         phase: String, attention: String, detail: String?,
                         state: String = "working") -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "label": label, "directory": directory,
            "state": state, "stateEnteredSecAgo": 120,
            "priority": "normal", "hasPendingPrompt": phase == "awaitingApproval",
            "phase": phase, "phaseEnteredSecAgo": 14,
            "attention": attention, "stale": false,
            "subagentCount": 0, "isClaudeTUI": true, "isWorktree": false,
        ]
        var inbox = SessionAttentionState()
        if phase == "awaitingApproval" {
            inbox.add(kind: .approval, summary: "Review the requested command", detail: detail, source: "approval")
        }
        row["attentionState"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox))
        if phase == "awaitingReply" { row["attention"] = "quiet" }
        if let detail { row["phaseDetail"] = detail }
        return row
    }

    private func seed() {
        switch MockHost.scenario {
        case .empty:
            return

        case .allBlocked:
            add(makeRow(id: uuid(1), label: "health-tracker", directory: "/Users/alex/code/health-tracker",
                        phase: "awaitingApproval", attention: "needsYou",
                        detail: "Run `npm run migrate` against the production database?"))
            add(makeRow(id: uuid(2), label: "site-builder", directory: "/Users/alex/code/site-builder",
                        phase: "awaitingApproval", attention: "needsYou",
                        detail: "Edit 14 files across src/renderer?"))

        case .longform:
            // One row deliberately forwarded from a third machine this client is
            // not subscribed to, so the read-only path stays exercised: it must
            // list, group under its own name, and say it cannot be opened.
            defer {
                if let last = order.last { rows[last]?["host"] = "build-box" }
            }
            let longPath = "/tmp/claude-1000/-home-dev-projects-acme-clients-zendesk-sync"
            var hunter = makeRow(
                id: uuid(1),
                label: "HD CS clients ticket hunter 2",
                directory: "/home/dev/projects/acme/clients/zendesk-sync",
                phase: "usingTool", attention: "working",
                detail: "Running S=\(longPath)/node_modules/.bin/jest --runInBand --coverage")
            hunter["contextPercent"] = 81
            hunter["costCents"] = 22187
            hunter["subagentCount"] = 4
            hunter["model"] = "Opus 5 (1M context)"
            add(hunter)

            var zendesk = makeRow(
                id: uuid(2),
                label: "clients Zendesk attorneybrianwhite.com migration",
                directory: "/home/dev/projects/acme/clients",
                phase: "usingTool", attention: "working",
                detail: "Running cd \(longPath) && pnpm -w exec turbo run build --filter=@hd/zendesk")
            zendesk["model"] = "Fable 5.1"
            zendesk["contextPercent"] = 43
            add(zendesk)

            var blockedLong = makeRow(
                id: uuid(3),
                label: "storefront",
                directory: "/home/dev/projects/work/storefront",
                phase: "awaitingApproval", attention: "needsYou",
                detail: "Run `npx playwright test gates/ --project=chromium --reporter=list --workers=4` against devbox.example.com:8443 with basic auth reviewer?")
            blockedLong["lastQuestion"] = "Should “other” leave the conversion denominator, or still count as a lead that didn’t sign? It changes every cohort chart in the deck and I would rather ask than guess."
            blockedLong["contextPercent"] = 97
            blockedLong["costCents"] = 32368
            blockedLong["isWorktree"] = true
            blockedLong["branch"] = "udha/storefront-conversion-rework"
            blockedLong["repo"] = "storefront"
            blockedLong["model"] = "Opus 5 (1M context)"
            blockedLong["options"] = [
                ["n": 1, "label": "Yes", "selected": true],
                ["n": 2, "label": "Yes, and don't ask again for npx playwright commands in this repository", "selected": false],
                ["n": 3, "label": "No, and tell Claude what to do differently instead", "selected": false],
            ] as [[String: Any]]
            add(blockedLong)

            var staleLong = makeRow(
                id: uuid(4),
                label: "clients",
                directory: "/home/dev/projects/acme/clients",
                phase: "awaitingReply", attention: "quiet", detail: nil, state: "idle")
            staleLong["stale"] = true
            staleLong["model"] = "Fable 5.1"
            staleLong["phaseEnteredSecAgo"] = 9000
            add(staleLong)

        case .standard:
            var blocked = makeRow(id: uuid(1), label: "health-tracker",
                                  directory: "/Users/alex/code/health-tracker",
                                  phase: "awaitingApproval", attention: "needsYou",
                                  detail: "Run `npm run migrate` against the production database?")
            blocked["contextPercent"] = 62
            blocked["costCents"] = 187
            blocked["subagentCount"] = 2
            // A real Claude permission prompt offers three choices, not two.
            // Without them the mock could never reproduce the bug where a
            // phone could only ever press "1".
            blocked["options"] = [
                ["n": 1, "label": "Yes", "selected": true],
                ["n": 2, "label": "Yes, and don't ask again for npm commands", "selected": false],
                ["n": 3, "label": "No, and tell Claude what to do differently", "selected": false],
            ] as [[String: Any]]
            add(blocked)

            var ready = makeRow(id: uuid(2), label: "intake-form",
                                directory: "/Users/alex/code/health-tracker",
                                phase: "awaitingReply", attention: "needsYou",
                                detail: nil, state: "idle")
            ready["lastQuestion"] = "I've split the DOB field into an optional. Want the migration too?"
            ready["phaseEnteredSecAgo"] = 420
            ready["isWorktree"] = true
            ready["branch"] = "udha/intake-a3f2"
            ready["repo"] = "health-tracker"
            ready["costCents"] = 412
            ready["contextPercent"] = 88
            add(ready)

            var thinking = makeRow(id: uuid(3), label: "udha-mobile",
                                   directory: "/Users/alex/code/udha-mobile",
                                   phase: "thinking", attention: "working",
                                   detail: "thinking with xhigh effort")
            thinking["contextPercent"] = 41
            thinking["costCents"] = 96
            add(thinking)

            var tooling = makeRow(id: uuid(4), label: "site-builder",
                                  directory: "/Users/alex/code/site-builder",
                                  phase: "usingTool", attention: "working",
                                  detail: "Running npm test")
            tooling["subagentCount"] = 3
            tooling["costCents"] = 55
            add(tooling)

            var planning = makeRow(id: uuid(5), label: "school-finder",
                                   directory: "/Users/alex/code/school-finder",
                                   phase: "planning", attention: "working",
                                   detail: "Drafting the migration plan")
            add(planning)

            var stale = makeRow(id: uuid(6), label: "crm",
                                directory: "/Users/alex/code/crm",
                                phase: "awaitingReply", attention: "quiet", detail: nil, state: "idle")
            stale["stale"] = true
            stale["phaseEnteredSecAgo"] = 7200
            add(stale)

            var shell = makeRow(id: uuid(7), label: "logs", directory: "/var/log",
                                phase: "idle", attention: "quiet", detail: nil, state: "idle")
            shell["isClaudeTUI"] = false
            add(shell)

            var dead = makeRow(id: uuid(8), label: "sandbox", directory: "/Users/alex/code/sandbox",
                               phase: "finished", attention: "quiet", detail: nil, state: "exited")
            // Hidden, so the "1 session hidden · Unhide all" footer is on
            // screen from the first launch.
            dead["hidden"] = true
            add(dead)

            // Two folders in board order, one of them holding the blocked
            // session so the folder row's "needs you" pill is exercised.
            folders = [
                ["id": uuid(101), "name": "Clients"],
                ["id": uuid(102), "name": "Side projects"],
            ]
            rows[uuid(1)]?["folder"] = uuid(101)
            rows[uuid(2)]?["folder"] = uuid(101)
            rows[uuid(4)]?["folder"] = uuid(102)
            rows[uuid(5)]?["folder"] = uuid(102)
        }
    }

    /// Simulates the Mac recording: a live row plus `meeting_live` ticks, so
    /// the host-live pane is reachable with no Mac in the room.
    private func startMockHostRecording(mode: String) {
        liveTicker?.cancel()
        let id = "live-\(Int(Date().timeIntervalSince1970))"
        mockLiveID = id
        bridge.mockInject(["type": "meetings_full", "meetings": meetingRows() + [[
            "id": id,
            "title": "Recording on this Mac",
            "createdAt": Date().timeIntervalSince1970,
            "mode": mode,
            "origin": "host",
            "hasAudio": true,
            "finalized": false,
        ]]])

        let script: [(String, String)] = [
            ("Me", "Let us start with where the pipeline actually stands this week."),
            ("Them", "Two deals moved to contract, one slipped because procurement wants a security review."),
            ("Me", "How long does that review usually take on their side?"),
            ("Them", "Three weeks if we give them the questionnaire early. Longer if we wait."),
            ("Me", "Then let us send it before the technical call, not after."),
        ]
        liveTicker = Task { @MainActor [weak self] in
            var elapsed = 0
            for (index, line) in script.enumerated() {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.mockLiveID == id else { return }
                elapsed += 24
                self.bridge.mockInject([
                    "type": "meeting_live",
                    "id": id,
                    "elapsedSec": elapsed,
                    "segments": [[
                        "id": "live-seg-\(index)",
                        "source": line.0 == "Me" ? "mic" : "system",
                        "speaker": line.0,
                        "text": line.1,
                        "startTime": Double(elapsed - 24),
                        "endTime": Double(elapsed),
                    ] as [String: Any]],
                ])
            }
        }
    }

    // MARK: - Meetings & agents fixtures

    private func meetingRows() -> [[String: Any]] {
        let day: TimeInterval = 86_400
        let base = Date().timeIntervalSince1970 - 3600 * 5
        var titles: [(String, Double, Int, String, Bool)] = [
            ("Client churn review and engineering QA", 0, 32, "processMapping", true),
            ("CRM onboarding", 3600 * 3, 32, "standard", true),
            ("AI writer prompt and workflow review", 3600 * 6, 27, "standard", true),
            ("Weekly sprint sync: SendGrid outage", day, 30, "standard", true),
            ("Website redesign deployment", day + 3600 * 2, 27, "processMapping", true),
            ("Tutoring platform onboarding", day * 2, 33, "standard", true),
            ("Standup — recorded on iPhone", day * 2 + 3600, 8, "standard", false),
        ]
        if MockHost.scenario == .longform {
            titles.insert(("SEO, CRM and AI platform update — Q4 retention review with Sam, Priya and the analytics team", 0, 70, "processMapping", false), at: 0)
        }
        return titles.enumerated().map { index, t in
            let created = base - t.1
            return [
                "id": "m\(index + 1)",
                "title": t.0,
                "createdAt": created,
                "endedAt": created + Double(t.2 * 60),
                "mode": t.3,
                "origin": index == titles.count - 1 ? "local" : "host",
                "hasAudio": true,
                "finalized": t.4,
            ]
        }
    }

    private func meetingDetail(_ id: String) -> [String: Any]? {
        guard var row = meetingRows().first(where: { ($0["id"] as? String) == id }) else { return nil }
        row["summary"] = "Roughly 90% of churn is addressable, with the biggest gaps in "
            + "operational execution, QA visibility and product strategy. Retention drops "
            + "sharply around month 11 against a ~27 month average tenure. Sweet James was "
            + "flagged as a case where further price increases are hard to justify now the "
            + "website and most SEO work are complete."
        row["notesMarkdown"] = """
            ## Churn
            About **90% of churn is addressable**. The rest is business model — \
            acquisitions and teams going in-house.

            ## The eleven-month cliff
            Average tenure is 27 months, but there is a visible drop at month 11, \
            which lines up with the big deliverables finishing while the invoice \
            stays the same.

            ## Pricing
            Sweet James is the clearest case: price was raised twice against a \
            shrinking scope.
            """
        row["decisions"] = [
            "Track execution errors across every team, not just developer QA.",
            "Reboot the QA program under a dedicated director of QA.",
            "Stand up a recurring Monday 3:00pm Central retention sync.",
            "Hire a head of product to own next-gen and AI offerings.",
        ]
        row["actionItems"] = [
            ["id": "a1", "text": "Pull retention by tenure cohort to find the month-11 drop-off", "owner": "Me", "done": false],
            ["id": "a2", "text": "Categorise execution errors by team and give the percentage split", "owner": "Me", "done": true],
            ["id": "a3", "text": "Send the retention email with the Loom and spreadsheet", "owner": "Them", "done": false],
            ["id": "a4", "text": "Move Sweet James to Alex to avoid the conflict of interest", "owner": "Them", "done": false],
        ]
        let lines: [(String, String, Double)] = [
            ("Me", "The framework I want to walk through is: how much of our churn is actually addressable, and where does it come from.", 12),
            ("Them", "My read is about ninety percent. The rest is business model — they got acquired, they went in-house.", 31),
            ("Me", "Then the interesting part is the eleven-month cliff. Average tenure is twenty-seven months, but there is a visible drop right around eleven.", 64),
            ("Them", "That lines up with when the big deliverables finish. Website is done, SEO is mostly done, and the invoice does not change.", 99),
            ("Me", "Which is exactly the Sweet James situation. We raised price twice against a shrinking scope.", 130),
        ]
        row["transcript"] = lines.enumerated().map { i, l in
            [
                "id": "t\(i)",
                "source": l.0 == "Me" ? "mic" : "system",
                "speaker": l.0,
                "text": l.1,
                "startTime": l.2,
                "endTime": l.2 + 18,
            ] as [String: Any]
        }
        return row
    }

    private func agentRows() -> [[String: Any]] {
        var rows: [[String: Any]] = [
            [
                "id": "a1", "name": "Security audit",
                "summary": "Read-only sweep for secrets, injection and permission holes",
                "directory": "/Users/alex/code/crm-api",
                "body": ["---", "name: Security audit", "description: Read-only sweep for secrets, injection and permission holes", "---", "",
                         "You are auditing this repository. Do not modify files.", "",
                         "1. Find committed secrets, keys and tokens.",
                         "2. Flag every place user input reaches a shell, a query or a file path.",
                         "3. List entitlements broader than needed.",
                         "4. Report findings as a table: severity, file:line, what to do.", "",
                         "Finish with the four highest-severity items and nothing else."],
            ],
            [
                "id": "a1b", "name": "Full-Spectrum Security Assessment orchestrator",
                "summary": "Master orchestrator — runs all 19 cybersecurity domains in sequence and produces a single consolidated report with severity, owner and remediation for every finding across the estate",
                "directory": "/home/dev/projects/acme/clients/zendesk-sync",
                "body": ["Run every domain in order and consolidate."],
            ],
            [
                "id": "a2", "name": "PR describer",
                "summary": "Writes the PR body from the diff on the current branch",
                "directory": "/Users/alex/code/crm-api",
                "body": ["---", "name: PR describer", "---", "",
                         "Read the diff against main and write the PR body.",
                         "Lead with what changed and why; keep it under 200 words."],
            ],
            [
                "id": "a3", "name": "Migration reviewer",
                "summary": "Checks SQL migrations for locks, backfills and rollback",
                "directory": "/Users/alex/code/dashboard",
                "body": ["---", "name: Migration reviewer", "---", "",
                         "Review every migration in this branch for table locks,",
                         "unbounded backfills and a missing down path."],
            ],
            [
                "id": "a4", "name": "Churn digest",
                "summary": "Turns the retention export into the Monday sync agenda",
                "body": ["---", "name: Churn digest", "---", "",
                         "Read the retention export and produce the Monday agenda:",
                         "cohort drop-offs, accounts at risk, and the three decisions needed."],
            ],
        ]
        if MockHost.scenario != .longform {
            rows.removeAll { ($0["id"] as? String) == "a1b" }
        }
        return rows
    }

    private func add(_ row: [String: Any]) {
        guard let id = row["id"] as? String else { return }
        rows[id] = row
        order.append(id)
    }

    /// Stable ids so a deep-link test can target a known session.
    private func uuid(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }
}
#endif
