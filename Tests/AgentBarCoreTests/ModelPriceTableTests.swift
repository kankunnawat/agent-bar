import Testing
@testable import AgentBarCore

@Suite struct ModelPriceTableTests {
    private func usd(_ model: String, input: Int = 0, output: Int = 0,
                     cacheRead: Int = 0, cacheWrite: Int = 0) -> Double {
        ModelPriceTable.costUSD(
            model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    @Test func opusInputAndOutputRates() {
        #expect(abs(usd("claude-opus-4-6", input: 1_000_000) - 5.0) < 0.0001)
        #expect(abs(usd("claude-opus-4-8", output: 1_000_000) - 25.0) < 0.0001)
    }

    @Test func cacheReadIsPricedDistinctlyFromInput() {
        // 0.1x input for Claude — pricing cache reads at the input rate
        // would inflate the estimate ~10x on cache-heavy logs.
        #expect(abs(usd("claude-opus-4-6", cacheRead: 1_000_000) - 0.5) < 0.0001)
        #expect(abs(usd("claude-sonnet-4-6", cacheRead: 1_000_000) - 0.3) < 0.0001)
    }

    @Test func cacheWriteIsPricedDistinctlyFromInput() {
        // 1.25x input for Claude.
        #expect(abs(usd("claude-opus-4-6", cacheWrite: 1_000_000) - 6.25) < 0.0001)
        #expect(abs(usd("claude-haiku-4-5", cacheWrite: 1_000_000) - 1.25) < 0.0001)
    }

    @Test func sonnetHaikuAndFableFamiliesResolve() {
        #expect(abs(usd("claude-sonnet-4-6", input: 1_000_000) - 3.0) < 0.0001)
        #expect(abs(usd("claude-haiku-4-5", input: 1_000_000) - 1.0) < 0.0001)
        #expect(abs(usd("claude-fable-5", input: 1_000_000) - 10.0) < 0.0001)
    }

    @Test func codexDefaultRate() {
        #expect(abs(usd("codex-default", input: 1_000_000) - 1.25) < 0.0001)
        #expect(abs(usd("codex-default", output: 1_000_000) - 10.0) < 0.0001)
        #expect(abs(usd("codex-default", cacheRead: 1_000_000) - 0.125) < 0.0001)
    }

    @Test func unknownModelContributesZero() {
        #expect(usd("some-mystery-model", input: 1_000_000, output: 1_000_000) == 0)
    }

    @Test func mixedBucketsSum() {
        // opus: 100k in ($0.50) + 50k out ($1.25) + 2M cacheRead ($1.00)
        // + 200k cacheWrite ($1.25) = $4.00
        let cost = usd("claude-opus-4-6", input: 100_000, output: 50_000,
                       cacheRead: 2_000_000, cacheWrite: 200_000)
        #expect(abs(cost - 4.0) < 0.0001)
    }
}
