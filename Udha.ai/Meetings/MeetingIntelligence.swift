import Foundation
import AVFoundation
import Speech
import Observation
import os

/// Prompts for the phone's own passes.
///
/// Deliberately worded to match the desktop's `MeetingPrompts` — the point is
/// that a meeting summarised here and the same meeting summarised on the Mac
/// read like the same product, so the fallback is not obviously the lesser
/// path. Process mapping is not ported: it needs the diagram model, and that
/// stays a desktop feature.
enum PhoneMeetingPrompts {

    static let finalizeSystem = """
    The meeting has ended. You receive the full transcript ("Me" is the app's \
    user; this recording is mic-only, so everything is attributed to Me even \
    when others were speaking in the room), the user's own rough notes typed \
    during the call, and produce the final record.

    - title: <= 8 words, specific ("Acme onboarding process discovery"), no date.
    - summary: 2-4 sentences, outcomes first.
    - notes_markdown: polished meeting notes in Markdown. Use the user's rough \
    notes as the backbone — every point they wrote must appear, corrected and \
    expanded with specifics from the transcript (numbers, names, decisions). \
    Then add clearly-separated sections for important topics the rough notes \
    missed. Use ## headings and bullets; bold decisions. Do not include an \
    action-items section (kept separately) and do not fabricate content absent \
    from both inputs.
    - decisions: things the meeting actually settled, one line each. Empty when \
    nothing was decided — an invented decision is worse than none.
    - action_items: concrete commitments and follow-ups. Give ids "new-1", \
    "new-2", … Set owner only when the transcript makes it explicit, otherwise \
    null. The transcript is imperfect speech-to-text: ignore filler, infer \
    obvious intent, never invent commitments that were not made. At most 20.
    """

    static let finalizeSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "summary", "notes_markdown", "decisions", "action_items"],
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "notes_markdown": ["type": "string"],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "text", "owner", "done"],
                    "properties": [
                        "id": ["type": "string"],
                        "text": ["type": "string"],
                        "owner": ["anyOf": [["type": "string"], ["type": "null"]]],
                        "done": ["type": "boolean"],
                    ],
                ],
            ],
        ],
    ]

    static let askSystem = """
    You are sitting in on a meeting that is happening right now, with access to \
    the live transcript so far ("Me" is the user you are helping; the recording \
    is mic-only, so the far side of the room is transcribed under the same \
    label). The user is asking you something mid-call and needs it fast.

    - Answer only from the transcript and the user's notes. If the answer is \
    not in there, say so plainly rather than guessing — being wrong in a \
    meeting is worse than being unhelpful.
    - Be brief: a few sentences, or a short list. The user is reading this while \
    someone talks at them.
    - Quote or paraphrase what was actually said when it helps them trust it.
    - No preamble, no "based on the transcript".
    """

    /// The one that earns the feature its keep.
    static let soundSmartQuestion = """
    Based on the last several minutes of this conversation, give me one or two \
    things I could say next that would make me sound like the sharpest person in \
    the room: an incisive question that exposes something nobody has addressed, \
    or an observation that synthesises what has been said into a point others \
    have not made yet. Ground each one in something actually said. No more than \
    two sentences each, phrased exactly as I would say them out loud, with no \
    lead-in.
    """

    static let suggestions: [String] = [
        "Make me sound smart",
        "Catch me up",
        "What have they committed to?",
        "What should I ask next?",
        "Any numbers said out loud?",
    ]

    static func question(for suggestion: String) -> String {
        suggestion == "Make me sound smart" ? soundSmartQuestion : suggestion
    }
}

/// Runs the end-of-meeting notes pass on this device when the Mac cannot.
@MainActor
@Observable
final class MeetingNotesEngine {

    /// Ids currently being summarised, so the UI can say so and a second tap
    /// cannot start a duplicate pass.
    private(set) var working: Set<String> = []
    private(set) var lastError: String?

    private let store: MeetingStore
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "notesengine")

    init(store: MeetingStore) {
        self.store = store
    }

    func isWorking(on id: String) -> Bool { working.contains(id) }

    var canSummarizeLocally: Bool { ClaudeDirect.hasKey }

    /// Exposed for the views, so they do not each reach into the keychain.
    static var hasKey: Bool { ClaudeDirect.hasKey }

    /// Summarises only when the host is not going to. When the Mac is reachable
    /// its pass is canonical and this would just be a second, worse answer.
    func summarizeIfNeeded(_ meeting: Meeting, bridge: UdhaBridge) async {
        guard !bridge.status.isReady else { return }
        await summarize(meeting, bridge: bridge)
    }

    /// Runs the pass regardless — the explicit "Summarise on this phone" tap.
    func summarize(_ meeting: Meeting, bridge: UdhaBridge) async {
        guard !working.contains(meeting.id) else { return }
        guard let client = ClaudeDirect() else { return }
        let transcript = (meeting.transcript ?? [])
            .map { "[\($0.stamp)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        guard !transcript.isEmpty || !(meeting.userNotes ?? "").isEmpty else { return }

        working.insert(meeting.id)
        lastError = nil
        defer { working.remove(meeting.id) }

        let user = """
        ## Transcript
        \(transcript.isEmpty ? "(no transcript was captured)" : transcript)

        ## The user's rough notes
        \(meeting.userNotes?.isEmpty == false ? meeting.userNotes! : "(none typed)")
        """

        do {
            let result = try await client.structured(
                system: PhoneMeetingPrompts.finalizeSystem,
                user: user,
                schema: PhoneMeetingPrompts.finalizeSchema,
                model: ClaudeDirect.notesModel
            )
            apply(result, to: meeting.id, bridge: bridge)
        } catch {
            log.error("phone notes pass failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    private func apply(_ result: [String: Any], to id: String, bridge: UdhaBridge) {
        let items = (result["action_items"] as? [[String: Any]] ?? []).map { raw in
            ActionItem(
                id: (raw["id"] as? String) ?? UUID().uuidString,
                text: (raw["text"] as? String) ?? "",
                owner: raw["owner"] as? String,
                done: (raw["done"] as? Bool) ?? false
            )
        }.filter { !$0.text.isEmpty }

        guard let updated = store.mutate(id: id, { meeting in
            if let title = result["title"] as? String, !title.isEmpty { meeting.title = title }
            meeting.summary = result["summary"] as? String
            meeting.notesMarkdown = result["notes_markdown"] as? String
            meeting.decisions = (result["decisions"] as? [String])?.filter { !$0.isEmpty }
            meeting.actionItems = items
            // Not `finalized`: the Mac has still never seen it, and the row
            // should keep saying so. This is a stand-in, and says so.
            meeting.provisionalSummary = true
        }) else { return }
        bridge.applyLocalSummary(updated)
    }
}

/// Re-runs speech recognition over a meeting's saved audio.
///
/// This is what the always-on audio file buys. When live transcription fails —
/// a missing model, an interrupted session, a route change at the wrong moment
/// — the recording is not lost, it is just not transcribed yet, and this turns
/// it back into a normal meeting.
@MainActor
@Observable
final class MeetingRetranscriber {

    private(set) var working: Set<String> = []
    private(set) var progress: String?
    private(set) var lastError: String?

    private let store: MeetingStore
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "retranscribe")

    init(store: MeetingStore) {
        self.store = store
    }

    func isWorking(on id: String) -> Bool { working.contains(id) }

    /// True when there is audio to work from — the button should not exist
    /// otherwise.
    func canRetranscribe(_ meeting: Meeting) -> Bool {
        meeting.origin == .local && store.audioURL(for: meeting.id) != nil
    }

    func retranscribe(_ meeting: Meeting, bridge: UdhaBridge) async {
        guard !working.contains(meeting.id) else { return }
        guard let url = store.audioURL(for: meeting.id) else {
            lastError = "There is no saved audio for this meeting."
            return
        }
        working.insert(meeting.id)
        lastError = nil
        progress = "preparing"
        defer {
            working.remove(meeting.id)
            progress = nil
        }

        do {
            let segments = try await Self.transcribe(file: url) { [weak self] note in
                self?.progress = note
            }
            guard !segments.isEmpty else {
                lastError = "Nothing could be recognised in the saved audio."
                return
            }
            guard let updated = store.mutate(id: meeting.id, { m in
                m.transcript = segments
                // A fresh transcript invalidates whatever was summarised from
                // the old one.
                m.summary = nil
                m.notesMarkdown = nil
                m.decisions = nil
                m.provisionalSummary = false
                m.finalized = false
                m.syncState = .queued
            }) else { return }
            bridge.applyLocalSummary(updated)
            bridge.flushOutbox()
        } catch {
            log.error("re-transcribe failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Offline transcription of a finished file. `SpeechAnalyzer` reads an
    /// `AVAudioFile` directly, so this is the same engine the live path uses.
    private static func transcribe(file url: URL,
                                   note: @escaping @MainActor (String) -> Void) async throws -> [TranscriptSegment] {
        let locale = await bestLocale()
        guard let locale else { throw RetranscribeError.noModel }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            await note("downloading speech model")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        await note("transcribing")
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The collector owns the array and hands it back, rather than the two
        // tasks sharing one — the results arrive on the analyzer's task.
        let collector = Task { () -> [TranscriptSegment] in
            var out: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    source: .mic,
                    speaker: "Me",
                    text: text,
                    startTime: result.range.start.isNumeric ? result.range.start.seconds : 0,
                    endTime: result.range.end.isNumeric ? result.range.end.seconds : 0
                ))
            }
            return out
        }

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return (try? await collector.value) ?? []
    }

    private static func bestLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.identifier(.bcp47).hasPrefix("en") } ?? supported.first
    }

    enum RetranscribeError: LocalizedError {
        case noModel
        var errorDescription: String? {
            "No speech model is available for \(Locale.current.identifier)."
        }
    }
}

/// Answers questions about the call happening right now, on this device.
///
/// The host cannot help here: a phone recording is only pushed when it ends, so
/// asking the Mac about an in-flight local meeting was a message about an id it
/// had never seen, and the pane simply spun forever.
@MainActor
final class MeetingAskEngine {

    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "askengine")

    /// Answers from the live transcript, appending both turns to the bridge's
    /// thread so the live pane and the host path render identically.
    func ask(question: String,
             meetingID: String,
             transcript: String,
             notes: [String],
             bridge: UdhaBridge) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        bridge.beginAsk(for: meetingID)
        // Show the chip's label, not the paragraph of prompt behind it.
        bridge.appendAskTurn(MeetingAskTurn(role: .you, text: displayLabel(for: trimmed)))

        guard let client = ClaudeDirect() else {
            bridge.appendAskTurn(MeetingAskTurn(
                role: .udha,
                text: "Add an Anthropic API key in Settings to ask about a call recorded on this device."
            ))
            return
        }
        guard !transcript.isEmpty else {
            bridge.appendAskTurn(MeetingAskTurn(role: .udha, text: "Nothing has been transcribed yet."))
            return
        }

        bridge.setAskPending(true)
        let user = """
        ## Transcript so far
        \(transcript)

        ## My notes so far
        \(notes.isEmpty ? "(none)" : notes.map { "- \($0)" }.joined(separator: "\n"))

        ## My question
        \(trimmed)
        """
        do {
            let answer = try await client.text(
                system: PhoneMeetingPrompts.askSystem,
                user: user,
                model: ClaudeDirect.liveModel,
                maxTokens: 700
            )
            bridge.setAskPending(false)
            bridge.appendAskTurn(MeetingAskTurn(role: .udha, text: answer))
        } catch {
            log.error("live ask failed: \(error.localizedDescription)")
            bridge.setAskPending(false)
            bridge.appendAskTurn(MeetingAskTurn(
                role: .udha,
                text: error.localizedDescription
            ))
        }
    }

    private func displayLabel(for question: String) -> String {
        question == PhoneMeetingPrompts.soundSmartQuestion ? "Make me sound smart" : question
    }
}
