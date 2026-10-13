import Foundation

/// Where a video is in the host's capture → transcribe → render → share
/// pipeline. Mirrors the desktop's `RecordingStage`; `unknown` is here so a
/// stage this build has never heard of shows as a video rather than vanishing.
enum VideoStage: String, Codable, Hashable, Sendable {
    case capturing
    case needsProcessing
    case transcribing
    case composing
    case ready
    case failed
    case unknown

    /// Lowercase on purpose — it reads as a state, not a heading, and matches
    /// the meta line it sits in.
    var label: String {
        switch self {
        case .capturing:       return "recording"
        case .needsProcessing: return "not rendered"
        case .transcribing:    return "transcribing"
        case .composing:       return "rendering"
        case .ready:           return "ready"
        case .failed:          return "failed"
        case .unknown:         return "unknown"
        }
    }
}

/// One video recorded on the host.
///
/// The bytes stay on the Mac — a master is gigabytes and the relay carries
/// JSON — so this is metadata plus, once published, a link anyone can open.
/// That is what the phone can honestly offer: see the library, fix a title,
/// throw one away. Recording, joining and rendering stay where the camera and
/// the encoder are.
struct VideoItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    /// Active capture seconds, pauses excised — the host's own number.
    var durationSeconds: TimeInterval
    var stage: VideoStage
    /// Why the pipeline gave up, when it did.
    var failureReason: String?

    var hasCamera: Bool
    var hasMic: Bool
    var hasSystemAudio: Bool

    /// Which masters exist on the Mac: "landscape", "portrait".
    var orientations: [String]

    /// The public page, once published. Nil means it has never left the Mac.
    var shareURL: URL?
    var isPasswordProtected: Bool
    var publishedAt: Date?

    /// The host is capturing or rendering this one right now. Renaming is
    /// still fine; deleting is not, and the host refuses it either way.
    var busy: Bool

    var isPublished: Bool { shareURL != nil }

    /// "Aug 21 · 03:12 · ready · shared" — the row's second line.
    var listMeta: String {
        var parts = [VideoItem.dayFormatter.string(from: createdAt)]
        if durationSeconds > 0 { parts.append(VideoItem.clock(durationSeconds)) }
        parts.append(stage.label)
        if isPublished { parts.append("shared") }
        return parts.joined(separator: " · ")
    }

    /// "Aug 21, 2026 · 3:04 PM · 03:12" — the detail header.
    var detailStamp: String {
        var parts = [VideoItem.stampFormatter.string(from: createdAt)]
        if durationSeconds > 0 { parts.append(VideoItem.clock(durationSeconds)) }
        return parts.joined(separator: " · ")
    }

    /// What was captured, as words rather than three silent icons.
    var sourcesLabel: String {
        var parts: [String] = []
        if hasCamera { parts.append("camera") }
        if hasMic { parts.append("mic") }
        if hasSystemAudio { parts.append("system audio") }
        return parts.isEmpty ? "screen only" : parts.joined(separator: " · ")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
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

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, durationSec, stage, failureReason
        case hasCamera, hasMic, hasSystemAudio, orientations
        case shareURL, isPasswordProtected, publishedAt, busy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        // Epoch seconds, as everywhere else on this wire — a date-string
        // mismatch blanks a whole list in silence.
        createdAt = Date(timeIntervalSince1970: (try? c.decode(Double.self, forKey: .createdAt)) ?? 0)
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSec)) ?? 0
        stage = (try? c.decode(VideoStage.self, forKey: .stage)) ?? .unknown
        failureReason = try? c.decode(String.self, forKey: .failureReason)
        hasCamera = (try? c.decode(Bool.self, forKey: .hasCamera)) ?? false
        hasMic = (try? c.decode(Bool.self, forKey: .hasMic)) ?? false
        hasSystemAudio = (try? c.decode(Bool.self, forKey: .hasSystemAudio)) ?? false
        orientations = (try? c.decode([String].self, forKey: .orientations)) ?? []
        shareURL = (try? c.decode(String.self, forKey: .shareURL)).flatMap(URL.init(string:))
        isPasswordProtected = (try? c.decode(Bool.self, forKey: .isPasswordProtected)) ?? false
        if let published = try? c.decode(Double.self, forKey: .publishedAt) {
            publishedAt = Date(timeIntervalSince1970: published)
        } else {
            publishedAt = nil
        }
        busy = (try? c.decode(Bool.self, forKey: .busy)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try c.encode(durationSeconds, forKey: .durationSec)
        try c.encode(stage.rawValue, forKey: .stage)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)
        try c.encode(hasCamera, forKey: .hasCamera)
        try c.encode(hasMic, forKey: .hasMic)
        try c.encode(hasSystemAudio, forKey: .hasSystemAudio)
        try c.encode(orientations, forKey: .orientations)
        try c.encodeIfPresent(shareURL?.absoluteString, forKey: .shareURL)
        try c.encode(isPasswordProtected, forKey: .isPasswordProtected)
        try c.encodeIfPresent(publishedAt?.timeIntervalSince1970, forKey: .publishedAt)
        try c.encode(busy, forKey: .busy)
    }

    init(id: String, title: String, createdAt: Date, durationSeconds: TimeInterval,
         stage: VideoStage, failureReason: String? = nil,
         hasCamera: Bool = false, hasMic: Bool = false, hasSystemAudio: Bool = false,
         orientations: [String] = [], shareURL: URL? = nil,
         isPasswordProtected: Bool = false, publishedAt: Date? = nil, busy: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.stage = stage
        self.failureReason = failureReason
        self.hasCamera = hasCamera
        self.hasMic = hasMic
        self.hasSystemAudio = hasSystemAudio
        self.orientations = orientations
        self.shareURL = shareURL
        self.isPasswordProtected = isPasswordProtected
        self.publishedAt = publishedAt
        self.busy = busy
    }
}

/// A library belongs to a capable host, independently of the selected terminal.
enum VideoLibraryRouting {
    static func hostID(preferred: String?, current: String?, active: String?, capable: [String]) -> String? {
        for id in [preferred, current, active].compactMap({ $0 }) where capable.contains(id) { return id }
        return capable.first
    }
}
