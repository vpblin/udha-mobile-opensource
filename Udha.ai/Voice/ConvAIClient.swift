import Foundation
import Combine
import os

/// Direct ElevenLabs ConvAI WebSocket client — mobile-side. Seeded with a
/// signed URL minted by the desktop (so the ElevenLabs API key never reaches
/// this device) and a context snapshot to keep continuity across handoffs.
///
/// Audio frames (mic in, agent out) flow over THIS socket. Tool calls from
/// the agent are bounced back to the desktop via a separate relay channel —
/// ConvAIClient surfaces them through `onToolCall` and expects the caller to
/// resolve via `sendToolResult`.
@MainActor
final class ConvAIClient: NSObject, ObservableObject {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastUserTranscript: String = ""
    @Published private(set) var lastAgentResponse: String = ""

    var onAgentAudio: ((Data) -> Void)?
    var onInterruption: (() -> Void)?
    /// Fires on ConvAI `client_tool_call`. Payload: (toolCallID, name, parameters).
    /// Caller must eventually call `sendToolResult` with the same id.
    var onToolCall: ((String, String, [String: Any]) -> Void)?
    /// Fires whenever the agent emits a text response (turn-end transcript).
    /// Used by the chat UI in text mode.
    var onAgentText: ((String) -> Void)?
    /// Fires when ConvAI's transcriber emits the user's spoken text. Used by
    /// the chat UI in voice mode so the bubble shows what was heard.
    var onUserTranscript: ((String) -> Void)?

    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "convai")

    private var task: URLSessionWebSocketTask?
    nonisolated(unsafe) private var session: URLSession!
    private var listenID: UInt64 = 0
    /// Buffered until the WS handshake completes (`didOpenWithProtocol`).
    private var pendingSends: [String] = []
    private var isOpen: Bool = false
    private var sendCount: Int = 0

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        // Set self as the WebSocket delegate so we know exactly when the
        // handshake actually opens — the alternative (assume open after
        // resume()) leads to "Socket is not connected" errors when sends or
        // receives race the handshake.
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// `signedURL` comes from the desktop's `voice_claim_response`. `context`
    /// is the desktop's ContextFeed snapshot — seeded into the agent via
    /// `conversation_initiation_client_data.dynamic_variables.current_context`
    /// so the iPhone session continues where the Mac session left off.
    func connect(signedURL: URL, context: String, voiceID: String?) {
        guard state == .disconnected || isFailed else { return }
        state = .connecting
        isOpen = false
        pendingSends.removeAll()

        log.info("connect: \(signedURL.absoluteString, privacy: .public)")

        let task = session.webSocketTask(with: signedURL)
        self.task = task
        task.resume()

        // Queue the initiation message — it'll flush when didOpenWithProtocol
        // fires. Trying to send before then races the handshake on iOS.
        //
        // NOTE: we deliberately do NOT send `conversation_config_override.tts.voice_id`
        // here even when the desktop hands us one. ElevenLabs closes the
        // socket with code 1008 ("Override for field 'voice_id' is not
        // allowed by config") unless the agent's Security tab has "Voice
        // override" enabled — and the user's agent currently doesn't.
        // The agent's configured default voice is used instead.
        _ = voiceID  // intentionally unused for now
        let payload: [String: Any] = [
            "type": "conversation_initiation_client_data",
            "dynamic_variables": [
                "current_context": context,
            ],
        ]
        enqueueOrSend(json: payload)
    }

    func disconnect() {
        listenID &+= 1
        isOpen = false
        pendingSends.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    // MARK: - Sending

    /// PCM16 16 kHz mono mic frame. Base64-encoded into the expected envelope.
    func sendAudioChunk(_ pcm: Data) {
        let b64 = pcm.base64EncodedString()
        enqueueOrSend(json: [
            "type": "user_audio_chunk",
            "user_audio_chunk": b64,
        ])
    }

    /// Send a typed text message — the agent treats it identically to a
    /// transcribed utterance, runs tools, and replies.
    func sendText(_ text: String) {
        enqueueOrSend(json: [
            "type": "user_message",
            "text": text,
        ])
    }

    /// Forward the desktop's tool result back to ConvAI so the agent can
    /// continue its turn.
    func sendToolResult(id: String, resultJSON: String, isError: Bool) {
        enqueueOrSend(json: [
            "type": "client_tool_result",
            "tool_call_id": id,
            "result": resultJSON,
            "is_error": isError,
        ])
    }

    // MARK: - Internals

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func enqueueOrSend(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              let str = String(data: data, encoding: .utf8) else { return }
        if isOpen, let task {
            sendCount += 1
            // Only log periodically + the first audio send so we can confirm
            // the byte size + structure ConvAI receives.
            let typeStr = (json["type"] as? String) ?? (json["user_audio_chunk"] != nil ? "user_audio_chunk(no-type)" : "?")
            if sendCount <= 3 || sendCount % 50 == 0 {
                log.info("WS send #\(self.sendCount) type=\(typeStr, privacy: .public) bytes=\(str.utf8.count)")
            }
            task.send(.string(str)) { [weak self] err in
                if let err {
                    Task { @MainActor in self?.log.error("send err: \(err.localizedDescription, privacy: .public)") }
                }
            }
        } else {
            pendingSends.append(str)
        }
    }

    private func flushPending() {
        guard isOpen, let task else { return }
        let toSend = pendingSends
        pendingSends.removeAll()
        for str in toSend {
            task.send(.string(str)) { [weak self] err in
                if let err {
                    Task { @MainActor in self?.log.error("flush err: \(err.localizedDescription, privacy: .public)") }
                }
            }
        }
    }

    private func listen(id: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while id == self.listenID, let task = self.task {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let t = String(data: data, encoding: .utf8) { self.handle(t) }
                    @unknown default: break
                    }
                } catch {
                    self.log.error("receive error: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private var audioChunksReceived: Int = 0
    private var vadCount: Int = 0

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        switch type {
        case "conversation_initiation_metadata":
            log.info("ConvAI: conversation_initiation_metadata received")

        case "ping":
            if let ping = json["ping_event"] as? [String: Any],
               let eventID = ping["event_id"] {
                enqueueOrSend(json: ["type": "pong", "event_id": eventID])
            }

        case "user_transcript":
            if let ev = json["user_transcription_event"] as? [String: Any],
               let t = ev["user_transcript"] as? String {
                log.info("ConvAI user_transcript: \(t, privacy: .public)")
                lastUserTranscript = t
                onUserTranscript?(t)
            }

        case "agent_response":
            if let ev = json["agent_response_event"] as? [String: Any],
               let r = ev["agent_response"] as? String {
                log.info("ConvAI agent_response: \(r, privacy: .public)")
                lastAgentResponse = r
                onAgentText?(r)
            }

        case "audio":
            if let ev = json["audio_event"] as? [String: Any],
               let b64 = ev["audio_base_64"] as? String,
               let pcm = Data(base64Encoded: b64) {
                audioChunksReceived += 1
                if audioChunksReceived % 20 == 1 {
                    log.info("ConvAI audio chunk #\(self.audioChunksReceived) (\(pcm.count) bytes)")
                }
                onAgentAudio?(pcm)
            }

        case "interruption":
            log.info("ConvAI interruption")
            onInterruption?()

        case "client_tool_call":
            guard let call = json["client_tool_call"] as? [String: Any],
                  let name = call["tool_name"] as? String,
                  let id = call["tool_call_id"] as? String else { return }
            let params = call["parameters"] as? [String: Any] ?? [:]
            log.info("ConvAI client_tool_call: \(name, privacy: .public) id=\(id, privacy: .public)")
            onToolCall?(id, name, params)

        case "vad_score":
            // Voice activity detection score — every ~100ms while connected.
            // We log every Nth so we can verify ConvAI is actually analyzing
            // our audio. If we NEVER see vad_score, ConvAI's pipeline isn't
            // receiving the chunks.
            if let ev = json["vad_score_event"] as? [String: Any],
               let score = ev["vad_score"] as? Double {
                audioChunksReceived += 0  // (just for the counter pattern below)
                vadCount += 1
                if vadCount <= 3 || vadCount % 30 == 0 {
                    log.info("ConvAI vad_score #\(self.vadCount): \(score)")
                }
            }

        case "internal_tentative_agent_response":
            break

        default:
            log.info("ConvAI unhandled msg type=\(type, privacy: .public)")
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ConvAIClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.task === webSocketTask else { return }
            self.log.info("WS open (proto=\(`protocol` ?? "(none)", privacy: .public))")
            self.isOpen = true
            self.state = .connected
            self.listenID &+= 1
            let id = self.listenID
            self.listen(id: id)
            self.flushPending()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(no reason)"
        let codeNum = closeCode.rawValue
        Task { @MainActor [weak self] in
            guard let self, self.task === webSocketTask else { return }
            self.log.error("WS closed code=\(codeNum) reason=\(reasonStr, privacy: .public)")
            self.isOpen = false
            // Map common close codes to user-facing messages.
            let detail: String
            switch codeNum {
            case 1000: detail = "closed normally"
            case 1006: detail = "connection lost (1006)"
            case 1008: detail = "policy violation (1008) — \(reasonStr)"
            case 1011: detail = "server error (1011) — \(reasonStr)"
            case 4001...4999: detail = "ElevenLabs rejected (\(codeNum)): \(reasonStr)"
            default: detail = "closed (\(codeNum)) \(reasonStr)"
            }
            self.state = .failed(detail)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // didCompleteWithError fires for ALL tasks; only react if the WS
            // task completed (e.g., handshake failed before didOpen).
            if let wsTask = self.task, wsTask === task {
                self.log.error("WS task error: \(error.localizedDescription, privacy: .public)")
                if !self.isFailed {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
