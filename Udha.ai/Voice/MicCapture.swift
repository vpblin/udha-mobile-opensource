import Foundation
@preconcurrency import AVFoundation
import os

/// iPhone mic → PCM16 16kHz mono chunks, gated by push-to-talk.
///
/// Mirrors the desktop's AudioCapture format so ElevenLabs ConvAI sees the
/// same input regardless of endpoint. The tap is installed once on start(),
/// and a `isTransmitting` gate decides whether chunks are emitted — holding
/// PTT flips the gate on, releasing flips it off. No taps install / uninstall
/// per PTT press, which would race with AVAudioEngine.
@MainActor
final class MicCapture {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var tapInstalled: Bool = false
    nonisolated(unsafe) private var converter: AVAudioConverter?

    /// Called on every PCM16 chunk (whenever transmitting). The caller is
    /// responsible for base64-encoding + framing + sending to ConvAI.
    var onAudioChunk: ((Data) -> Void)?

    /// Set to true to emit chunks; false drops them at the tap boundary.
    private(set) var isTransmitting: Bool = false

    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "mic")
    private var chunkCount: Int = 0

    init(sampleRate: Double = 16000) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    static func requestPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        let status = session.recordPermission
        switch status {
        case .granted: return true
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { granted in cont.resume(returning: granted) }
            }
        default:
            return false
        }
    }

    func start() async throws {
        log.info("start() called, tapInstalled=\(self.tapInstalled)")
        guard !tapInstalled else {
            log.info("start() noop — tap already installed")
            return
        }
        let granted = await Self.requestPermission()
        log.info("mic permission granted=\(granted)")
        guard granted else {
            throw NSError(domain: "MicCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        // Session is configured ONCE by MobileBridgeClient (via
        // SpeakerPlayback.setupSharedAudioSession) at claim time as
        // .playAndRecord/.voiceChat, which is a strict superset of what mic
        // needs. We deliberately don't change category here — doing so would
        // tear down the speaker engine.
        let session = AVAudioSession.sharedInstance()
        let routeIn = session.currentRoute.inputs.map { $0.portName }.joined(separator: ",")
        let routeOut = session.currentRoute.outputs.map { $0.portName }.joined(separator: ",")
        log.info("audio session (already set): cat=\(session.category.rawValue), inputs=[\(routeIn)] outputs=[\(routeOut)]")

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        log.info("input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, common=\(inputFormat.commonFormat.rawValue)")

        if inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            log.info("created AVAudioConverter \(inputFormat.sampleRate) Hz → \(self.targetFormat.sampleRate) Hz")
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isTransmitting, let cb = self.onAudioChunk else { return }
                let data = self.encodeToPCM16(buffer: buffer)
                if !data.isEmpty {
                    self.chunkCount += 1
                    if self.chunkCount % 50 == 1 {
                        // Sample the first few hundred frames to see if there
                        // is actual signal. Silence = max abs ~0; speech is
                        // typically thousands. If always ~0, mic is muted /
                        // wrong route / wrong category.
                        let maxAbs = data.withUnsafeBytes { raw -> Int in
                            let int16s = raw.bindMemory(to: Int16.self)
                            var m: Int = 0
                            for v in int16s { let a = Int(abs(Int32(v))); if a > m { m = a } }
                            return m
                        }
                        self.log.info("chunk #\(self.chunkCount) bytes=\(data.count) maxAbs=\(maxAbs)")
                    }
                    cb(data)
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        log.info("mic engine started, tap installed")
    }

    func stop() {
        log.info("stop() called, tapInstalled=\(self.tapInstalled), totalChunks=\(self.chunkCount)")
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        isTransmitting = false
        chunkCount = 0
        // Release the audio session so other audio apps can resume normally.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func beginTransmitting() {
        log.info("beginTransmitting()")
        isTransmitting = true
    }

    func endTransmitting() {
        log.info("endTransmitting() — sent \(self.chunkCount) chunks")
        isTransmitting = false
    }

    nonisolated private func encodeToPCM16(buffer: AVAudioPCMBuffer) -> Data {
        if buffer.format.commonFormat == .pcmFormatInt16 && buffer.format.sampleRate == targetFormat.sampleRate {
            let frames = Int(buffer.frameLength)
            guard frames > 0, let src = buffer.int16ChannelData?[0] else { return Data() }
            return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
        }
        guard let converter else { return Data() }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return Data() }
        var done = false
        var error: NSError?
        _ = converter.convert(to: outBuffer, error: &error) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return Data() }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let src = outBuffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: src, count: frames * MemoryLayout<Int16>.size)
    }
}
