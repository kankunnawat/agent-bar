import Foundation

/// USD per million tokens at public API list prices. All figures are
/// estimates of what the local usage would cost on the API — never a bill.
public struct ModelRate: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// Single source of truth for pricing. Model ids match by family keyword so
/// dated/point releases (claude-opus-4-6, claude-opus-4-8, ...) resolve
/// without per-release entries. Claude cache rates: read 0.1x input, write
/// 1.25x input (5m TTL). "codex-default" is the one flat rate used for all
/// Codex usage (Codex logs don't carry a model id per token line).
public enum ModelPriceTable {
    static let families: [(keyword: String, rate: ModelRate)] = [
        ("fable", ModelRate(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)),
        ("opus", ModelRate(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("sonnet", ModelRate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("haiku", ModelRate(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)),
        ("codex-default", ModelRate(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
    ]

    static func rate(for model: String) -> ModelRate? {
        families.first { model.contains($0.keyword) }?.rate
    }

    /// Prices one usage record. An unknown model contributes $0 and logs at
    /// debug level so table gaps are visible without spamming user-level logs.
    public static func costUSD(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        guard let rate = rate(for: model) else {
            Log.cost.debug("no price for model \(model, privacy: .public); contributes $0")
            return 0
        }
        return (Double(input) * rate.input
            + Double(output) * rate.output
            + Double(cacheRead) * rate.cacheRead
            + Double(cacheWrite) * rate.cacheWrite) / 1_000_000
    }
}
