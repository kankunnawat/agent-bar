import Foundation

/// Facade over the per-provider log cost readers. Local filesystem only —
/// no network, no keychain — so it is safe to run off the main actor.
public enum UsageCostFetcher {
    public static func cost(
        for account: Account, now: Date, fileManager: FileManager = .default, cache: FileRecordCache
    ) -> (cost: UsageCost, cache: FileRecordCache) {
        let dir = URL(fileURLWithPath: account.path)
        switch account.provider {
        case .claude:
            return ClaudeLogCostReader.cost(configDir: dir, now: now, fileManager: fileManager, cache: cache)
        case .codex:
            return CodexLogCostReader.cost(codexDir: dir, now: now, fileManager: fileManager, cache: cache)
        case .cursor:
            // Cursor keeps no local usage logs; a zero cost hides the row caption.
            return (.zero, cache)
        }
    }

    /// Cache-less convenience for callers that don't memoize (tests).
    public static func cost(for account: Account, now: Date, fileManager: FileManager = .default) -> UsageCost {
        cost(for: account, now: now, fileManager: fileManager, cache: [:]).cost
    }
}
