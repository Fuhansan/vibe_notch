import Foundation

/// Parses a Claude Code session transcript JSONL file and returns the most
/// recent assistant text response. Returns nil if the file is missing or
/// contains no assistant text. Reads only the tail of the file for efficiency.
enum TranscriptReader {
    /// Returns the text of the LAST real user prompt in the transcript
    /// (entries with type=user AND a promptId — tool_results are excluded).
    /// Used to backfill `promptSummary` when the App restarts mid-session.
    static func lastUserPrompt(transcriptPath: String, maxLen: Int = 4000) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            // String content = real user prompt — done.
            if let str = message["content"] as? String {
                if let formatted = Self.format(str, maxLen: maxLen) { return formatted }
                continue
            }
            // Array content: a real prompt may use text blocks; tool_result
            // entries also live here but only have `tool_result` blocks. Keep
            // walking back when we don't find any text block.
            if let arr = message["content"] as? [[String: Any]] {
                for item in arr {
                    if (item["type"] as? String) == "text",
                       let text = item["text"] as? String,
                       let formatted = Self.format(text, maxLen: maxLen) {
                        return formatted
                    }
                }
            }
            // Not a real prompt; keep searching upward.
        }
        return nil
    }

    /// Returns the latest assistant text response that appears AFTER the most
    /// recent user prompt in the file. This guarantees the reply belongs to
    /// the current turn — earlier-turn text is never returned. Returns nil
    /// when the file hasn't yet been flushed with an assistant text for the
    /// current turn (the caller should retry).
    /// Returns the ordered timeline of THIS turn — every assistant text block
    /// AND every tool_use, in the order they appear. Powers the milestone
    /// view in DetailCard.
    static func currentTurnSteps(transcriptPath: String) -> [TurnStep] {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String { isRealPrompt = true }
            else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true; break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        guard let userIdx = lastUserIdx else { return [] }

        var steps: [TurnStep] = []
        for line in lines[(userIdx + 1)...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                switch item["type"] as? String {
                case "text":
                    if let text = item["text"] as? String,
                       let formatted = Self.format(text, maxLen: 4000) {
                        steps.append(.text(formatted))
                    }
                case "tool_use":
                    let name = (item["name"] as? String) ?? "?"
                    let input = item["input"] as? [String: Any]
                    steps.append(.tool(name: name, input: Self.toolInputSummary(name: name, input: input)))
                default:
                    break
                }
            }
        }
        return steps
    }

    private static func toolInputSummary(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Edit", "Write", "Read", "NotebookEdit":
            return (input["file_path"] as? String) ?? (input["path"] as? String)
        case "Bash":
            guard let cmd = input["command"] as? String else { return nil }
            let line = cmd.split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        case "Grep", "Glob":
            return input["pattern"] as? String
        case "WebFetch":
            return input["url"] as? String
        case "Task":
            return input["prompt"] as? String
        default:
            return nil
        }
    }

    /// Legacy plain text helper (kept for reply-poll comparison).
    static func currentTurnReplyBlocks(transcriptPath: String, perBlockMaxLen: Int = 4000) -> [String] {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return [] }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String {
                isRealPrompt = true
            } else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true
                    break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        guard let userIdx = lastUserIdx else { return [] }

        var blocks: [String] = []
        for line in lines[(userIdx + 1)...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                if (item["type"] as? String) == "text",
                   let text = item["text"] as? String,
                   let formatted = Self.format(text, maxLen: perBlockMaxLen) {
                    blocks.append(formatted)
                }
            }
        }
        return blocks
    }

    static func currentTurnReply(transcriptPath: String, maxLen: Int = 4000) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024),
              let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Find the LAST REAL user prompt. Tool results also have type=user
        // and `promptId`, but their content is a tool_result block array
        // without text — we must skip those to avoid using them as the
        // turn boundary (which would hide intermediate assistant text).
        var lastUserIdx: Int? = nil
        for (i, line) in lines.enumerated().reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "user" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var isRealPrompt = false
            if message["content"] is String {
                isRealPrompt = true
            } else if let arr = message["content"] as? [[String: Any]] {
                for item in arr where (item["type"] as? String) == "text" {
                    isRealPrompt = true
                    break
                }
            }
            if isRealPrompt {
                lastUserIdx = i
                break
            }
        }
        guard let userIdx = lastUserIdx else { return nil }

        // Walk lines AFTER the user prompt; find the LAST assistant text.
        var bestText: String? = nil
        for line in lines[(userIdx + 1)...] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                if (item["type"] as? String) == "text",
                   let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        bestText = trimmed  // keep updating — LAST text wins
                    }
                }
            }
        }
        return Self.format(bestText, maxLen: maxLen)
    }

    private static func format(_ s: String?, maxLen: Int) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxLen {
            return String(trimmed.prefix(maxLen)) + "…"
        }
        return trimmed
    }

    /// Truncates the result to `maxLen` chars (with an ellipsis) and strips
    /// to first non-empty line.
    static func lastAssistantReply(transcriptPath: String, maxLen: Int = 220) -> String? {
        guard let data = readTail(path: transcriptPath, maxBytes: 256 * 1024) else {
            return nil
        }
        guard let blob = String(data: data, encoding: .utf8) else { return nil }
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            guard (obj["type"] as? String) == "assistant" else { continue }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }

            // Walk content blocks from the end; first text block wins.
            for item in content.reversed() {
                guard (item["type"] as? String) == "text",
                      let text = item["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // Collapse multi-line text into a single space-joined string —
                // the row renderer wraps it into 2 visual lines as needed.
                let collapsed = trimmed
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if collapsed.count > maxLen {
                    return String(collapsed.prefix(maxLen)) + "…"
                }
                return collapsed
            }
        }
        return nil
    }

    /// Reads up to `maxBytes` from the END of the file. Used to bound work for
    /// long-running sessions whose transcripts grow into the megabytes.
    private static func readTail(path: String, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }
}
