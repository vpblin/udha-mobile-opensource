import Foundation

/// A reusable agent definition living on the host (the desktop's `Agents/Agent`).
///
/// The body is the agent's markdown prompt file, shown verbatim in a terminal
/// block so you can read exactly what will run before running it.
struct BridgeAgent: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    /// Default working directory, if the agent declares one.
    var directory: String?
    /// The prompt file, split into lines for rendering.
    var body: [String]

    /// "Run in crm-api" / "Run…" when no directory is bound yet.
    var runLabel: String {
        guard let directory, !directory.isEmpty else { return "Run…" }
        return "Run in \((directory as NSString).lastPathComponent)"
    }

    var directoryName: String? {
        guard let directory, !directory.isEmpty else { return nil }
        return (directory as NSString).lastPathComponent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Agent"
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        directory = try? c.decode(String.self, forKey: .directory)
        // Hosts may send the prompt as one blob or pre-split; accept either
        // rather than rendering an empty body against the wrong shape.
        if let lines = try? c.decode([String].self, forKey: .body) {
            body = lines
        } else if let blob = try? c.decode(String.self, forKey: .body) {
            body = blob.components(separatedBy: "\n")
        } else {
            body = []
        }
    }

    init(id: String, name: String, summary: String, directory: String? = nil, body: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.directory = directory
        self.body = body
    }

    enum CodingKeys: String, CodingKey { case id, name, summary, directory, body }
}
