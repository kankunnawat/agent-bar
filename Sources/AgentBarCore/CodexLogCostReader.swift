import Foundation

/// Prices an account's local Codex session logs at API rates.
///
/// Approximation, by design: Codex token_count lines carry no model id, so
/// all usage is priced at the single "codex-default" rate. Billable input is
/// input_tokens minus cached_input_tokens; the cached portion is priced at
/// the cache-read rate; output_tokens (which already includes reasoning
/// tokens) at the output rate. `total_token_usage` is cumulative per session
/// and must never be summed across events — only `last_token_usage` deltas.
public enum CodexLogCostReader {
    public static func cost(
        codexDir: URL, now: Date, fileManager: FileManager = .default, cache: FileRecordCache
    ) -> (cost: UsageCost, cache: FileRecordCache) {
        LogCostScanner.scan(
            roots: [codexDir.appendingPathComponent("sessions"),
                    codexDir.appendingPathComponent("archived_sessions")],
            now: now, fileManager: fileManager, cache: cache, priceLine: priceLine)
    }

    /// Cache-less convenience for callers that don't memoize (tests).
    public static func cost(codexDir: URL, now: Date, fileManager: FileManager = .default) -> UsageCost {
        cost(codexDir: codexDir, now: now, fileManager: fileManager, cache: [:]).cost
    }

    /// key is always nil: `last_token_usage` values are genuine per-event deltas
    /// and must never be deduped (sessions/ and archived_sessions/ don't overlap).
    private static func priceLine(_ object: [String: Any]) -> (key: String?, date: Date, usd: Double)? { // swiftlint:disable:this large_tuple line_length
        guard let timestamp = object["timestamp"] as? String,
              let date = ISO8601.parse(timestamp),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let usd = ModelPriceTable.costUSD(
            model: "codex-default",
            input: max(0, input - cached),
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: cached,
            cacheWrite: 0)
        return (nil, date, usd)
    }
}
