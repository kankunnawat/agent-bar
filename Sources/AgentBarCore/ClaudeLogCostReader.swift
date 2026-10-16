import Foundation

/// Prices an account's local Claude session logs at API rates.
/// Read-only: never touches credentials or writes anything back.
public enum ClaudeLogCostReader {
    public static func cost(
        configDir: URL, now: Date, fileManager: FileManager = .default, cache: FileRecordCache
    ) -> (cost: UsageCost, cache: FileRecordCache) {
        LogCostScanner.scan(
            roots: [configDir.appendingPathComponent("projects")],
            now: now, fileManager: fileManager, cache: cache, priceLine: priceLine)
    }

    /// Cache-less convenience for callers that don't memoize (tests).
    public static func cost(configDir: URL, now: Date, fileManager: FileManager = .default) -> UsageCost {
        cost(configDir: configDir, now: now, fileManager: fileManager, cache: [:]).cost
    }

    /// (dedupe key, timestamp, USD) for an assistant line carrying usage; nil otherwise.
    /// input_tokens excludes cache tokens — each bucket priced separately.
    ///
    /// Claude Code writes one jsonl line per content block of an assistant message,
    /// and every such line repeats the identical full `usage` object — so a single
    /// API call would otherwise be counted N times. The key `message.id|requestId`
    /// lets the scanner collapse those duplicates to one; a resume/fork copies the
    /// same line into multiple files, so dedupe must span the whole scan. When both
    /// ids are absent the key is nil and the line always counts (no dedupe).
    private static func priceLine(_ object: [String: Any]) -> (key: String?, date: Date, usd: Double)? { // swiftlint:disable:this large_tuple line_length
        guard let timestamp = object["timestamp"] as? String,
              let date = ISO8601.parse(timestamp),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        let usd = ModelPriceTable.costUSD(
            model: message["model"] as? String ?? "",
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
        let messageID = message["id"] as? String ?? ""
        let requestID = object["requestId"] as? String ?? ""
        let key = (messageID.isEmpty && requestID.isEmpty) ? nil : "\(messageID)|\(requestID)"
        return (key, date, usd)
    }
}
