// Assertions over the wire layer: row decoding, v1 fallback, message decoding,
// and the send_keys validator.
//
// BridgeModels.swift and BridgeProtocol.swift import only Foundation, so they
// compile and run natively — no simulator, no UI, no flakiness. Run via
// tests/run.sh.
import Foundation

var failures = 0
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        let d = detail()
        print("FAIL  \(name)\(d.isEmpty ? "" : "  — " + d)")
    }
}

func payload(_ json: String) -> [String: Any] {
    let data = json.data(using: .utf8)!
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

// MARK: - Row decoding, full v2 shape

let fullRow = """
{"type":"sessions_full","sessions":[{
  "id":"abc","label":"health-tracker","directory":"/Users/alex/code/health-tracker",
  "state":"working","stateEnteredSecAgo":62,"priority":"normal","hasPendingPrompt":false,
  "phase":"awaitingApproval","phaseDetail":"Editing IntakeForm.swift","phaseEnteredSecAgo":14,
  "attention":"needsYou","stale":false,"subagentCount":2,"contextPercent":62,"costCents":187,
  "lastQuestion":"migrate?","isClaudeTUI":true,
  "repo":"health-tracker","branch":"udha/cov-a3f2","isWorktree":true}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(fullRow)) {
    check("decodes one row", rows.count == 1)
    let r = rows[0]
    check("phase", r.phase == .awaitingApproval, "\(r.phase)")
    check("attention from wire", r.attention == .needsYou, "\(r.attention)")
    check("costCents is Int", r.costCents == 187, "\(String(describing: r.costCents))")
    check("cost renders as dollars", r.costDisplay == "$1.87", r.costDisplay ?? "nil")
    check("worktree branch", r.branch == "udha/cov-a3f2" && r.isWorktree)
    check("subagent note", r.subagentNote == "2 subagents", r.subagentNote ?? "nil")
    check("status label for approval", r.statusLabel == "Needs approval", r.statusLabel)
    check("phase age compact", r.phaseAge == "14s", r.phaseAge)
} else {
    check("decodes sessions_full", false)
}

// MARK: - v1 fallback (an old desktop sends none of the v2 fields)

let v1Row = """
{"type":"sessions_full","sessions":[
 {"id":"a","label":"old","state":"working","stateEnteredSecAgo":5,"priority":"normal","hasPendingPrompt":false},
 {"id":"b","label":"blocked","state":"needsInput","stateEnteredSecAgo":5,"priority":"normal","hasPendingPrompt":true},
 {"id":"c","label":"done","state":"exited","stateEnteredSecAgo":5,"priority":"normal","hasPendingPrompt":false}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(v1Row)) {
    check("v1 working -> thinking/working", rows[0].phase == .thinking && rows[0].attention == .working,
          "\(rows[0].phase)/\(rows[0].attention)")
    check("v1 pending prompt -> needsYou", rows[1].phase == .awaitingApproval && rows[1].attention == .needsYou,
          "\(rows[1].phase)/\(rows[1].attention)")
    check("v1 exited -> quiet", rows[2].attention == .quiet, "\(rows[2].attention)")
    check("v1 defaults isClaudeTUI true", rows[0].isClaudeTUI)
} else {
    check("decodes v1 sessions_full", false)
}

// MARK: - Unknown enum values must not throw the whole row away

let weird = """
{"type":"sessions_full","sessions":[{"id":"x","label":"z","state":"quantum","phase":"vibing","attention":"whatever"}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(weird)) {
    check("unknown state degrades, row survives", rows.count == 1 && rows[0].state == .unknown, "\(rows.count)")
    check("unknown phase degrades", rows[0].phase == .unknown)
    check("unknown attention -> quiet", rows[0].attention == .quiet)
} else {
    check("survives unknown enums", false)
}

// MARK: - Deltas

if case .sessionsDelta(let seq, let changed, let removed) =
    BridgeDecoder.decode(payload: payload("""
    {"type":"sessions_delta","seq":4172,"changed":[{"id":"a","label":"x"}],"removed":["b","c"]}
    """)) {
    check("delta seq", seq == 4172)
    check("delta changed", changed.count == 1)
    check("delta removed", removed == ["b", "c"])
} else {
    check("decodes sessions_delta", false)
}

// MARK: - hello_ack capabilities

if case .helloAck(let ack) = BridgeDecoder.decode(payload: payload("""
    {"type":"hello_ack","protocol":2,"capabilities":["delta","actions","pty"],
     "instanceKind":"udha-headless","clientId":"c1","staleAfterSec":900}
    """)) {
    check("ack protocol", ack.protocolVersion == 2)
    check("ack supports delta", ack.supportsDelta)
    check("ack lacks diff", !ack.supportsDiff)
    check("ack headless kind", ack.instanceKind == "udha-headless")
    check("ack clientId", ack.clientID == "c1")
    check("ack staleAfter", ack.staleAfterSec == 900)
} else {
    check("decodes hello_ack", false)
}

// MARK: - action_result

if case .actionResult(let r) = BridgeDecoder.decode(payload: payload("""
    {"type":"action_result","action":"approve","id":"s1","ok":false,"error":"no dialog visible"}
    """)) {
    check("action_result failure carries reason", !r.ok && r.error == "no dialog visible", r.error ?? "nil")
} else {
    check("decodes action_result", false)
}

// MARK: - diff_result

if case .diffResult(let d) = BridgeDecoder.decode(payload: payload("""
    {"type":"diff_result","id":"s1","mode":"branch","stat":"1 file, +2 −1","truncated":true,
     "files":[{"path":"a/b/C.swift","patch":"+x\\n-y","additions":2,"deletions":1}]}
    """)) {
    check("diff mode", d.mode == .branch)
    check("diff truncated flag", d.truncated)
    check("diff file name", d.files.first?.fileName == "C.swift", d.files.first?.fileName ?? "nil")
} else {
    check("decodes diff_result", false)
}

// MARK: - unknown message types degrade rather than crash

if case .unknown(let t) = BridgeDecoder.decode(payload: payload("{\"type\":\"from_the_future\"}")) {
    check("unknown type degrades", t == "from_the_future")
} else {
    check("unknown type degrades", false)
}

// MARK: - send_keys validator (payload-smuggling guard)

check("accepts named keys", TmuxKey.validate(["Down", "Down", "Enter"]))
check("accepts ctrl chord", TmuxKey.validate(["C-c"]))
check("accepts meta chord", TmuxKey.validate(["M-x"]))
check("accepts BTab", TmuxKey.validate(["BTab"]))
check("accepts function key", TmuxKey.validate(["F12"]))
check("accepts single alnum", TmuxKey.validate(["a", "7"]))
check("rejects shell injection", !TmuxKey.validate(["; rm -rf /"]))
check("rejects spaces", !TmuxKey.validate(["Down Enter"]))
check("rejects empty sequence", !TmuxKey.validate([]))
check("rejects whole message on one bad element", !TmuxKey.validate(["Down", "$(whoami)"]))
check("rejects unknown名 key", !TmuxKey.validate(["Bananas"]))

// MARK: - Outbound encoding

let keysMsg = BridgeOutbound.sendKeys(id: "s1", keys: ["Down", "Enter"]).json
check("send_keys type", keysMsg["type"] as? String == "send_keys")
check("send_keys carries array", (keysMsg["keys"] as? [String]) == ["Down", "Enter"])

let helloMsg = BridgeOutbound.hello.json
check("hello announces protocol 2", helloMsg["protocol"] as? Int == 2)
check("hello lists capabilities", (helloMsg["capabilities"] as? [String])?.contains("delta") == true)

let wt = BridgeOutbound.createSession(
    directory: "~/code/x", label: "cov", prompt: "migrate the schema", tool: nil, permission: nil,
    worktree: .init(branch: "udha/cov", base: "main")).json
check("create_session nests worktree",
      ((wt["worktree"] as? [String: Any])?["branch"] as? String) == "udha/cov")
// The slash must survive encoding — the host stores the branch rather than
// deriving it from the worktree path, which folds the slash to a dash.
check("worktree branch keeps its slash",
      ((wt["worktree"] as? [String: Any])?["branch"] as? String)?.contains("/") == true)
check("worktree defaults to a new branch",
      ((wt["worktree"] as? [String: Any])?["newBranch"] as? Bool) == true)
check("create_session carries the prompt", wt["prompt"] as? String == "migrate the schema")

let existingBranch = BridgeOutbound.createSession(
    directory: "~/code/x", label: nil, prompt: nil, tool: nil, permission: nil,
    worktree: .init(branch: "feature/ready", base: "", isNewBranch: false)).json
check("existing-branch mode is on the wire",
      ((existingBranch["worktree"] as? [String: Any])?["newBranch"] as? Bool) == false)

let noLabel = BridgeOutbound.createSession(directory: "~/x", label: nil, prompt: nil, tool: nil, permission: nil, worktree: nil).json
check("create_session omits empty label", noLabel["label"] == nil)
check("create_session omits absent prompt", noLabel["prompt"] == nil)
check("create_session omits empty prompt",
      BridgeOutbound.createSession(directory: "~/x", label: nil, prompt: "", tool: nil, permission: nil, worktree: nil)
        .json["prompt"] == nil)

check("duplicate_session carries the id",
      BridgeOutbound.duplicateSession(id: "s7").json["id"] as? String == "s7")
check("duplicate_session type",
      BridgeOutbound.duplicateSession(id: "s7").json["type"] as? String == "duplicate_session")
check("list_branches carries the directory",
      BridgeOutbound.listBranches(directory: "~/code/x").json["directory"] as? String == "~/code/x")
check("list_directory forwards showHidden",
      BridgeOutbound.listDirectory(path: "/x", showHidden: true).json["showHidden"] as? Bool == true)

check("kill_session requires confirm",
      BridgeOutbound.killSession(id: "s", confirm: true).json["confirm"] as? Bool == true)

// Rename travels to the host — the label is the Mac's, not a local nickname —
// so the verb has to carry both halves or the desktop renames nothing.
let renameMsg = BridgeOutbound.renameSession(id: "s7", label: "intake fix").json
check("rename_session type", renameMsg["type"] as? String == "rename_session")
check("rename_session carries the id", renameMsg["id"] as? String == "s7")
check("rename_session carries the label", renameMsg["label"] as? String == "intake fix")
check("client advertises rename", BridgeProtocolVersion.capabilities.contains("rename"))

// Videos: the library is the host's, so the phone's verbs have to name the
// video and nothing else — there is no local copy to fall back on.
check("list_videos type", BridgeOutbound.listVideos.json["type"] as? String == "list_videos")
let renameVideo = BridgeOutbound.renameVideo(id: "v1", title: "Intake demo").json
check("rename_video type", renameVideo["type"] as? String == "rename_video")
check("rename_video carries the id", renameVideo["id"] as? String == "v1")
check("rename_video carries the title", renameVideo["title"] as? String == "Intake demo")
check("delete_video carries the id",
      BridgeOutbound.deleteVideo(id: "v1").json["id"] as? String == "v1")
check("client advertises videos", BridgeProtocolVersion.capabilities.contains("videos"))

// The row the desktop serializes. Epoch seconds and a share link that is
// absent — not empty — until the video is published.
if case .videosFull(let videos) = BridgeDecoder.decode(payload: payload("""
    {"type":"videos_full","videos":[
     {"id":"v1","title":"Intake demo","createdAt":1787000000,"durationSec":192.5,
      "stage":"ready","hasCamera":true,"hasMic":true,"hasSystemAudio":false,
      "orientations":["landscape","portrait"],"shareURL":"https://example.com/v/intake",
      "isPasswordProtected":true,"publishedAt":1787003000,"busy":false},
     {"id":"v2","title":"Local only","createdAt":1786000000,"durationSec":45,
      "stage":"composing","busy":true}]}
    """)) {
    check("decodes both videos", videos.count == 2)
    check("video title", videos.first?.title == "Intake demo")
    check("video duration", videos.first?.durationSeconds == 192.5)
    check("video stage", videos.first?.stage == .ready)
    check("published video carries its link",
          videos.first?.shareURL?.absoluteString == "https://example.com/v/intake")
    check("published video is published", videos.first?.isPublished == true)
    check("unpublished video has no link", videos.last?.shareURL == nil)
    check("unpublished video is not published", videos.last?.isPublished == false)
    check("busy survives", videos.last?.busy == true)
    check("missing flags default to false", videos.last?.hasMic == false)
    check("clock formats mm:ss", VideoItem.clock(192.5) == "03:13")
    check("clock grows an hour field", VideoItem.clock(3671) == "1:01:11")
} else {
    check("decodes videos_full", false)
}

// An unknown stage must not swallow the row: a desktop that grows a new stage
// still has a video the phone can rename and delete.
if case .videosFull(let videos) = BridgeDecoder.decode(payload: payload("""
    {"type":"videos_full","videos":[{"id":"v9","title":"From the future",
     "createdAt":1787000000,"stage":"uploading"}]}
    """)) {
    check("unknown stage still decodes", videos.first?.stage == .unknown)
} else {
    check("decodes videos_full with an unknown stage", false)
}
check("actions are flagged", BridgeOutbound.interrupt(id: "s").isAction)
check("list is not an action", !BridgeOutbound.listSessionsFull.isAction)

// MARK: - Meetings

let meetingsPayload = """
{"type":"meetings_full","meetings":[
 {"id":"m1","title":"Client losses and QA","createdAt":1787000000,"endedAt":1787001920,
  "mode":"processMapping","origin":"host","hasAudio":true,"finalized":true},
 {"id":"m2","title":"Standup","createdAt":1787100000,"origin":"local","finalized":false},
 {"id":"m3","title":"Ended but unsummarised","createdAt":1787100000,"endedAt":1787100480,
  "origin":"local","finalized":false}]}
"""
if case .meetingsFull(let list) = BridgeDecoder.decode(payload: payload(meetingsPayload)) {
    check("decodes meetings", list.count == 3, "\(list.count)")
    let m = list[0]
    check("epoch dates decode", Int(m.createdAt.timeIntervalSince1970) == 1787000000)
    check("duration from endedAt", m.durationSeconds == 1920)
    check("mode processMapping", m.mode == .processMapping)
    check("host origin label", m.origin.audioLabel == "mic + system audio")
    check("list meta has mapped", m.listMeta.contains("mapped") && m.listMeta.contains("32m"), m.listMeta)
    check("no detail until fetched", !m.hasDetail)

    let live = list[1]
    check("missing endedAt means recording", live.isRecording)
    check("local origin is mic only", live.origin.audioLabel == "mic only")
    // A recording still in progress must NOT be labelled "needs summary" —
    // that label is only meaningful once it has actually ended.
    check("in-progress is not needs-summary", !live.listMeta.contains("needs summary"), live.listMeta)

    let stranded = list[2]
    check("ended + unfinalized shows needs summary",
          stranded.listMeta.contains("needs summary"), stranded.listMeta)
    check("ended + unfinalized is not recording", !stranded.isRecording)
} else {
    check("decodes meetings_full", false)
}

if case .meetingDetail(let m) = BridgeDecoder.decode(payload: payload("""
    {"type":"meeting_detail","meeting":{"id":"m1","title":"T","createdAt":1787000000,
     "endedAt":1787000600,"origin":"host","finalized":true,
     "summary":"S","decisions":["d1","d2"],
     "actionItems":[{"id":"a1","text":"do it","owner":"Me","done":true},
                    {"id":"a2","text":"other"}],
     "transcript":[{"id":"t1","source":"system","speaker":"Them","text":"hi","startTime":726,"endTime":730}]}}
    """)) {
    check("detail marks hasDetail", m.hasDetail)
    check("decisions decode", m.decisions?.count == 2)
    check("action item done", m.actionItems?.first?.done == true)
    // `done` is absent on the second item — a synthesised decoder would throw
    // here and drop the whole array, which is the DiffFile bug class.
    check("action item missing done defaults false", m.actionItems?.last?.done == false)
    check("action item missing owner is nil", m.actionItems?.last?.owner == nil)
    check("transcript speaker", m.transcript?.first?.speaker == "Them")
    check("transcript stamp mm:ss", m.transcript?.first?.stamp == "12:06", m.transcript?.first?.stamp ?? "nil")
    check("system source is not me", m.transcript?.first?.isMe == false)
} else {
    check("decodes meeting_detail", false)
}

if case .meetingLive(let id, let elapsed, let segments) = BridgeDecoder.decode(payload: payload("""
    {"type":"meeting_live","id":"m9","elapsedSec":93,
     "segments":[{"id":"s1","source":"mic","speaker":"Me","text":"yes","startTime":90,"endTime":93}]}
    """)) {
    check("live id", id == "m9")
    check("live elapsed", elapsed == 93)
    check("live segment", segments.first?.isMe == true)
} else {
    check("decodes meeting_live", false)
}

// Round-trip: what we upload must decode back to what we sent.
let local = Meeting(id: "L1", title: "Local", createdAt: Date(timeIntervalSince1970: 1787200000),
                    endedAt: Date(timeIntervalSince1970: 1787200600), origin: .local,
                    finalized: false,
                    transcript: [TranscriptSegment(id: "x", source: .mic, speaker: "Me",
                                                   text: "hello", startTime: 1, endTime: 4)])
if let wire = local.wirePayload,
   let data = try? JSONSerialization.data(withJSONObject: wire),
   let back = try? JSONDecoder().decode(Meeting.self, from: data) {
    check("upload round-trips id", back.id == "L1")
    check("upload round-trips dates", Int(back.createdAt.timeIntervalSince1970) == 1787200000)
    check("upload round-trips origin", back.origin == .local)
    check("upload round-trips transcript", back.transcript?.first?.text == "hello")
} else {
    check("wirePayload round-trips", false)
}

// MARK: - Agents

if case .agentsFull(let agents) = BridgeDecoder.decode(payload: payload("""
    {"type":"agents_full","agents":[
     {"id":"a1","name":"Security audit","summary":"sweep","directory":"/x/crm-api",
      "body":["---","name: x"]},
     {"id":"a2","name":"Blob body","summary":"s","body":"line one\\nline two"}]}
    """)) {
    check("decodes agents", agents.count == 2)
    check("agent run label uses folder", agents[0].runLabel == "Run in crm-api", agents[0].runLabel)
    check("agent body as array", agents[0].body.count == 2)
    // Hosts may send the prompt pre-split or as one blob; both must render.
    check("agent body as blob splits", agents[1].body == ["line one", "line two"], "\(agents[1].body)")
    check("agent without directory", agents[1].runLabel == "Run…", agents[1].runLabel)
} else {
    check("decodes agents_full", false)
}

// MARK: - Meetings outbound

check("start_meeting carries mode",
      BridgeOutbound.startMeeting(mode: .processMapping).json["mode"] as? String == "processMapping")
check("meeting_ask carries question",
      BridgeOutbound.askMeeting(id: "m", question: "q").json["question"] as? String == "q")
check("action_done carries itemId",
      BridgeOutbound.setActionItemDone(meetingID: "m", itemID: "i", done: true).json["itemId"] as? String == "i")

// MARK: - Meetings: persistence and sync state
//
// These cover the two defects that made local recordings disappear: an encoder
// that disagreed with the decoder about how dates are written, and a sync state
// that had nowhere to live.

// The synthesised encoder would write Date as seconds since 2001 while
// init(from:) reads epoch seconds — a silent 31-year skew on every meeting the
// on-disk store round-trips.
do {
    let original = Meeting(
        id: "S1", title: "Stored", createdAt: Date(timeIntervalSince1970: 1787200000),
        endedAt: Date(timeIntervalSince1970: 1787203600), origin: .local,
        hasAudio: true, finalized: false,
        transcript: [TranscriptSegment(id: "s", source: .mic, speaker: "Me",
                                       text: "kept", startTime: 2, endTime: 9)],
        userNotes: "rough", notesMarkdown: "## Polished",
        syncState: .queued, provisionalSummary: true
    )
    if let data = try? JSONEncoder().encode(original),
       let back = try? JSONDecoder().decode(Meeting.self, from: data) {
        check("store round-trips createdAt as epoch",
              Int(back.createdAt.timeIntervalSince1970) == 1787200000,
              "\(back.createdAt.timeIntervalSince1970)")
        check("store round-trips endedAt as epoch",
              Int(back.endedAt?.timeIntervalSince1970 ?? 0) == 1787203600)
        check("store round-trips sync state", back.syncState == .queued)
        check("store round-trips provisional flag", back.provisionalSummary)
        check("store round-trips notesMarkdown", back.notesMarkdown == "## Polished")
        check("store round-trips user notes", back.userNotes == "rough")
        check("store round-trips transcript", back.transcript?.first?.text == "kept")
        check("store round-trips origin", back.origin == .local)
    } else {
        check("meeting encodes and decodes", false)
    }
}

// A host row says nothing about this phone's outbox, so decoding one must not
// invent a sync state that would strand a queued upload.
if case .meetingsFull(let list) = BridgeDecoder.decode(payload: payload("""
    {"type":"meetings_full","meetings":[
     {"id":"h1","title":"Host","createdAt":1787000000,"endedAt":1787001000,
      "origin":"host","finalized":true}]}
    """)) {
    check("a host row defaults to synced", list.first?.syncState == .synced)
    check("a host row is not provisional", list.first?.provisionalSummary == false)
} else {
    check("decodes meetings_full with defaults", false)
}

// The rough notes typed during a call are the backbone of the polished notes,
// so they have to survive the trip up even when nothing else is set.
do {
    let notesOnly = Meeting(id: "N1", title: "Notes only", origin: .local,
                            userNotes: "just what I typed")
    check("upload carries user notes",
          notesOnly.wirePayload?["userNotes"] as? String == "just what I typed")
    let polished = Meeting(id: "N2", title: "Polished", notesMarkdown: "## Heading")
    check("upload carries notesMarkdown",
          polished.wirePayload?["notesMarkdown"] as? String == "## Heading")
}

// The sync state, not `finalized`, is what the row leads with while a
// recording is still stuck on this device.
do {
    var queued = Meeting(id: "Q1", title: "Queued",
                         createdAt: Date(timeIntervalSince1970: 1787200000),
                         endedAt: Date(timeIntervalSince1970: 1787201200),
                         origin: .local, finalized: false, syncState: .queued)
    check("queued row says it is waiting", queued.listMeta.contains("waiting for Mac"), queued.listMeta)
    check("queued row does not also say needs summary",
          !queued.listMeta.contains("needs summary"), queued.listMeta)
    queued.syncState = .synced
    check("a synced but unsummarised row says needs summary",
          queued.listMeta.contains("needs summary"), queued.listMeta)
    check("needsUpload covers a failed upload", MeetingSyncState.failed.needsUpload)
    check("needsUpload excludes synced", !MeetingSyncState.synced.needsUpload)
}

// Notes are what the detail pane reads; the blurb is the fallback.
do {
    let both = Meeting(id: "D1", title: "Both", summary: "blurb", notesMarkdown: "## real notes")
    check("polished notes win over the blurb", both.displayNotes == "## real notes")
    let blurbOnly = Meeting(id: "D2", title: "Blurb", summary: "blurb")
    check("the blurb is the fallback", blurbOnly.displayNotes == "blurb")
    check("notesMarkdown alone counts as detail",
          Meeting(id: "D3", title: "N", notesMarkdown: "x").hasDetail)
    check("nothing at all is not detail", !Meeting(id: "D4", title: "N").hasDetail)

    // The host sends an empty summary for a meeting it has not summarised yet.
    // Treating "fetched" as "has something to show" rendered a blank pane.
    let fetchedButEmpty = Meeting(id: "D5", title: "Empty", origin: .host,
                                  finalized: false, summary: "",
                                  decisions: [], actionItems: [], transcript: [])
    check("an empty fetched detail counts as fetched", fetchedButEmpty.hasDetail)
    check("an empty fetched detail has nothing to show", !fetchedButEmpty.hasNotesContent)
    check("a summary alone is content",
          Meeting(id: "D6", title: "S", summary: "text").hasNotesContent)
    check("action items alone are content",
          Meeting(id: "D7", title: "A",
                  actionItems: [ActionItem(text: "do it")]).hasNotesContent)
}

// The ack is what lets the outbox tell "sent" from "arrived".
if case .localMeetingAck(let id, let ok, let error) = BridgeDecoder.decode(payload: payload("""
    {"type":"push_local_meeting_ack","id":"L9","ok":true}
    """)) {
    check("ack carries the id", id == "L9")
    check("ack reports success", ok)
    check("a successful ack has no error", error == nil)
} else {
    check("decodes push_local_meeting_ack", false)
}

if case .localMeetingAck(let id, let ok, let error) = BridgeDecoder.decode(payload: payload("""
    {"type":"push_local_meeting_ack","id":"L9","ok":false,"error":"meeting id missing"}
    """)) {
    check("a rejected ack keeps the id", id == "L9")
    check("a rejected ack reports failure", !ok)
    check("a rejected ack explains why", error == "meeting id missing")
} else {
    check("decodes a rejected ack", false)
}

// MARK: - Directory listing and branches

func decodeInbound(_ json: String) -> BridgeInbound {
    let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    return BridgeDecoder.decode(payload: obj)
}

// A host that predates `isRepo` omits it. Swift's *synthesised* decoder ignores
// default values, so an omitted key would throw and blank the whole listing —
// the exact class of bug that once emptied the diff viewer.
let listingJSON = """
{"type":"directory_listing","path":"/Users/alex/code","parent":"/Users/alex",
 "entries":[{"name":"health-tracker","path":"/Users/alex/code/health-tracker","isRepo":true},
            {"name":"notes","path":"/Users/alex/code/notes"}]}
"""
if case .directoryListing(let listing) = decodeInbound(listingJSON) {
    check("listing keeps both entries", listing.entries.count == 2, "\(listing.entries.count)")
    check("isRepo decodes when present", listing.entries.first?.isRepo == true)
    check("isRepo defaults when absent", listing.entries.last?.isRepo == false)
    check("listing parent decodes", listing.parent == "/Users/alex")
} else {
    check("directory listing decodes", false)
}

let branchesJSON = """
{"type":"branches","directory":"/x","current":"main",
 "branches":["main","udha/cov-a3f2","origin/main"]}
"""
if case .branches(let b) = decodeInbound(branchesJSON) {
    check("branches decode", b.names.count == 3, "\(b.names.count)")
    check("branches report current", b.current == "main")
    check("current sorts first", b.ordered.first == "main")
    check("branch slashes survive decoding", b.names.contains("udha/cov-a3f2"))
} else {
    check("branches decode", false)
}

// An error listing must still decode rather than falling through to .unknown.
let branchErrorJSON = """
{"type":"branches","directory":"/x","branches":[],"error":"not a git repository"}
"""
if case .branches(let b) = decodeInbound(branchErrorJSON) {
    check("branch error decodes", b.error == "not a git repository", b.error ?? "nil")
    check("branch error has no current", b.current == nil)
} else {
    check("branch error decodes", false)
}

let createdJSON = """
{"type":"session_created","id":"s9","label":"cov","directory":"/x-wt/cov"}
"""
if case .sessionCreated(let id, let label, let dir) = decodeInbound(createdJSON) {
    check("session_created id", id == "s9")
    check("session_created label", label == "cov")
    check("session_created directory", dir == "/x-wt/cov", dir ?? "nil")
} else {
    check("session_created decodes", false)
}


// MARK: - Permission mode

// Raw values ARE the wire contract with the Mac's three ladders —
// ClaudePermissionMode, CodexApprovalMode, QwenApprovalMode. A rename on either
// side silently changes which flags the CLI launches with, and the host answers
// an unknown name by falling back to its own default rather than erroring, so
// a drift here is invisible until someone notices the agent behaving oddly.
check("Claude raw values match the host",
      SessionTool.claude.modes.map(\.rawValue) == ["acceptEdits", "ask", "plan", "bypass"],
      SessionTool.claude.modes.map(\.rawValue).joined(separator: ","))
check("ChatGPT raw values match the host's CodexApprovalMode",
      SessionTool.codex.modes.map(\.rawValue) == ["workspaceWrite", "ask", "readOnly", "bypass"],
      SessionTool.codex.modes.map(\.rawValue).joined(separator: ","))
check("Qwen raw values match the host's QwenApprovalMode",
      SessionTool.qwen.modes.map(\.rawValue) == ["autoEdit", "ask", "plan", "yolo"],
      SessionTool.qwen.modes.map(\.rawValue).joined(separator: ","))
check("tool raw values are the commands the host spawns",
      SessionTool.allCases.map(\.rawValue) == ["claude", "codex", "qwen"],
      SessionTool.allCases.map(\.rawValue).joined(separator: ","))
// Each ladder has exactly one no-approvals rung, and it is the one that gets
// the warning colour.
check("every tool has exactly one dangerous rung",
      SessionTool.allCases.allSatisfy { $0.modes.filter(\.isDangerous).count == 1 })

let perm = BridgeOutbound.createSession(
    directory: "~/x", label: nil, prompt: nil, tool: nil, permission: .plan, worktree: nil).json
check("create_session carries permission", perm["permission"] as? String == "plan")

// Omitted, not defaulted: a host predating this keeps its own default rather
// than being handed a mode it cannot read.
let noPerm = BridgeOutbound.createSession(
    directory: "~/x", label: nil, prompt: nil, tool: nil, permission: nil, worktree: nil).json
check("create_session omits absent permission", noPerm["permission"] == nil)

check("bypass encodes as the host expects",
      BridgeOutbound.createSession(directory: "~/x", label: nil, prompt: nil,
                                   tool: nil, permission: .bypass, worktree: nil)
        .json["permission"] as? String == "bypass")

// MARK: - Connection health policy
//
// The battery-relevant decisions live in ConnectionHealth as pure functions
// over timestamps, precisely so they can be asserted here instead of being
// discovered on a phone fifteen minutes later.

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// Backoff has to actually escalate. The old socket reset its attempt counter
// on `resume()`, which made every delay 2^0 — a redial every second for as
// long as the network stayed down.
check("backoff starts at 1s", ConnectionHealth.backoffDelay(attempt: 0) == 1)
check("backoff escalates", ConnectionHealth.backoffDelay(attempt: 3) == 8)
check("backoff caps", ConnectionHealth.backoffDelay(attempt: 12) == ConnectionHealth.maxBackoff)
check("backoff cannot overflow", ConnectionHealth.backoffDelay(attempt: 9999) == ConnectionHealth.maxBackoff)

// Pings are the whole battery story: one per idle interval, none at all while
// traffic is flowing, because any inbound frame is proof enough.
check("ping when nothing has ever arrived",
      ConnectionHealth.shouldPing(lastInboundAt: nil, now: t0))
check("no ping while traffic is flowing",
      !ConnectionHealth.shouldPing(lastInboundAt: t0.addingTimeInterval(-5), now: t0))
check("ping once the wire goes quiet",
      ConnectionHealth.shouldPing(lastInboundAt: t0.addingTimeInterval(-26), now: t0))

// Death is silence, not an error: URLSession never reports the cases that
// actually happen (NAT timeout, network handoff, fifteen minutes suspended).
check("silence under the limit is not death",
      !ConnectionHealth.isDead(lastInboundAt: t0.addingTimeInterval(-60), now: t0))
check("silence past the limit is death",
      ConnectionHealth.isDead(lastInboundAt: t0.addingTimeInterval(-71), now: t0))
check("a socket that never spoke is not yet declared dead",
      !ConnectionHealth.isDead(lastInboundAt: nil, now: t0))
check("death is slower than a ping, so a keepalive gets its chance first",
      ConnectionHealth.silenceLimit > ConnectionHealth.pingInterval * 2)

// An idle pane and a dead pane are both silent, so silence proves nothing.
// Only an unanswered attach — a question with a known answer — counts.
check("an unanswered attach eventually counts as broken",
      ConnectionHealth.attachIsUnanswered(sentAt: t0.addingTimeInterval(-31), now: t0))
check("a slow attach is not yet broken",
      ConnectionHealth.attachIsUnanswered(sentAt: t0.addingTimeInterval(-29), now: t0) == false)
check("no outstanding attach is never broken",
      !ConnectionHealth.attachIsUnanswered(sentAt: nil, now: t0))

check("the watchdog gives up rather than retrying forever",
      ConnectionHealth.terminalResyncAttempts > 0 && ConnectionHealth.terminalResyncAttempts <= 3)
check("a fresh dial gets longer than a foreground probe",
      ConnectionHealth.connectTimeout > ConnectionHealth.probeTimeout)

check("age label is compact", ConnectionHealth.ageLabel(since: t0.addingTimeInterval(-480), now: t0) == "8m")
check("age label handles never", ConnectionHealth.ageLabel(since: nil, now: t0) == "—")

// MARK: - Terminal sizing

// The grid is what the host sizes its real tmux window to, so an off-by-one
// here wraps every line on the phone. Round DOWN on both axes: a column that
// only half fits is a column of text you would have to scroll sideways to read,
// which is the exact problem the feature removes.
let cell = TerminalGrid.cell(for: 13)
check("cell has a positive advance", cell.width > 0, "\(cell.width)")
check("cell has a positive line height", cell.height > 0, "\(cell.height)")
check("advance is plausible for monospace at 13pt",
      cell.width > 5 && cell.width < 11, "\(cell.width)")

let phone = TerminalGrid.grid(viewport: CGSize(width: 390, height: 600), fontSize: 13)
check("phone grid is realistic", phone.cols > 30 && phone.cols < 60, "\(phone.cols)")
check("phone rows are realistic", phone.rows > 20 && phone.rows < 60, "\(phone.rows)")

// Wider viewport, same type ⇒ strictly more columns; same viewport, bigger type
// ⇒ strictly fewer. Neither should ever go the other way.
let pad = TerminalGrid.grid(viewport: CGSize(width: 1000, height: 600), fontSize: 13)
check("more width means more columns", pad.cols > phone.cols, "\(pad.cols) vs \(phone.cols)")
let big = TerminalGrid.grid(viewport: CGSize(width: 390, height: 600), fontSize: 20)
check("bigger type means fewer columns", big.cols < phone.cols, "\(big.cols) vs \(phone.cols)")

// A zero-size viewport happens for one layout pass before SwiftUI has measured.
// It must clamp, not ask the Mac for a zero-column window.
let degenerate = TerminalGrid.grid(viewport: .zero, fontSize: 13)
check("degenerate viewport clamps to the floor",
      degenerate.cols == TerminalGrid.minimumColumns && degenerate.rows == TerminalGrid.minimumRows)
check("client floor matches the host's clamp", TerminalGrid.minimumColumns == 20)

// The grid must actually fit: cols * advance can never exceed the usable width,
// or the host lays out a pane one column too wide and every line wraps.
let usable = 390.0 - 24
check("computed columns fit inside the viewport",
      Double(phone.cols) * Double(cell.width) <= usable,
      "\(Double(phone.cols) * Double(cell.width)) > \(usable)")

// MARK: - Resize wire format

let resize = BridgeOutbound.resizeTerminal(id: "abc", cols: 44, rows: 50).json
check("resize verb", resize["type"] as? String == "resize_terminal")
check("resize carries the grid",
      resize["cols"] as? Int == 44 && resize["rows"] as? Int == 50)
check("resize names the session", resize["id"] as? String == "abc")

check("client advertises resize", BridgeProtocolVersion.capabilities.contains("resize"))

// A host that predates the feature answers without "resize", and the client
// must then leave its desk-sized pane alone rather than sending verbs into the
// void — this is what keeps the MATCH control off screen there.
let oldHost = payload("""
{"type":"hello_ack","protocol":2,"capabilities":["delta","actions","terminal"],"instanceKind":"udha-desktop"}
""")
if case .helloAck(let ack) = BridgeDecoder.decode(payload: oldHost) {
    check("old host does not claim resize", !ack.supportsResize)
} else {
    check("decodes hello_ack without resize", false)
}

let newHost = payload("""
{"type":"hello_ack","protocol":2,"capabilities":["delta","terminal","resize"],"instanceKind":"udha-desktop"}
""")
if case .helloAck(let ack) = BridgeDecoder.decode(payload: newHost) {
    check("new host claims resize", ack.supportsResize)
    // Same gate for rename: this host predates it, so the rename control has
    // to stay off screen rather than send a verb nothing will answer.
    check("resize host does not imply rename", !ack.supportsRename)
} else {
    check("decodes hello_ack with resize", false)
}

let renameHost = payload("""
{"type":"hello_ack","protocol":2,"capabilities":["delta","terminal","rename"],"instanceKind":"udha-desktop"}
""")
if case .helloAck(let ack) = BridgeDecoder.decode(payload: renameHost) {
    check("new host claims rename", ack.supportsRename)
} else {
    check("decodes hello_ack with rename", false)
}

// The host reports the grid it actually drew at. The client must not assume it
// won the request: tmux clamps, and a resize is refused outright under a dialog.
let sizedFrame = payload("""
{"type":"terminal_frame","id":"abc","seq":7,"ansi":"hello","cols":44,"rows":50}
""")
if case .terminalFrame(let frame) = BridgeDecoder.decode(payload: sizedFrame) {
    check("frame carries the achieved grid", frame.cols == 44 && frame.rows == 50)
} else {
    check("decodes a sized terminal_frame", false)
}

let unsizedFrame = payload("""
{"type":"terminal_frame","id":"abc","seq":8,"ansi":"hello"}
""")
if case .terminalFrame(let frame) = BridgeDecoder.decode(payload: unsizedFrame) {
    check("a host that omits the grid decodes as unknown, not zero",
          frame.cols == nil && frame.rows == nil)
} else {
    check("decodes an unsized terminal_frame", false)
}

// A grid on an attach is an *instruction* to the host, so it must be absent
// unless this device is actually asking to be matched. Shipping a default here
// would reshape the Mac's window every time a pane was opened — including on
// the re-attach that follows turning MATCH off, whose whole purpose is to give
// the window back.
let bareAttach = BridgeOutbound.attachTerminal(id: "abc", cols: nil, rows: nil).json
check("attach without a grid omits cols", bareAttach["cols"] == nil)
check("attach without a grid omits rows", bareAttach["rows"] == nil)
check("attach still names the session", bareAttach["id"] as? String == "abc")

let sizedAttach = BridgeOutbound.attachTerminal(id: "abc", cols: 48, rows: 30).json
check("attach carries the grid when matching",
      sizedAttach["cols"] as? Int == 48 && sizedAttach["rows"] as? Int == 30)

// MARK: - Status label + colour

// The reported bug: "Ready" was red on one row and the same grey as "Thinking"
// on the next. Cause — the word came from `phase`, the colour from `attention`,
// and the host only calls an awaitingReply session `needsYou` when Claude
// actually left a question. Same word, two situations. These assertions pin
// them apart and keep label and tone coming from one value.

func statusOf(_ json: String) -> SessionStatus? {
    let envelope = "{\"type\":\"sessions_full\",\"sessions\":[\(json)]}"
    guard case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(envelope)),
          let row = rows.first else { return nil }
    return row.status
}

let asked = statusOf("""
{"id":"a","label":"x","state":"idle","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"awaitingReply","attention":"needsYou","stale":false}
""")
check("a question waiting is named apart from a finished turn", asked?.label == "Needs reply",
      asked?.label ?? "nil")
check("and it is the colour that means act now", asked?.tone == .needsYou)

let finished = statusOf("""
{"id":"a","label":"x","state":"idle","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"awaitingReply","attention":"quiet","stale":false}
""")
check("a turn that simply ended is Ready", finished?.label == "Ready", finished?.label ?? "nil")
check("Ready is never the urgent colour", finished?.tone == .idle)

// The specific confusion: these two rows say different words now, and the words
// match their colours. Previously both said "Ready" and only the colour differed.
check("the two awaitingReply cases no longer share a word", asked?.label != finished?.label)

let stale = statusOf("""
{"id":"a","label":"x","state":"idle","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"awaitingReply","attention":"quiet","stale":true}
""")
check("an abandoned turn reads as Stale", stale?.label == "Stale", stale?.label ?? "nil")
check("Stale is dormant, not idle", stale?.tone == .dormant)

// Working states must not share a tone with idle ones — that was the other half
// of the complaint, "Thinking" and a quiet session looking alike.
for (phase, label) in [("thinking", "Thinking"), ("planning", "Planning"), ("starting", "Starting")] {
    let s = statusOf("""
    {"id":"a","label":"x","state":"working","stateEnteredSecAgo":5,"priority":"normal",
     "hasPendingPrompt":false,"phase":"\(phase)","attention":"working"}
    """)
    check("\(label) is labelled", s?.label == label, s?.label ?? "nil")
    check("\(label) reads as running", s?.tone == .working)
}

let tool = statusOf("""
{"id":"a","label":"x","state":"working","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"usingTool","phaseDetail":"Running npm test","attention":"working"}
""")
check("a tool names itself", tool?.label == "Running npm test", tool?.label ?? "nil")
check("a running tool is running", tool?.tone == .working)

let approval = statusOf("""
{"id":"a","label":"x","state":"needsInput","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":true,"phase":"awaitingApproval","attention":"needsYou"}
""")
check("approval still reads as needs-you", approval?.tone == .needsYou)

// A crash is yours to deal with, but it is not a question — worth its own
// colour so the two are separable at a glance.
let crashed = statusOf("""
{"id":"a","label":"x","state":"crashed","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"finished","attention":"needsYou"}
""")
check("a crash is labelled", crashed?.label == "Crashed", crashed?.label ?? "nil")
check("a crash is not the same colour as a question", crashed?.tone == .error)
check("but it still demands attention", crashed?.tone.demandsAttention == true)

let exited = statusOf("""
{"id":"a","label":"x","state":"exited","stateEnteredSecAgo":5,"priority":"normal",
 "hasPendingPrompt":false,"phase":"finished","attention":"quiet"}
""")
check("an exited session is dormant", exited?.tone == .dormant)
check("dormant asks for nothing", exited?.tone.demandsAttention == false)

// Every tone must be reachable, or the palette is claiming a distinction the
// board never actually draws.
check("every tone has a distinct raw name",
      Set(SessionStatus.Tone.allCases.map(\.rawValue)).count == SessionStatus.Tone.allCases.count)
check("only needsYou and error demand attention",
      SessionStatus.Tone.allCases.filter(\.demandsAttention).count == 2)

check("statusLabel still routes through the one derivation",
      statusOf("""
      {"id":"a","label":"x","state":"idle","stateEnteredSecAgo":5,"priority":"normal",
       "hasPendingPrompt":false,"phase":"idle","attention":"quiet"}
      """)?.label == "Idle")

// MARK: - Dialog options

// The bug: a phone could only ever answer "1" or Escape, because nothing read
// what the dialog's choices were. The host has always accepted an option
// number — the parameter simply never had a caller.

let optRow = """
{"type":"sessions_full","sessions":[{
  "id":"a","label":"x","state":"needsInput","stateEnteredSecAgo":3,"priority":"normal",
  "hasPendingPrompt":true,"phase":"awaitingApproval","attention":"needsYou",
  "options":[{"n":1,"label":"Yes","selected":true},
             {"n":2,"label":"Yes, and don't ask again","selected":false},
             {"n":3,"label":"No, and tell Claude what to do differently","selected":false}]}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(optRow)), let r = rows.first {
    check("all three choices decode", r.dialogOptions.count == 3, "\(r.dialogOptions.count)")
    check("numbers are the digits to press, not indices",
          r.dialogOptions.map(\.number) == [1, 2, 3])
    check("labels survive punctuation and commas",
          r.dialogOptions[2].label == "No, and tell Claude what to do differently",
          r.dialogOptions[2].label)
    check("the highlighted row is marked", r.dialogOptions[0].isSelected)
    check("only one row is highlighted",
          r.dialogOptions.filter(\.isSelected).count == 1)
} else {
    check("decodes a row carrying options", false)
}

// A host that predates this sends no options at all, and the client must fall
// back to plain approve / deny rather than rendering an empty choice list.
let noOpts = """
{"type":"sessions_full","sessions":[{"id":"a","label":"x","state":"needsInput",
 "stateEnteredSecAgo":3,"priority":"normal","hasPendingPrompt":true,
 "phase":"awaitingApproval","attention":"needsYou"}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(noOpts)), let r = rows.first {
    check("an older host yields no options", r.dialogOptions.isEmpty)
} else {
    check("decodes a row without options", false)
}

// The wire must carry the chosen digit. Sending approve with no option is what
// made every tap mean "1".
let approve2 = BridgeOutbound.approve(id: "abc", option: 2).json
check("approve carries the chosen option", approve2["option"] as? Int == 2)
check("approve names the session", approve2["id"] as? String == "abc")

let approveBare = BridgeOutbound.approve(id: "abc", option: nil).json
check("approve without a choice omits the key", approveBare["option"] == nil)

// MARK: - Terminal links
//
// The case that matters: `aws sso login --no-browser` prints a URL and then
// blocks, polling, while the person who has to open it is holding an iPad.

let ssoFrame = """
\u{1B}[2mAttempting to automatically open the SSO authorization page…\u{1B}[0m
\u{1B}[1mhttps://device.sso.eu-central-1.amazonaws.com/?user_code=WXYZ-TUVW\u{1B}[0m
"""
let ssoHits = TerminalLinks.detect(inANSI: ssoFrame)
check("finds the SSO URL through escapes", ssoHits.count == 1, "\(ssoHits.count)")
check("SSO URL is whole",
      ssoHits.first?.url.absoluteString
        == "https://device.sso.eu-central-1.amazonaws.com/?user_code=WXYZ-TUVW",
      ssoHits.first?.url.absoluteString ?? "nil")
check("SSO URL reads as a sign-in", ssoHits.first?.isSignIn == true)
check("carries the user code", ssoHits.first?.code == "WXYZ-TUVW", ssoHits.first?.code ?? "nil")

// The classic AWS output prints the code on its own line instead. The URL is
// still a sign-in — the shape says so even with no query to read.
let bareDevice = TerminalLinks.detect(in: "open https://device.sso.us-east-1.amazonaws.com/")
check("bare device URL is a sign-in", bareDevice.first?.isSignIn == true)
check("bare device URL has no code", bareDevice.first?.code == nil)

check("github device flow", TerminalLinks.detect(in: "https://github.com/login/device").first?.isSignIn == true)
check("ordinary link is not a sign-in",
      TerminalLinks.detect(in: "see https://docs.aws.amazon.com/cli/").first?.isSignIn == false)

// Offsets are what `ANSIText` styles the run with, so they have to be exact.
let inProse = "run https://example.com/a now"
let proseHit = TerminalLinks.detect(in: inProse)[0]
check("offsets bound the URL exactly",
      String(Array(inProse)[proseHit.start..<proseHit.end]) == "https://example.com/a")

// Prose punctuation is not part of the address; a matched pair inside one is.
check("trailing stop is dropped",
      TerminalLinks.detect(in: "at https://example.com/x.").first?.url.absoluteString
        == "https://example.com/x")
check("balanced brackets survive",
      TerminalLinks.detect(in: "https://en.wikipedia.org/wiki/Foo_(bar)").first?.url.absoluteString
        == "https://en.wikipedia.org/wiki/Foo_(bar)")
check("unbalanced bracket is dropped",
      TerminalLinks.detect(in: "(https://example.com/y)").first?.url.absoluteString
        == "https://example.com/y")

// A TUI box border sits flush against the text on a full row. Swallowing it
// would produce a URL that 404s.
check("box border stops the match",
      TerminalLinks.detect(in: "│ https://example.com/z │").first?.url.absoluteString
        == "https://example.com/z")

// NSDataDetector would light up every one of these. That is the reason this is
// hand-rolled.
check("no bare hostnames", TerminalLinks.detect(in: "edit Sources/App.swift in acme.ai/Bridge").isEmpty)
check("no scp-style paths", TerminalLinks.detect(in: "scp host.example.com:/tmp/x .").isEmpty)

// One chip per destination, however many times the frame repeats it.
let repeated = "https://example.com/a\nnoise\nhttps://example.com/a\nhttps://example.com/b"
check("chips are de-duplicated", TerminalLinks.detect(inANSI: repeated).count == 2,
      "\(TerminalLinks.detect(inANSI: repeated).count)")

// MARK: - Model and machine on the row

// The two fields the redesigned list reads: which model the session is running,
// and which machine is running it. Both are optional on the wire — a session
// with no statusLine sidecar has no model, and a row with no `host` is on the
// machine this client is talking to.
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload("""
    {"type":"sessions_full","sessions":[
     {"id":"a","label":"mac one","state":"working","stateEnteredSecAgo":3,
      "priority":"normal","hasPendingPrompt":false,"model":"Opus 5","isClaudeTUI":true},
     {"id":"b","label":"box one","state":"working","stateEnteredSecAgo":3,
      "priority":"normal","hasPendingPrompt":false,"model":"Sonnet 5","host":"devbox"},
     {"id":"c","label":"plain shell","state":"idle","stateEnteredSecAgo":3,
      "priority":"normal","hasPendingPrompt":false,"isClaudeTUI":false}]}
    """)) {
    check("model decodes", rows[0].model == "Opus 5", rows[0].model ?? "nil")
    check("local row has no host", rows[0].host == nil, rows[0].host ?? "nil")
    check("remote row carries its machine", rows[1].host == "devbox", rows[1].host ?? "nil")
    check("model badge is the model", rows[1].modelBadge == "Sonnet 5", rows[1].modelBadge ?? "nil")
    check("a session with no sidecar shows no badge", rows[0].modelBadge == "Opus 5")
    check("a non-Claude session says so instead", rows[2].modelBadge == "shell",
          rows[2].modelBadge ?? "nil")
    // The filter reads everything the row shows plus the things you might
    // remember about it.
    check("filter matches the label", rows[0].matches("mac"))
    check("filter matches the model", rows[1].matches("sonnet"))
    check("filter matches the machine", rows[1].matches("devbox"))
    check("filter rejects a miss", !rows[0].matches("zzz"))
} else {
    check("decodes rows carrying model and host", false)
}

// MARK: - Attachments

// `put_attachment` is the one verb that carries bulk. The token is what lets two
// screenshots be in flight for one session without their replies crossing.
let put = BridgeOutbound.putAttachment(id: "s1", token: "t1", name: "shot.jpg",
                                      mime: "image/jpeg", base64: "AAAB").json
check("put_attachment type", put["type"] as? String == "put_attachment")
check("put_attachment names the session", put["id"] as? String == "s1")
check("put_attachment carries its token", put["token"] as? String == "t1")
check("put_attachment carries the bytes", put["data"] as? String == "AAAB")
check("put_attachment declares the type", put["mime"] as? String == "image/jpeg")

if case .attachmentStaged(let id, let token, let path, _, let error) =
    BridgeDecoder.decode(payload: payload("""
    {"type":"attachment_staged","id":"s1","token":"t1",
     "path":"/tmp/udha/attachments/shot-a1b2c3.jpg","name":"shot-a1b2c3.jpg"}
    """)) {
    check("staged names its session", id == "s1", id ?? "nil")
    check("staged echoes the token", token == "t1", token)
    check("staged carries the path the session can read",
          path == "/tmp/udha/attachments/shot-a1b2c3.jpg", path ?? "nil")
    check("a staged reply has no error", error == nil)
} else {
    check("decodes attachment_staged", false)
}

// A refusal before the host could resolve a session carries neither id nor path;
// the client still has to be able to fail the right chip, which is why the token
// is the thing that matters.
if case .attachmentStaged(let id, let token, let path, _, let error) =
    BridgeDecoder.decode(payload: payload("""
    {"type":"attachment_staged","token":"t9","error":"unknown session"}
    """)) {
    check("failed staging has no session", id == nil)
    check("failed staging still has its token", token == "t9", token)
    check("failed staging has no path", path == nil)
    check("failed staging says why", error == "unknown session", error ?? "nil")
} else {
    check("decodes a failed attachment_staged", false)
}

// The capability gate: an older host never advertises `attachments`, and the
// paperclip stays off screen rather than picking a photo with nowhere to put it.
if case .helloAck(let ack) = BridgeDecoder.decode(payload: payload("""
    {"type":"hello_ack","protocol":2,"capabilities":["delta","actions","attachments"],
     "instanceKind":"Udha.app","staleAfterSec":900}
    """)) {
    check("ack advertises attachments", ack.supportsAttachments)
} else {
    check("decodes an ack with attachments", false)
}
if case .helloAck(let ack) = BridgeDecoder.decode(payload: payload("""
    {"type":"hello_ack","protocol":2,"capabilities":["delta","actions"],
     "instanceKind":"Udha.app","staleAfterSec":900}
    """)) {
    check("an older host advertises no attachments", !ack.supportsAttachments)
} else {
    check("decodes an ack without attachments", false)
}

// MARK: - Drop-out buckets

// Errors carry their own timestamps, so this series is real history from the
// first sample — one point per hour, oldest first, now on the right.
let dropNow = Date()
let drops = MachineHistory.dropsPerHour([
    MachineStats.ConnectionError(at: dropNow.addingTimeInterval(-60), code: "1006", text: "closed"),
    MachineStats.ConnectionError(at: dropNow.addingTimeInterval(-60 * 61), code: "1006", text: "closed"),
    MachineStats.ConnectionError(at: dropNow.addingTimeInterval(-60 * 61), code: "4002", text: "taken"),
    // Older than the window: counted nowhere rather than folded into hour 0.
    MachineStats.ConnectionError(at: dropNow.addingTimeInterval(-60 * 60 * 30), code: "1006", text: "old"),
], now: dropNow)
check("24 buckets", drops.count == 24, "\(drops.count)")
check("this hour holds one drop", drops[23] == 1, "\(drops[23])")
check("the hour before holds two", drops[22] == 2, "\(drops[22])")
check("a day-old drop is outside the window", drops.reduce(0, +) == 3, "\(drops.reduce(0, +))")

check("span of one sample is honest", MachineHistory.duration(dropNow, dropNow) == "0s")
check("span in seconds", MachineHistory.duration(dropNow.addingTimeInterval(-19), dropNow) == "19s")
check("span in minutes", MachineHistory.duration(dropNow.addingTimeInterval(-725), dropNow) == "12m")
check("span in hours", MachineHistory.duration(dropNow.addingTimeInterval(-3_840), dropNow) == "1h 4m")

// MARK: - Summary


// MARK: - Path collapsing in a status label
//
// A row that refused to truncate its `usingTool` label dragged the whole card
// off both edges of the phone; truncating it then kept the useless half. Both
// halves of that fix are asserted here.

check("collapses a long absolute path to its leaf",
      SessionRow.collapsePaths(in: "Running S=/tmp/claude-1000/-home-dev-projects-acme/node_modules/.bin/jest")
          == "Running S=jest",
      SessionRow.collapsePaths(in: "Running S=/tmp/claude-1000/-home-dev-projects-acme/node_modules/.bin/jest"))

check("keeps the flag that introduced the path",
      SessionRow.collapsePaths(in: "Building --out=/home/dev/projects/work/very/long/path/dist").hasPrefix("Building --out="),
      SessionRow.collapsePaths(in: "Building --out=/home/dev/projects/work/very/long/path/dist"))

check("leaves a short path alone",
      SessionRow.collapsePaths(in: "Editing src/App.swift") == "Editing src/App.swift",
      SessionRow.collapsePaths(in: "Editing src/App.swift"))

check("leaves a path-free label alone",
      SessionRow.collapsePaths(in: "Drafting the migration plan") == "Drafting the migration plan",
      SessionRow.collapsePaths(in: "Drafting the migration plan"))

check("collapses every path in a compound command",
      SessionRow.collapsePaths(in: "Running cd /tmp/claude-1000/-home-dev-projects && /usr/local/bin/pnpm-workspace-runner build")
          == "Running cd -home-dev-projects && pnpm-workspace-runner build",
      SessionRow.collapsePaths(in: "Running cd /tmp/claude-1000/-home-dev-projects && /usr/local/bin/pnpm-workspace-runner build"))


// MARK: - What counts as blocked
//
// `awaitingReply` is both "Claude asked you a question" and "Claude's turn
// ended". Treating the phase alone as blocked pinned an undismissable card
// above the composer on every resting session.

let blockedRows = """
{"type":"sessions_full","sessions":[
 {"id":"a","label":"approval","phase":"awaitingApproval","attention":"needsYou"},
 {"id":"b","label":"asked","phase":"awaitingReply","attention":"needsYou"},
 {"id":"c","label":"resting","phase":"awaitingReply","attention":"quiet"},
 {"id":"d","label":"stale","phase":"awaitingReply","attention":"quiet","stale":true},
 {"id":"e","label":"working","phase":"usingTool","attention":"working"}]}
"""
if case .sessionsFull(let rows, _) = BridgeDecoder.decode(payload: payload(blockedRows)) {
    check("an approval blocks", rows[0].isBlocking)
    check("an unanswered question blocks", rows[1].isBlocking)
    check("a finished turn does not block", !rows[2].isBlocking, rows[2].statusLabel)
    check("a stale session does not block", !rows[3].isBlocking, rows[3].statusLabel)
    check("a working session does not block", !rows[4].isBlocking)
} else {
    check("decodes the blocked fixture", false)
}

// MARK: - Tool on create
//
// The host has always read `tool` and defaulted to Claude without it, so a
// phone that never sent one could only ever start Claude sessions.

let created = BridgeOutbound.createSession(directory: "/tmp/x", label: "l", prompt: nil,
                                           tool: .codex, permission: .workspaceWrite,
                                           worktree: nil).json
check("create carries the tool", created["tool"] as? String == "codex",
      String(describing: created["tool"]))
check("create carries that tool's own permission rung",
      created["permission"] as? String == "workspaceWrite",
      String(describing: created["permission"]))

let noTool = BridgeOutbound.createSession(directory: "/tmp/x", label: nil, prompt: nil,
                                          tool: nil, permission: nil, worktree: nil).json
check("tool is omitted when unset, so an older host keeps its default",
      noTool["tool"] == nil)

// Each CLI names its four rungs differently; sending one tool's name to another
// is not an error at the host, it just quietly gives you something else.
check("Claude ladder", SessionTool.claude.modes == [.acceptEdits, .ask, .plan, .bypass])
check("ChatGPT ladder", SessionTool.codex.modes == [.workspaceWrite, .ask, .readOnly, .bypass])
check("Qwen ladder", SessionTool.qwen.modes == [.autoEdit, .ask, .plan, .yolo])
check("every tool opens on the rung the host would have picked",
      SessionTool.allCases.allSatisfy { $0.modes.contains($0.defaultMode) })
check("both bypass rungs are marked dangerous",
      PermissionMode.bypass.isDangerous && PermissionMode.yolo.isDangerous)
check("ChatGPT is the label for the codex CLI", SessionTool.codex.label == "ChatGPT")

check("videos route to Mac when the active session host is headless",
      VideoLibraryRouting.hostID(preferred: nil, current: nil, active: "box", capable: ["mac"]) == "mac")
check("videos wait when no machine has advertised a library",
      VideoLibraryRouting.hostID(preferred: nil, current: nil, active: "box", capable: []) == nil)
check("video library stays on chosen Mac when terminal host changes",
      VideoLibraryRouting.hostID(preferred: nil, current: "mac", active: "other", capable: ["other", "mac"]) == "mac")
check("explicit video host choice wins",
      VideoLibraryRouting.hostID(preferred: "other", current: "mac", active: "box", capable: ["mac", "other"]) == "other")
check("offline video host falls back to another capable Mac",
      VideoLibraryRouting.hostID(preferred: "offline", current: "offline", active: "box", capable: ["mac"]) == "mac")


// MARK: - Folders (the list beside sessions_full, and the row's own keys)

let folderedFull = """
{"type":"sessions_full",
 "folders":[{"id":"F1","name":"Clients"},{"id":"F2","name":"Old","hidden":true}],
 "sessions":[
  {"id":"a","label":"in-folder","directory":"/x","state":"working","stateEnteredSecAgo":1,"priority":"normal","hasPendingPrompt":false,"folder":"F1"},
  {"id":"b","label":"hidden-row","directory":"/x","state":"working","stateEnteredSecAgo":1,"priority":"normal","hasPendingPrompt":false,"hidden":true},
  {"id":"c","label":"loose","directory":"/x","state":"working","stateEnteredSecAgo":1,"priority":"normal","hasPendingPrompt":false}]}
"""
if case .sessionsFull(let rows, let folders) = BridgeDecoder.decode(payload: payload(folderedFull)) {
    check("folders decode in host order", folders.map(\.id) == ["F1", "F2"], "\(folders.map(\.id))")
    check("folder hidden defaults false", folders[0].hidden == false && folders[1].hidden == true)
    check("row folder id", rows[0].folderID == "F1", rows[0].folderID ?? "nil")
    check("row hidden flag", rows[1].hidden && !rows[0].hidden && !rows[2].hidden)
    check("loose row has no folder", rows[2].folderID == nil)
} else {
    check("decodes sessions_full with folders", false)
}

// A host that predates folders sends no list at all.
if case .sessionsFull(_, let folders) = BridgeDecoder.decode(payload: payload(v1Row)) {
    check("no folders key decodes as empty", folders.isEmpty)
}

// The folder itself round-trips with `hidden` only when true — the wire rule.
do {
    let shown = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionFolder(id: "F", name: "n"))) as? [String: Any]
    check("folder omits hidden when false", shown?["hidden"] == nil)
    let hidden = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionFolder(id: "F", name: "n", hidden: true))) as? [String: Any]
    check("folder carries hidden when true", (hidden?["hidden"] as? Bool) == true)
} catch { check("folder encodes", false, "\(error)") }

check("nudge up", SessionFolder.nudged(["a", "b", "c"], moving: "b", up: true) == ["b", "a", "c"])
check("nudge down", SessionFolder.nudged(["a", "b", "c"], moving: "b", up: false) == ["a", "c", "b"])
check("nudge at top is a no-op", SessionFolder.nudged(["a", "b"], moving: "a", up: true) == ["a", "b"])
check("nudge of unknown id is a no-op", SessionFolder.nudged(["a", "b"], moving: "z", up: true) == ["a", "b"])

// Outbound shapes, byte-for-byte what the desktop's handlers read.
do {
    let j = BridgeOutbound.setSessionFolder(id: "s", folder: "F1").json
    check("set_session_folder", j["type"] as? String == "set_session_folder" && j["id"] as? String == "s" && j["folder"] as? String == "F1")
    let loose = BridgeOutbound.setSessionFolder(id: "s", folder: nil).json
    check("set_session_folder loose omits folder", loose["folder"] == nil)
    let h = BridgeOutbound.setSessionHidden(id: "s", hidden: true).json
    check("set_session_hidden", h["type"] as? String == "set_session_hidden" && h["hidden"] as? Bool == true)
    let c = BridgeOutbound.createFolder(id: "F9", name: "New").json
    check("create_folder carries client id", c["type"] as? String == "create_folder" && c["id"] as? String == "F9" && c["name"] as? String == "New")
    let r = BridgeOutbound.renameFolder(id: "F9", name: "Renamed").json
    check("rename_folder", r["type"] as? String == "rename_folder" && r["name"] as? String == "Renamed")
    let d = BridgeOutbound.deleteFolder(id: "F9").json
    check("delete_folder", d["type"] as? String == "delete_folder" && d["id"] as? String == "F9")
    let fh = BridgeOutbound.setFolderHidden(id: "F9", hidden: false).json
    check("set_folder_hidden", fh["type"] as? String == "set_folder_hidden" && fh["hidden"] as? Bool == false)
    let ro = BridgeOutbound.reorderFolders(order: ["F2", "F1"]).json
    check("reorder_folders", ro["type"] as? String == "reorder_folders" && ro["order"] as? [String] == ["F2", "F1"])
    let rs = BridgeOutbound.reorderSessions(order: ["b", "a"]).json
    check("reorder_sessions", rs["type"] as? String == "reorder_sessions" && rs["order"] as? [String] == ["b", "a"])
    check("unhide_all", BridgeOutbound.unhideAll.json["type"] as? String == "unhide_all")
    let cs = BridgeOutbound.createSession(directory: "/x", label: nil, prompt: nil, tool: nil, permission: nil, worktree: nil, folder: "F1").json
    check("create_session carries folder", cs["folder"] as? String == "F1")
    let csLoose = BridgeOutbound.createSession(directory: "/x", label: nil, prompt: nil, tool: nil, permission: nil, worktree: nil).json
    check("create_session omits folder when loose", csLoose["folder"] == nil)
}

check("client advertises folders", BridgeProtocolVersion.capabilities.contains("folders"))
check("client advertises reorder", BridgeProtocolVersion.capabilities.contains("reorder"))
let folderAck = HelloAck(protocolVersion: 2, capabilities: ["folders"], instanceKind: "udha-desktop", clientID: nil, staleAfterSec: 1)
check("hello_ack folders gate", folderAck.supportsFolders && !folderAck.supportsReorder)

// Claude logins
do {
    check("client advertises accounts", BridgeProtocolVersion.capabilities.contains("accounts"))
    let rot = BridgeOutbound.rotateAccount(id: "S1", to: "/home/b/.claude-2").json
    check("rotate_account", rot["type"] as? String == "rotate_account" && rot["id"] as? String == "S1"
          && rot["to"] as? String == "/home/b/.claude-2")
    check("rotate_account omits to for emptiest", BridgeOutbound.rotateAccount(id: "S1", to: nil).json["to"] == nil)
    check("fetch_accounts", BridgeOutbound.fetchAccounts.json["type"] as? String == "fetch_accounts")
    let msg: [String: Any] = [
        "type": "accounts",
        "pools": [["pathPrefix": "/Users/b/projects/work", "members": [
            ["dir": "/Users/b/.claude", "name": "claude", "email": "a@x.com", "fiveHour": 26, "sevenDay": 7.4],
            ["dir": "/Users/b/.claude-2", "name": "claude-2", "limitedUntil": Date().timeIntervalSince1970 + 3600],
        ]]],
        "default": ["dir": "/Users/b/.claude", "name": "claude"],
    ]
    if case .accounts(let h) = BridgeDecoder.decode(payload: msg) {
        let pool = h.pool(for: "/Users/b/projects/work/udha")
        check("accounts pool matched by prefix", pool?.members.count == 2)
        check("accounts pool not matched by sibling", h.pool(for: "/Users/b/projects/workx") == nil)
        check("login headroom", pool?.members[0].headroom() == "5h 26% · 7d 7%", pool?.members[0].headroom() ?? "")
        check("login display name is email", pool?.members[0].displayName == "a@x.com")
        check("limited login", pool?.members[1].isLimited() == true)
        check("default login", h.defaultLogin?.name == "claude")
    } else {
        check("accounts decodes", false)
    }
    let ack = HelloAck(protocolVersion: 2, capabilities: ["accounts"], instanceKind: "udha-desktop", clientID: nil, staleAfterSec: 1)
    check("hello_ack accounts gate", ack.supportsAccounts)
}

print("\n\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
