import Foundation
@preconcurrency import AVFoundation
import os

/// Queues base64-PCM16-16k-mono chunks arriving from ElevenLabs ConvAI and
/// plays them back-to-back on AVAudioEngine. Designed to match the desktop's
/// AudioPlayer behaviour so the handoff feels identical regardless of
/// endpoint.
@MainActor
final class SpeakerPlayback {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat
    private let sampleRate: Int
    private var graphConnected: Bool = false
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "speaker")
    private var enqueueCount: Int = 0

    init(sampleRate: Int = 16000) {
        self.sampleRate = sampleRate
        self.sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        )!
        // Engine nodes are NOT wired up here. iOS's AVAudioEngine queries the
        // hardware on first node access (outputNode / mainMixerNode), and that
        // query requires a configured + activated audio session. Wiring nodes
        // before configuring the session leaves the session in a state where
        // setCategory fails with OSStatus -50. Defer until `start()`.
    }

    func start() throws {
        if engine.isRunning {
            return
        }
        log.info("start() called (first=\(!self.graphConnected))")
        // Audio session is now configured ONCE by MobileBridgeClient at claim
        // time (using .playAndRecord/.voiceChat which supports both mic AND
        // speaker). We don't touch the session here — switching it back to
        // .playback would fail with OSStatus 561017449 ('!cat') while mic
        // is using .playAndRecord, AND would tear down the mic engine.
        if !graphConnected {
            let hwFormat = engine.outputNode.outputFormat(forBus: 0)
            log.info("hardware output format = \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: sourceFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hwFormat)
            graphConnected = true
            log.info("audio graph connected")
        }
        engine.prepare()
        do {
            try engine.start()
            log.info("engine.start() ok")
        } catch let err as NSError {
            log.error("engine.start() FAILED: osStatus=\(err.code) \(err.localizedDescription)")
            throw err
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Called by MobileBridgeClient at claim time. Sets the audio session to
    /// a category compatible with both speaker output AND optional mic input
    /// (so the same session can be used by SpeakerPlayback and MicCapture
    /// without ever switching categories).
    static func setupSharedAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord with .voiceChat:
        //   - Allows simultaneous output AND input (no category switch needed)
        //   - .voiceChat applies AGC + echo cancellation (essential for VoIP)
        //   - .defaultToSpeaker forces output to loudspeaker (vs earpiece)
        //   - Bluetooth options enable AirPods playback + recording
        try session.setCategory(.playAndRecord,
                                 mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        // Don't deactivate the session here — MicCapture.stop also deactivates
        // and we'd race. The bridge tears both down on release; one of them
        // wins the deactivate call, which is fine.
    }

    /// Interrupt playback — drop everything pending and reset scheduling.
    func clearQueue() {
        playerNode.stop()
        if engine.isRunning {
            playerNode.play()
        }
    }

    /// `pcm` is raw PCM16 mono at `sampleRate`. ElevenLabs ConvAI chunks are
    /// typically 20–50ms each; we schedule them back-to-back.
    func enqueuePCM16(_ pcm: Data) {
        do { try start() } catch {
            log.error("start() failed in enqueue: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard engine.isRunning else {
            log.error("enqueue but engine not running")
            return
        }

        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            log.error("failed to alloc PCM buffer for \(frameCount) frames")
            return
        }
        buffer.frameLength = frameCount

        pcm.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.int16ChannelData?[0] else { return }
            memcpy(dst, src, Int(frameCount) * MemoryLayout<Int16>.size)
        }

        enqueueCount += 1
        if enqueueCount <= 3 || enqueueCount % 30 == 0 {
            // Sample first few PCM values to confirm we're not getting silence
            let maxAbs = pcm.withUnsafeBytes { raw -> Int in
                let int16s = raw.bindMemory(to: Int16.self)
                var m: Int = 0
                for v in int16s { let a = Int(abs(Int32(v))); if a > m { m = a } }
                return m
            }
            log.info("enqueue #\(self.enqueueCount): \(frameCount) frames, maxAbs=\(maxAbs), playerNode.isPlaying=\(self.playerNode.isPlaying), engine.isRunning=\(self.engine.isRunning)")
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
    }

    private func configureSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        // Hint iOS that we want 16 kHz hardware so the engine doesn't
        // resample unnecessarily and so AURemoteIO initializes at a real rate.
        try? session.setPreferredSampleRate(Double(sampleRate))

        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playback, .spokenAudio, []),
            (.playback, .default, []),
            (.playAndRecord, .voiceChat, [.defaultToSpeaker]),
        ]
        var lastError: NSError?
        for (cat, mode, opts) in attempts {
            do {
                try session.setCategory(cat, mode: mode, options: opts)
                try session.setActive(true, options: [])
                let outRoute = session.currentRoute.outputs.map { $0.portName }.joined(separator: ",")
                log.info("session OK category=\(cat.rawValue, privacy: .public) mode=\(mode.rawValue, privacy: .public) hwSR=\(session.sampleRate) outVol=\(session.outputVolume) outRoute=[\(outRoute, privacy: .public)]")
                return
            } catch let error as NSError {
                log.error("session FAILED cat=\(cat.rawValue, privacy: .public) mode=\(mode.rawValue, privacy: .public) → osStatus=\(error.code) \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "SpeakerPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not configure audio session"])
    }
}
