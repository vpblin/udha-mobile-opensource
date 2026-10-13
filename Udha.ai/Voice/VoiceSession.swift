import Foundation
import Combine
import Observation
import os

/// The voice half of the bridge: ElevenLabs ConvAI socket, mic capture, speaker
/// playback, push-to-talk and the transcript.
///
/// Split out of the old `MobileBridgeClient` so the fleet/protocol layer no
/// longer carries an audio pipeline. Behaviour is deliberately unchanged — in
/// particular the trailing-silence flush below is load-bearing and empirically
/// derived; see `flushEndOfUtteranceSilence()`.
@MainActor
@Observable
final class VoiceSession {

    enum State: Equatable {
        case idle          // the Mac has the agent, or nobody does
        case claiming      // claim sent, waiting on the host
        case active        // this device owns the floor; ConvAI open
        case releasing
    }

    /// How the user talks to the agent. Switchable mid-claim — both modes share
    /// one ConvAI socket and the same agent state.
    enum InputMode: String, Equatable, CaseIterable, Identifiable {
        case voice   // push-to-talk mic + speaker
        case text    // typed; agent audio still plays

        var id: String { rawValue }
        var title: String { self == .voice ? "Voice" : "Text" }
        var systemImage: String { self == .voice ? "mic.fill" : "keyboard" }
    }

    struct Message: Identifiable, Equatable {
        enum Role: String { case user, agent }
        let id = UUID()
        let role: Role
        let text: String
        let at: Date

        static func == (lhs: Message, rhs: Message) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - State

    private(set) var state: State = .idle {
        didSet {
            // Leaving .active for any reason must drop PTT, or the UI shows
            // "speaking" stuck on against a dead socket.
            if state != .active && pttHeld { pttHeld = false }
        }
    }
    private(set) var messages: [Message] = []
    private(set) var lastError: String?

    var inputMode: InputMode = .voice {
        didSet {
            guard oldValue == .voice, inputMode != .voice else { return }
            // Switching away mid-transmit would leave the mic hot.
            mic.endTransmitting()
            if pttHeld { pttHeld = false }
            // Silence anything already queued so the speaker cuts immediately.
            speaker.clearQueue()
        }
    }

    /// Push-to-talk gate, set by the UI while the button is held.
    var pttHeld: Bool = false {
        didSet { handlePTTChange() }
    }

    // MARK: - Callbacks to the bridge

    var onToolCall: ((_ callID: String, _ name: String, _ parameters: [String: Any]) -> Void)?
    var onEnded: (() -> Void)?

    // MARK: - Components

    let mic = MicCapture()
    let speaker = SpeakerPlayback()
    private let convai = ConvAIClient()
    private var micStarted = false
    private var silenceFlushTask: Task<Void, Never>?
    private var claimTimeout: Task<Void, Never>?
    private var convaiStateObserver: AnyCancellable?
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "voice")

    init() {
        convai.onAgentAudio = { [weak self] pcm in
            guard let self else { return }
            // Text mode means the user wants quiet. ConvAI still streams audio
            // (small bandwidth cost) but the speaker stays silent.
            guard self.inputMode == .voice else { return }
            self.speaker.enqueuePCM16(pcm)
        }
        convai.onInterruption = { [weak self] in self?.speaker.clearQueue() }
        convai.onToolCall = { [weak self] id, name, params in
            self?.onToolCall?(id, name, params)
        }
        convai.onAgentText = { [weak self] text in self?.append(.agent, text) }
        convai.onUserTranscript = { [weak self] text in self?.append(.user, text) }
    }

    // MARK: - Claim / release

    func beginClaim() {
        guard state == .idle else { return }
        state = .claiming
        lastError = nil
        // Without this the UI can sit on "Claiming…" forever if the host is wedged.
        claimTimeout?.cancel()
        claimTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.state == .claiming else { return }
            self.lastError = "Host didn't respond — try again"
            self.state = .idle
        }
    }

    func handleClaimResponse(_ result: Result<VoiceClaimGrant, BridgeError>) {
        claimTimeout?.cancel()
        claimTimeout = nil

        switch result {
        case .failure(let error):
            lastError = error.message
            state = .idle

        case .success(let grant):
            // Configure the shared audio session ONCE. .playAndRecord/.voiceChat
            // serves both mic and speaker; after this neither MicCapture nor
            // SpeakerPlayback touches the category, so there's no category-switch
            // race to break the playback engine mid-session.
            do {
                try SpeakerPlayback.setupSharedAudioSession()
            } catch {
                log.error("shared audio session setup failed: \(error.localizedDescription)")
                lastError = "Audio session: \(error.localizedDescription)"
            }
            do {
                try speaker.start()
            } catch {
                lastError = "Speaker: \(error.localizedDescription)"
            }
            convai.connect(signedURL: grant.signedURL, context: grant.context, voiceID: grant.voiceID)
            state = .active
            micStarted = false
            watchConvAIFailures()
        }
    }

    func release() {
        guard state == .active else { return }
        state = .releasing
        teardown()
        messages.removeAll()
        state = .idle
    }

    /// Hard stop — used on disconnect, host-offline and error paths.
    func teardown() {
        silenceFlushTask?.cancel()
        silenceFlushTask = nil
        claimTimeout?.cancel()
        claimTimeout = nil
        convaiStateObserver?.cancel()
        convaiStateObserver = nil
        convai.disconnect()
        mic.stop()
        speaker.stop()
        micStarted = false
        if state != .idle { state = .idle }
    }

    /// Surface ConvAI handshake failures instead of sitting in `.active` with
    /// nothing happening.
    private func watchConvAIFailures() {
        convaiStateObserver = convai.$state.sink { [weak self] state in
            guard let self, case .failed(let message) = state, self.state == .active else { return }
            Task { @MainActor in
                self.lastError = "ConvAI: \(message)"
                self.teardown()
                self.onEnded?()
            }
        }
    }

    // MARK: - Text

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .active else { return }
        append(.user, trimmed)
        convai.sendText(trimmed)
    }

    func deliverToolResult(callID: String, result: String, isError: Bool) {
        convai.sendToolResult(id: callID, resultJSON: result, isError: isError)
    }

    private func append(_ role: Message.Role, _ text: String) {
        messages.append(Message(role: role, text: text, at: Date()))
        if messages.count > 200 {
            messages.removeFirst(messages.count - 200)
        }
    }

    // MARK: - Push to talk

    private func handlePTTChange() {
        guard state == .active, inputMode == .voice else { return }

        if pttHeld {
            silenceFlushTask?.cancel()
            silenceFlushTask = nil
            // Lazy mic start, so denying the mic permission doesn't kill
            // text-only sessions.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.micStarted {
                    do {
                        try await self.mic.start()
                        self.micStarted = true
                        self.mic.onAudioChunk = { [weak self] chunk in
                            self?.convai.sendAudioChunk(chunk)
                        }
                    } catch {
                        self.log.error("mic.start failed: \(error.localizedDescription)")
                        self.lastError = "Mic: \(error.localizedDescription)"
                        self.pttHeld = false
                        return
                    }
                }
                self.mic.beginTransmitting()
            }
        } else {
            mic.endTransmitting()
            flushEndOfUtteranceSilence()
        }
    }

    /// Send 30 × 100 ms PCM16 silence chunks (3 s) so ConvAI's server-side VAD
    /// detects end-of-turn.
    ///
    /// Do not "optimise" this away: simply ceasing to send chunks leaves the
    /// agent waiting indefinitely. Verified via `test-harness/iphone-audio-e2e.js`
    /// — 28 chunks of speech + 30 of silence is what makes the agent transcribe
    /// and respond.
    private func flushEndOfUtteranceSilence() {
        silenceFlushTask?.cancel()
        let silence = Data(count: 3200)  // 1600 frames × 2 bytes = 100 ms @ 16 kHz
        silenceFlushTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self, self.state == .active, !self.pttHeld else { return }
                self.convai.sendAudioChunk(silence)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
