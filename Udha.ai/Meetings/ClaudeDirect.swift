import Foundation
import os

/// A small Anthropic Messages client for the times the Mac is not there.
///
/// The Mac stays the canonical summariser — it has the meeting folder, the
/// prompts and its own key — but a phone recording that ends somewhere with no
/// Mac in reach used to produce a transcript and nothing else, which is not
/// what anyone records a meeting for. This fills that gap and is overwritten
/// the moment the host's own pass lands.
///
/// Mirrors the desktop's `ClaudeClient`: same structured-output shape, same
/// `x-api-key` header, same JSON model. Kept deliberately minimal — this is not
/// a general-purpose SDK, it runs two prompts.
struct ClaudeDirect {

    /// The finalize pass. Quality matters more than latency: it runs once,
    /// after the call, and its output is what the user reads.
    static let notesModel = "claude-sonnet-5"
    /// The live Ask. Latency *is* the feature — an answer that arrives after
    /// the moment has passed is worthless mid-meeting.
    static let liveModel = "claude-haiku-4-5-20251001"

    private let apiKey: String
    private let log = Logger(subsystem: AppConfig.logSubsystem, category: "claudedirect")

    /// Nil when the user has not supplied a key — callers treat that as "this
    /// path is unavailable" rather than as an error to report.
    init?(apiKey: String? = SecureStorage.getAnthropicKey()) {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
    }

    static var hasKey: Bool { SecureStorage.getAnthropicKey() != nil }

    // MARK: - Requests

    /// Plain text answer.
    func text(system: String,
              user: String,
              model: String,
              maxTokens: Int = 1024) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        let json = try await post(body)
        return Self.firstText(in: json)
    }

    /// Structured answer, via a single forced tool call — the same trick the
    /// desktop uses, because a schema the model must fill beats parsing prose.
    func structured(system: String,
                    user: String,
                    schema: [String: Any],
                    model: String,
                    maxTokens: Int = 4096) async throws -> [String: Any] {
        let tool: [String: Any] = [
            "name": "record",
            "description": "Record the result.",
            "input_schema": schema,
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "record"],
            "messages": [["role": "user", "content": user]],
        ]
        let json = try await post(body)
        guard let content = json["content"] as? [[String: Any]],
              let use = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = use["input"] as? [String: Any] else {
            throw ClaudeDirectError.malformedResponse
        }
        return input
    }

    /// Cheapest possible round trip, to tell a bad key from a bad network
    /// while the user is looking at the settings sheet.
    func ping() async throws {
        _ = try await text(system: "Reply with OK.", user: "ping", model: Self.liveModel, maxTokens: 16)
    }

    // MARK: - Transport

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeDirectError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            log.error("claude \(http.statusCode): \(detail ?? "no detail")")
            throw ClaudeDirectError.api(status: http.statusCode, message: detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDirectError.malformedResponse
        }
        return json
    }

    private static func firstText(in json: [String: Any]) -> String {
        guard let content = json["content"] as? [[String: Any]] else { return "" }
        return content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ClaudeDirectError: LocalizedError {
    case api(status: Int, message: String?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .api(let status, let message):
            if status == 401 { return "That API key was rejected." }
            if status == 429 { return "Rate limited by the API. Try again shortly." }
            return message ?? "The API returned \(status)."
        case .malformedResponse:
            return "The API returned something unexpected."
        }
    }
}
