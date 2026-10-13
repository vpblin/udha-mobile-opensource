import Foundation
import Observation
import os

/// On-disk home for meetings recorded on this device.
///
/// The desktop keeps one folder per meeting so everything is hand-inspectable;
/// this mirrors that. `meta.json` holds the whole `Meeting` (transcript and
/// notes included — they are small) and `audio.m4a` sits beside it.
///
/// **Why this exists at all.** Local meetings used to live only in the bridge's
/// in-memory array, which meant two guaranteed ways to lose one: relaunch the
/// app, or let a `meetings_full` from the Mac replace the list with the Mac's
/// idea of the world, which does not include a recording it has never been
/// told about. Recording something and then losing it is the worst thing this
/// feature can do, so the disk write happens before anything else is tried.
@MainActor
@Observable
final class MeetingStore {

    /// Every meeting recorded on this device, newest first.
    private(set) var localMeetings: [Meeting] = []

    private let root: URL
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "meetingstore")

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("Meetings", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Paths

    func folderURL(for id: String) -> URL {
        root.appendingPathComponent(sanitize(id), isDirectory: true)
    }

    /// The audio file's location if one was recorded, nil otherwise.
    func audioURL(for id: String) -> URL? {
        let url = folderURL(for: id).appendingPathComponent("audio.m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Creates the meeting folder and returns where audio should be written.
    /// Nil when the folder cannot be made — recording still proceeds, just
    /// without the safety net, which beats refusing to record at all.
    func prepareAudioURL(for id: String) -> URL? {
        let folder = folderURL(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            log.error("could not create meeting folder: \(error.localizedDescription)")
            return nil
        }
        let url = folder.appendingPathComponent("audio.m4a")
        // AVAudioFile refuses to overwrite; a retry of the same id should not
        // fail because of a stale file from an aborted attempt.
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Reading

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            localMeetings = []
            return
        }
        var loaded: [Meeting] = []
        for entry in entries where entry.hasDirectoryPath {
            let meta = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta) else { continue }
            guard let meeting = try? JSONDecoder().decode(Meeting.self, from: data) else {
                log.error("unreadable meta.json in \(entry.lastPathComponent)")
                continue
            }
            loaded.append(meeting)
        }
        localMeetings = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func meeting(id: String) -> Meeting? {
        localMeetings.first { $0.id == id }
    }

    /// Meetings still owed to the host, oldest first so a backlog drains in
    /// the order it was recorded.
    var pendingUploads: [Meeting] {
        localMeetings
            .filter { $0.syncState.needsUpload && !$0.isRecording }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Writing

    func save(_ meeting: Meeting) throws {
        let folder = folderURL(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meeting)
        // Atomic: a half-written meta.json is an unreadable meeting, and the
        // moment this runs is exactly when the app is most likely to be killed.
        try data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        upsert(meeting)
    }

    /// Saves without throwing — for the paths where losing the update is worse
    /// than any error we could usefully report.
    func saveQuietly(_ meeting: Meeting) {
        do {
            try save(meeting)
        } catch {
            log.error("meeting save failed: \(error.localizedDescription)")
            upsert(meeting)
        }
    }

    /// Applies an edit to a stored meeting and persists it. No-op when the id
    /// belongs to a host meeting — those are the Mac's to keep.
    @discardableResult
    func mutate(id: String, _ change: (inout Meeting) -> Void) -> Meeting? {
        guard var meeting = meeting(id: id) else { return nil }
        change(&meeting)
        saveQuietly(meeting)
        return meeting
    }

    func setSyncState(_ state: MeetingSyncState, for id: String) {
        mutate(id: id) { $0.syncState = state }
    }

    func delete(id: String) {
        deleteFolder(for: id)
        localMeetings.removeAll { $0.id == id }
    }

    func deleteFolder(for id: String) {
        try? FileManager.default.removeItem(at: folderURL(for: id))
    }

    private func upsert(_ meeting: Meeting) {
        if let idx = localMeetings.firstIndex(where: { $0.id == meeting.id }) {
            localMeetings[idx] = meeting
        } else {
            localMeetings.append(meeting)
            localMeetings.sort { $0.createdAt > $1.createdAt }
        }
    }

    /// Ids are UUIDs we generate, but a folder name is a filesystem thing and
    /// a stray separator would write outside the store.
    private func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }
}
