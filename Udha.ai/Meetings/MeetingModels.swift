import Foundation

/// Mirrors the desktop's `Meetings/MeetingModels.swift` over the wire.
///
/// The desktop is the source of truth for meetings it recorded; meetings this
/// phone records locally are created here and pushed up. Both use the same
/// shape so one list can hold either — `origin` is the only thing that differs.

enum MeetingMode: String, Codable, Hashable, Sendable {
    case standard
    case processMapping

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingMode(rawValue: raw) ?? .standard
    }
}

/// Where the recording happened. iOS cannot capture system audio, so a phone
/// recording is mic-only and its transcript has no `Them` separation — the UI
/// says so rather than pretending the streams were split.
enum MeetingOrigin: String, Codable, Hashable, Sendable {
    case host    // recorded on the Mac: mic + system audio, diarized
    case local   // recorded on this device: mic only

    var audioLabel: String {
        switch self {
        case .host:  return "mic + system audio"
        case .local: return "mic only"
        }
    }
}

/// Where a locally-recorded meeting stands on its way to the host.
///
/// Persisted in the meeting folder, so a meeting recorded with the Mac offline
/// survives a relaunch and is still pushed days later. Host-origin meetings are
/// always `.synced` — there is nothing to upload.
enum MeetingSyncState: String, Codable, Hashable, Sendable {
    case localOnly    // on disk here, not yet queued (still being written)
    case queued       // waiting for a host connection
    case uploading    // push sent, waiting on the ack
    case synced       // host has it; its notes pass may still be running
    case failed       // host rejected it — retry is manual

    /// Shown under the row title. Nil where the state is unremarkable.
    var label: String? {
        switch self {
        case .localOnly, .queued: return "waiting for Mac"
        case .uploading:          return "uploading…"
        case .synced:             return nil
        case .failed:             return "upload failed"
        }
    }

    var needsUpload: Bool { self == .queued || self == .uploading || self == .failed }
}

struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var done: Bool

    init(id: String = UUID().uuidString, text: String, owner: String? = nil, done: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        owner = try? c.decode(String.self, forKey: .owner)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }

    enum CodingKeys: String, CodingKey { case id, text, owner, done }
}

/// List-level metadata. The heavy parts (transcript, decisions, full summary)
/// arrive separately via `fetch_meeting`, so the list stays cheap — the same
/// split the desktop store uses on disk.
struct Meeting: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var endedAt: Date?
    var mode: MeetingMode
    var origin: MeetingOrigin
    var hasAudio: Bool
    /// False with a non-nil `endedAt` means the notes pass never completed —
    /// the row shows "Needs summary" and offers a retry.
    var finalized: Bool
    /// Present once the detail has been fetched.
    var summary: String?
    var decisions: [String]?
    var actionItems: [ActionItem]?
    var transcript: [TranscriptSegment]?
    /// Hand-written notes, editable from any client. Distinct from `summary`,
    /// which the model generates and a re-run would overwrite.
    var userNotes: String?
    /// The polished Markdown notes the finalize pass produces — the user's
    /// rough notes as the backbone, corrected and expanded from the transcript.
    /// This is the primary thing to read after a call; `summary` is the blurb.
    var notesMarkdown: String?
    /// Local bookkeeping. Never read off the wire from the host — a host row
    /// is authoritative about content, not about this phone's upload queue.
    var syncState: MeetingSyncState = .synced
    /// True when `summary`/`notesMarkdown` came from the phone's own pass
    /// because the Mac was unreachable. The host's pass overwrites it.
    var provisionalSummary: Bool = false

    var durationSeconds: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(createdAt)
    }

    var isRecording: Bool { endedAt == nil }
    /// The detail payload has been fetched. Deliberately not "there is
    /// something worth reading" — the host sends an empty summary for a meeting
    /// it has not summarised yet, and conflating the two rendered a blank pane.
    var hasDetail: Bool {
        summary != nil || notesMarkdown != nil || transcript != nil || actionItems != nil
    }

    /// There is actual generated content to show.
    var hasNotesContent: Bool {
        displayNotes != nil
            || !(decisions?.isEmpty ?? true)
            || !(actionItems?.isEmpty ?? true)
    }

    /// The body to render on the Summary tab: the polished notes when the
    /// finalize pass produced them, the blurb otherwise.
    var displayNotes: String? {
        if let notesMarkdown, !notesMarkdown.isEmpty { return notesMarkdown }
        if let summary, !summary.isEmpty { return summary }
        return nil
    }

    /// "Aug 21 · 32m · mapped" — the row's second line.
    ///
    /// The upload state outranks "needs summary": when the Mac has never seen
    /// the recording, saying so is more useful than saying the notes are
    /// missing, which is merely the consequence.
    var listMeta: String {
        var parts: [String] = [Meeting.dayFormatter.string(from: createdAt)]
        if let duration = durationSeconds {
            parts.append("\(Int(duration / 60))m")
        }
        if mode == .processMapping { parts.append("mapped") }
        if let sync = syncState.label {
            parts.append(sync)
        } else if endedAt != nil && !finalized {
            parts.append("needs summary")
        }
        return parts.joined(separator: " · ")
    }

    /// "Aug 21, 2026 · 3:04 PM · 32 min · mic only" — the detail header.
    var detailStamp: String {
        var parts: [String] = [Meeting.stampFormatter.string(from: createdAt)]
        if let duration = durationSeconds {
            parts.append("\(Int(duration / 60)) min")
        }
        parts.append(origin.audioLabel)
        return parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }()

    init(id: String = UUID().uuidString,
         title: String,
         createdAt: Date = Date(),
         endedAt: Date? = nil,
         mode: MeetingMode = .standard,
         origin: MeetingOrigin = .local,
         hasAudio: Bool = false,
         finalized: Bool = false,
         summary: String? = nil,
         decisions: [String]? = nil,
         actionItems: [ActionItem]? = nil,
         transcript: [TranscriptSegment]? = nil,
         userNotes: String? = nil,
         notesMarkdown: String? = nil,
         syncState: MeetingSyncState = .synced,
         provisionalSummary: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.mode = mode
        self.origin = origin
        self.hasAudio = hasAudio
        self.finalized = finalized
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.transcript = transcript
        self.userNotes = userNotes
        self.notesMarkdown = notesMarkdown
        self.syncState = syncState
        self.provisionalSummary = provisionalSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        // Epoch seconds on the wire — the desktop sends timeIntervalSince1970,
        // and a date-string format mismatch is a silent whole-list failure.
        let created = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        createdAt = Date(timeIntervalSince1970: created)
        if let ended = try? c.decode(Double.self, forKey: .endedAt) {
            endedAt = Date(timeIntervalSince1970: ended)
        } else {
            endedAt = nil
        }
        mode = (try? c.decode(MeetingMode.self, forKey: .mode)) ?? .standard
        origin = (try? c.decode(MeetingOrigin.self, forKey: .origin)) ?? .host
        hasAudio = (try? c.decode(Bool.self, forKey: .hasAudio)) ?? false
        finalized = (try? c.decode(Bool.self, forKey: .finalized)) ?? true
        summary = try? c.decode(String.self, forKey: .summary)
        decisions = try? c.decode([String].self, forKey: .decisions)
        actionItems = try? c.decode([ActionItem].self, forKey: .actionItems)
        transcript = try? c.decode([TranscriptSegment].self, forKey: .transcript)
        userNotes = try? c.decode(String.self, forKey: .userNotes)
        notesMarkdown = try? c.decode(String.self, forKey: .notesMarkdown)
        // Absent on the wire — the host has no opinion about this phone's
        // upload queue. Only the on-disk store writes these.
        syncState = (try? c.decode(MeetingSyncState.self, forKey: .syncState)) ?? .synced
        provisionalSummary = (try? c.decode(Bool.self, forKey: .provisionalSummary)) ?? false
    }

    /// Explicit, because the synthesised encoder would write `Date` as seconds
    /// since 2001 while `init(from:)` reads epoch seconds — a silent 31-year
    /// skew on every meeting the store round-trips. Encoding and decoding have
    /// to agree, and epoch is what the wire format already uses.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encodeIfPresent(endedAt?.timeIntervalSince1970, forKey: .endedAt)
        try c.encode(mode.rawValue, forKey: .mode)
        try c.encode(origin.rawValue, forKey: .origin)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encode(finalized, forKey: .finalized)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(decisions, forKey: .decisions)
        try c.encodeIfPresent(actionItems, forKey: .actionItems)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(userNotes, forKey: .userNotes)
        try c.encodeIfPresent(notesMarkdown, forKey: .notesMarkdown)
        try c.encode(syncState.rawValue, forKey: .syncState)
        try c.encode(provisionalSummary, forKey: .provisionalSummary)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, endedAt, mode, origin, hasAudio, finalized
        case summary, decisions, actionItems, transcript, userNotes, notesMarkdown
        case syncState, provisionalSummary
    }

    /// Dictionary form for `push_local_meeting`. Hand-built rather than
    /// `JSONEncoder`-derived because the relay envelope is assembled with
    /// `JSONSerialization`, and dates must go out as epoch seconds to match
    /// what `init(from:)` above expects to read back.
    var wirePayload: [String: Any]? {
        var out: [String: Any] = [
            "id": id,
            "title": title,
            "createdAt": createdAt.timeIntervalSince1970,
            "mode": mode.rawValue,
            "origin": origin.rawValue,
            "hasAudio": hasAudio,
            "finalized": finalized,
        ]
        if let endedAt { out["endedAt"] = endedAt.timeIntervalSince1970 }
        if let summary { out["summary"] = summary }
        // The rough notes typed during the call. The host's finalize pass uses
        // these as the backbone of the polished notes, so they must go up even
        // when everything else about the meeting is empty.
        if let userNotes { out["userNotes"] = userNotes }
        if let notesMarkdown { out["notesMarkdown"] = notesMarkdown }
        if let decisions { out["decisions"] = decisions }
        if let actionItems {
            out["actionItems"] = actionItems.map { item -> [String: Any] in
                var d: [String: Any] = ["id": item.id, "text": item.text, "done": item.done]
                if let owner = item.owner { d["owner"] = owner }
                return d
            }
        }
        if let transcript {
            out["transcript"] = transcript.map { seg in
                [
                    "id": seg.id,
                    "source": seg.source.rawValue,
                    "speaker": seg.speaker,
                    "text": seg.text,
                    "startTime": seg.startTime,
                    "endTime": seg.endTime,
                ] as [String: Any]
            }
        }
        return JSONSerialization.isValidJSONObject(out) ? out : nil
    }
}

// MARK: - Transcript

enum TranscriptSource: String, Codable, Hashable, Sendable {
    case mic      // "Me"
    case system   // "Them" — host recordings only

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TranscriptSource(rawValue: raw) ?? .mic
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var source: TranscriptSource
    /// "Me", "Them", "Them 1" — diarized labels are only stable within one
    /// STT chunk, which is why the label travels with the segment.
    var speaker: String
    var text: String
    /// Seconds from meeting start, counting active recording time only.
    var startTime: TimeInterval
    var endTime: TimeInterval

    /// "12:06"
    var stamp: String {
        String(format: "%02d:%02d", Int(startTime) / 60, Int(startTime) % 60)
    }

    var isMe: Bool { source == .mic }

    init(id: String = UUID().uuidString,
         source: TranscriptSource,
         speaker: String,
         text: String,
         startTime: TimeInterval,
         endTime: TimeInterval) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        source = (try? c.decode(TranscriptSource.self, forKey: .source)) ?? .mic
        speaker = (try? c.decode(String.self, forKey: .speaker)) ?? "Me"
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        startTime = (try? c.decode(Double.self, forKey: .startTime)) ?? 0
        endTime = (try? c.decode(Double.self, forKey: .endTime)) ?? 0
    }

    enum CodingKeys: String, CodingKey { case id, source, speaker, text, startTime, endTime }
}

// MARK: - Ask

/// One turn of the "Ask about this call" thread.
struct MeetingAskTurn: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable { case you, udha }
    var id = UUID()
    var role: Role
    var text: String
}
