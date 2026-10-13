import Foundation
import AVFoundation
import Speech
import Observation
import os

/// Records a meeting on this device: mic audio in, transcript segments out.
///
/// **Why `SpeechAnalyzer`, not `SFSpeechRecognizer`.** The old recogniser is
/// built for dictation: a recognition request dies after about a minute, so a
/// meeting had to be transcribed as a chain of restarted requests. That chain
/// was the feature's central defect — cancelling a task fires its own callback
/// with an error, the error handler restarted, and the restart cancelled again,
/// so a recording spent its life tearing the audio engine down and building it
/// back up. `SpeechAnalyzer` is built for long-form audio: one analyzer, one
/// input stream, results as an async sequence, for the whole call. There is no
/// session to recycle, so there is no restart loop to get wrong.
///
/// **Why the audio file is written unconditionally.** Speech recognition is the
/// part most likely to fail — a missing model, an unsupported locale, a device
/// under memory pressure. Audio capture is not. Writing `audio.m4a` from the
/// same tap means a failed transcription is a retry (`retranscribe`) rather
/// than a lost meeting, which is the difference between an annoyance and the
/// worst outcome this feature has.
///
/// **What it cannot do.** iOS gives an app no access to system audio, so this
/// is one mic stream. There is no `Me` / `Them` separation — every segment is
/// attributed to `Me`, and the UI labels the recording "mic only" rather than
/// implying the desktop's diarized two-stream capture.
@MainActor
@Observable
final class LocalMeetingRecorder {

    enum State: Equatable {
        case idle
        /// Carries what is being waited on — model download in particular can
        /// take a while on first run, and "unavailable" was a lie.
        case preparing(String)
        case recording
        case finishing
        case denied(String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .recording, .preparing: return true
            default: return false
            }
        }

        var preparingMessage: String? {
            if case .preparing(let message) = self { return message }
            return nil
        }
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var segments: [TranscriptSegment] = []
    /// The text currently being recognised, not yet committed to a segment.
    private(set) var partial: String = ""
    /// Recent audio levels, 0…1, for the waveform meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: 40)
    private(set) var meetingID: String = UUID().uuidString
    private(set) var startedAt: Date = Date()
    /// True while an interruption (a phone call, Siri) has the audio session.
    /// The clock stops, so meeting time stays equal to recorded time.
    private(set) var interrupted = false
    /// Free-text notes typed during the call.
    var notes: [String] = []

    private let store: MeetingStore
    private let liveActivity = MeetingActivityController()
    private let engine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var pipe: AudioPipe?
    private var resultsTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    /// Meeting-time seconds at which the current utterance began, used when a
    /// result carries no usable audio range of its own.
    private var utteranceStart: TimeInterval = 0
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "recorder")

    init(store: MeetingStore) {
        self.store = store
        // A crash mid-recording leaves an activity behind that claims to still
        // be recording; nothing else would ever clean it up.
        liveActivity.clearStaleActivities()
    }

    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Everything said so far, for the live Ask context.
    var liveTranscriptText: String {
        var lines = segments.map { "[\($0.stamp)] \($0.speaker): \($0.text)" }
        let tail = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lines.append("[now] Me: \(tail)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Permissions

    /// Only the microphone. `SpeechAnalyzer` runs on-device and does not go
    /// through `SFSpeechRecognizer` authorization, so asking for it would be a
    /// second permission prompt that gates nothing.
    static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !state.isActive else { return }
        state = .preparing("starting")
        segments = []
        partial = ""
        notes = []
        elapsed = 0
        utteranceStart = 0
        interrupted = false
        levels = Array(repeating: 0, count: 40)
        meetingID = UUID().uuidString
        startedAt = Date()

        guard await Self.requestMicrophonePermission() else {
            state = .denied("Microphone access is required to record a meeting.")
            return
        }

        do {
            let locale = await Self.bestLocale()
            guard let locale else {
                state = .failed("No speech model is available for \(Locale.current.identifier).")
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                // Volatile results are what makes the live pane feel alive;
                // the finalized ones are what become segments.
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            self.transcriber = transcriber

            try await ensureModel(for: transcriber)
            guard state.isActive else { return }   // cancelled while downloading

            state = .preparing("starting")
            try await startCapture(transcriber: transcriber)
        } catch {
            log.error("recorder start failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            teardown()
            return
        }

        observeInterruptions()
        state = .recording
        startTicking()
        // Proof, on the Lock Screen, that this is still running once the phone
        // goes back in a pocket — and the way back into the live screen.
        liveActivity.start(title: "Recording a meeting", elapsed: elapsed)
    }

    /// Stops and returns the finished meeting, persisted to disk before it
    /// returns. Nil only when nothing at all was captured.
    func stop() async -> Meeting? {
        // Deliberately not gated on `.isActive`: a recorder that failed
        // mid-call still holds real segments and a real audio file, and
        // throwing those away was how a bad minute became a lost meeting.
        guard state != .idle, state != .finishing else { return nil }
        state = .finishing

        liveActivity.end(elapsed: elapsed)

        // Let the analyzer drain what it is holding before the stack comes
        // down — the last sentence of every meeting lives in there.
        await finishAnalysis()
        teardown()

        let ended = Date()
        state = .idle

        let typed = notes.joined(separator: "\n")
        let hasAudio = store.audioURL(for: meetingID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard !segments.isEmpty || !typed.isEmpty || hasAudio else { return nil }

        var meeting = Meeting(
            id: meetingID,
            title: Self.provisionalTitle(from: segments, at: startedAt),
            createdAt: startedAt,
            endedAt: ended,
            mode: .standard,
            origin: .local,
            hasAudio: hasAudio,
            // Nothing has summarised it yet — the row says so until a notes
            // pass, here or on the Mac, comes back.
            finalized: false,
            summary: nil,
            decisions: nil,
            actionItems: nil,
            transcript: segments,
            userNotes: typed.isEmpty ? nil : typed,
            syncState: .queued
        )

        // Disk first, always, and before anything touches the network: a
        // meeting that exists only in memory is one crash from gone.
        do {
            try store.save(meeting)
        } catch {
            log.error("failed to persist meeting: \(error.localizedDescription)")
            meeting.syncState = .localOnly
        }
        return meeting
    }

    func cancel() {
        resultsTask?.cancel()
        liveActivity.end(elapsed: elapsed)
        teardown()
        state = .idle
        segments = []
        partial = ""
        elapsed = 0
        store.deleteFolder(for: meetingID)
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(trimmed)
    }

    // MARK: - Model

    /// The user's own locale where the transcriber supports it, English as the
    /// fallback. Hardcoding en-US meant everyone else got nonsense.
    private static func bestLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first { $0.identifier(.bcp47).hasPrefix("en") } ?? supported.first
    }

    private func ensureModel(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        state = .preparing("downloading speech model")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        // Keeping the locale reserved stops the system reclaiming the model
        // between calls, which would put the download in front of a meeting
        // the user is trying to start right now.
        _ = try? await AssetInventory.reserve(locale: transcriber.selectedLocales.first ?? Locale.current)
    }

    // MARK: - Capture

    private func startCapture(transcriber: SpeechTranscriber) async throws {
        try configureSession()

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pipe = try AudioPipe(
            inputFormat: inputFormat,
            analyzerFormat: analyzerFormat,
            audioURL: store.prepareAudioURL(for: meetingID),
            continuation: continuation
        )
        self.pipe = pipe

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Read results before the audio starts flowing, so nothing said in the
        // first moments is dropped on the floor.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let range = result.range
                    let isFinal = result.isFinal
                    await MainActor.run {
                        self?.handle(text: text, range: range, isFinal: isFinal)
                    }
                }
            } catch {
                await MainActor.run { self?.handleRecognitionFailure(error) }
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            pipe.accept(buffer, at: time)
            guard let self else { return }
            let level = AudioPipe.rms(buffer)
            Task { @MainActor in self.pushLevel(level) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement keeps iOS from applying the voice-processing AGC that
        // makes far-field meeting audio unintelligible.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Drains the analyzer and waits, briefly, for the tail of the transcript.
    private func finishAnalysis() async {
        pipe?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // The results sequence ends on its own once the analyzer finishes; a
        // ceiling keeps a wedged analyzer from hanging the Stop button.
        if let resultsTask {
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await resultsTask.value }
                group.addTask { try? await Task.sleep(nanoseconds: 2_500_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        commitPartial()
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        resultsTask?.cancel()
        resultsTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        // Unconditionally, not `if engine.isRunning`: a failed start leaves the
        // tap installed on a stopped engine, and the next `installTap` on a bus
        // that already has one is an uncatchable crash.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        pipe?.close()
        pipe = nil
        analyzer = nil
        transcriber = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Interruptions

    /// A phone call, Siri, or another app taking the session. The recording
    /// pauses rather than dying, and resumes itself when the session comes
    /// back — the elapsed clock stops meanwhile, so transcript timestamps stay
    /// aligned with the audio that was actually captured.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    self.pauseForInterruption()
                case .ended:
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if options.contains(.shouldResume) { self.resumeAfterInterruption() }
                @unknown default:
                    break
                }
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state = .failed("Audio services restarted. The recording so far was saved.")
            }
        })
    }

    private func pauseForInterruption() {
        guard state == .recording else { return }
        interrupted = true
        if engine.isRunning { engine.pause() }
        commitPartial()
        liveActivity.update(elapsed: elapsed, paused: true, lastLine: lastLine, force: true)
    }

    private func resumeAfterInterruption() {
        guard interrupted else { return }
        do {
            try configureSession()
            try engine.start()
            interrupted = false
            liveActivity.update(elapsed: elapsed, paused: false, lastLine: lastLine, force: true)
        } catch {
            log.error("resume after interruption failed: \(error.localizedDescription)")
            state = .failed("Recording stopped when the call was interrupted. What was captured is saved.")
        }
    }

    /// A route change (AirPods in or out) invalidates the tap's format. Rather
    /// than let the engine throw on the next buffer, pause and rebuild the tap
    /// against the new hardware format.
    private func handleRouteChange() {
        guard state == .recording, !interrupted else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard let pipe, !pipe.matches(inputFormat: current), current.sampleRate > 0 else { return }
        log.info("input route changed; rebuilding tap at \(current.sampleRate)Hz")
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        do {
            try pipe.retune(to: current)
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: current) { [weak self] buffer, time in
                pipe.accept(buffer, at: time)
                guard let self else { return }
                let level = AudioPipe.rms(buffer)
                Task { @MainActor in self.pushLevel(level) }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            log.error("tap rebuild failed: \(error.localizedDescription)")
            state = .failed("The audio route changed and recording could not continue. What was captured is saved.")
        }
    }

    // MARK: - Transcript

    private func handle(text: String, range: CMTimeRange, isFinal: Bool) {
        guard state == .recording || state == .finishing else { return }
        if isFinal {
            let start = range.start.isNumeric ? range.start.seconds : utteranceStart
            let end = range.end.isNumeric ? range.end.seconds : elapsed
            partial = ""
            append(text: text, start: start, end: end)
        } else {
            partial = text
        }
    }

    /// The analyzer stopping is not the recording stopping. Whatever has been
    /// transcribed stays, the audio file keeps the rest, and the meeting is
    /// still saveable — `retranscribe` can recover the remainder later.
    private func handleRecognitionFailure(_ error: Error) {
        guard state == .recording else { return }
        log.error("transcription ended early: \(error.localizedDescription)")
        commitPartial()
        state = .failed("Transcription stopped early. The audio was saved — you can re-transcribe it.")
    }

    private func commitPartial() {
        let text = partial
        partial = ""
        append(text: text, start: utteranceStart, end: elapsed)
    }

    private func append(text: String, start: TimeInterval, end: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(TranscriptSegment(
            source: .mic,
            speaker: "Me",
            text: trimmed,
            startTime: max(0, start),
            endTime: max(start, end)
        ))
        utteranceStart = max(utteranceStart, end)
        liveActivity.update(elapsed: elapsed, paused: false, lastLine: trimmed)
    }

    /// The most recent thing heard, for the Lock Screen line.
    private var lastLine: String { segments.last?.text ?? "" }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                guard self.state == .recording, !self.interrupted else { continue }
                self.elapsed += 0.5
            }
        }
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(min(1, level * 6))
    }

    /// A readable placeholder until a notes pass names it properly.
    private static func provisionalTitle(from segments: [TranscriptSegment], at date: Date) -> String {
        if let first = segments.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            let words = first.split(separator: " ").prefix(7).joined(separator: " ")
            if words.count > 3 { return words }
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d 'recording' h:mm a"
        return f.string(from: date)
    }

    enum RecorderError: LocalizedError {
        case noInput
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .noInput:       return "No audio input is available on this device."
            case .noAudioFormat: return "This device's microphone format is not supported."
            }
        }
    }
}

// MARK: - Audio pipe

/// Fans one tap out to the two consumers that matter: the file on disk and the
/// analyzer's input stream.
///
/// Lives off the main actor because it is driven from the realtime audio
/// thread. Everything it touches is confined to that thread — the tap callback
/// is serial — so it is `@unchecked Sendable` by construction rather than by
/// hope.
private final class AudioPipe: @unchecked Sendable {
    private var inputFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var finished = false
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "audiopipe")

    init(inputFormat: AVAudioFormat,
         analyzerFormat: AVAudioFormat?,
         audioURL: URL?,
         continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.inputFormat = inputFormat
        self.analyzerFormat = analyzerFormat
        self.continuation = continuation
        if let analyzerFormat, analyzerFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
        if let audioURL {
            // Compressed, because an hour of float PCM is a gigabyte and this
            // file is kept indefinitely.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            audioFile = try AVAudioFile(forWriting: audioURL, settings: settings)
        }
    }

    func matches(inputFormat other: AVAudioFormat) -> Bool {
        other.sampleRate == inputFormat.sampleRate && other.channelCount == inputFormat.channelCount
    }

    /// Rebuilds the converter for a new hardware format after a route change.
    /// The file keeps its original format — `AVAudioFile` cannot change one
    /// mid-write — so buffers are converted back to it instead.
    func retune(to newFormat: AVAudioFormat) throws {
        inputFormat = newFormat
        if let analyzerFormat, analyzerFormat != newFormat {
            converter = AVAudioConverter(from: newFormat, to: analyzerFormat)
        } else {
            converter = nil
        }
    }

    func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard !finished else { return }
        write(buffer)
        guard let analyzerFormat else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        guard let converted = convert(buffer, with: converter, to: analyzerFormat) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    func close() {
        finish()
        audioFile = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile else { return }
        // A mismatch here means a route change slipped past `retune`. Dropping
        // the buffer costs a few milliseconds of audio; writing it throws.
        guard buffer.format.sampleRate == audioFile.processingFormat.sampleRate,
              buffer.format.channelCount == audioFile.processingFormat.channelCount else { return }
        do {
            try audioFile.write(from: buffer)
        } catch {
            log.error("audio write failed: \(error.localizedDescription)")
            self.audioFile = nil
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         with converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("analyzer conversion failed: \(error.localizedDescription)")
            return nil
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return (sum / Float(count)).squareRoot()
    }
}
