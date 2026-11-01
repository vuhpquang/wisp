import Foundation

/// Lets connected agents see each other. For every agent and terminal Wisp
/// keeps a short readable digest (recent conversation or output), and for
/// every agent a list of what it's connected to, with the digests' paths.
/// The hook prints that list when a prompt is sent, which Claude adds to its
/// context; the agent reads a digest when it needs to.
enum SuperNodeContext {
    static var digestDirectory: URL { SuperNodeHooks.directory.appendingPathComponent("context") }
    static var linksDirectory: URL { SuperNodeHooks.directory.appendingPathComponent("links") }

    static func digestURL(_ id: UUID) -> URL {
        digestDirectory.appendingPathComponent(id.uuidString + ".md")
    }

    /// Named the way the hook script looks it up, from the node's ID.
    static func linksURL(_ id: UUID) -> URL {
        linksDirectory.appendingPathComponent(id.uuidString + ".md")
    }

    /// Writes a file only when its contents change, so nothing churns.
    static func write(_ text: String?, to url: URL) {
        let manager = FileManager.default
        guard let text else {
            try? manager.removeItem(at: url)
            return
        }
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: digestURL(id))
        try? FileManager.default.removeItem(at: linksURL(id))
    }

    // MARK: Transcripts

    struct Transcript {
        /// The recent conversation as Markdown.
        let conversation: String
        /// Tokens in the context window after the last reply.
        let contextTokens: Int?
        let model: String?
    }

    /// Reads the end of a Claude Code transcript. Call this off the main thread.
    static func readTranscript(_ path: String) -> Transcript? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 768 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        // The first line is cut off unless the file was read from the start.
        if size > window, !lines.isEmpty { lines.removeFirst() }

        var entries: [String] = []
        var tokens: Int?
        var model: String?
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }

            if type == "assistant", let usage = message["usage"] as? [String: Any] {
                let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .compactMap { usage[$0] as? Int }
                    .reduce(0, +)
                if total > 0 { tokens = total }
                model = message["model"] as? String ?? model
            }
            entries.append(contentsOf: describe(message, from: type))
        }

        let conversation = entries.suffix(40).joined(separator: "\n")
        return Transcript(conversation: conversation, contextTokens: tokens, model: model)
    }

    /// The readable lines of one transcript message: text, and the tools used.
    private static func describe(_ message: [String: Any], from type: String) -> [String] {
        let speaker = type == "user" ? "**User:**" : "**Claude:**"
        if let text = message["content"] as? String {
            return text.hasPrefix("<") ? [] : ["\(speaker) \(clip(text))"]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var lines: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty, !text.hasPrefix("<") {
                    lines.append("\(speaker) \(clip(text))")
                }
            case "tool_use":
                let name = block["name"] as? String ?? "a tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let detail = ["command", "file_path", "description", "pattern", "url", "query"]
                    .lazy.compactMap { input[$0] as? String }.first
                    .map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
                lines.append("- used \(name)" + (detail.map { ": `\(clip($0, 160))`" } ?? ""))
            default:
                break
            }
        }
        return lines
    }

    private static func clip(_ text: String, _ limit: Int = 700) -> String {
        let single = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count > limit ? String(single.prefix(limit)) + "…" : single
    }

    /// The size of the context window for a model and usage, in tokens.
    static func contextWindow(model: String?, tokens: Int) -> Int {
        if tokens > 200_000 || model?.contains("[1m]") == true { return 1_000_000 }
        return 200_000
    }
}
