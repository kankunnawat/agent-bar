import Foundation
import Testing
@testable import AgentBarCore

@Suite struct UsageCostFetcherTests {
    let now = Date()

    @Test func dispatchesClaudeAccountsToClaudeReader() throws {
        let dir = try CostFixtures.makeDir()
        let usage = "{\"input_tokens\":1000000,\"output_tokens\":0,"
            + "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}"
        let line = "{\"timestamp\":\"\(CostFixtures.iso(now))\","
            + "\"message\":{\"model\":\"claude-opus-4-6\",\"usage\":\(usage)}}"
        try CostFixtures.write(lines: [line], to: dir.appendingPathComponent("projects/p/s.jsonl"))
        let account = Account(provider: .claude, path: dir.path, label: "test", hidden: false)
        let cost = UsageCostFetcher.cost(for: account, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001)
    }

    @Test func dispatchesCodexAccountsToCodexReader() throws {
        let dir = try CostFixtures.makeDir()
        let last = "{\"input_tokens\":1000000,\"cached_input_tokens\":0,"
            + "\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":1000000}"
        let line = "{\"timestamp\":\"\(CostFixtures.iso(now))\",\"type\":\"event_msg\","
            + "\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(last)}}}"
        try CostFixtures.write(
            lines: [line], to: dir.appendingPathComponent("sessions/2026/07/04/rollout-a.jsonl"))
        let account = Account(provider: .codex, path: dir.path, label: "test", hidden: false)
        let cost = UsageCostFetcher.cost(for: account, now: now)
        #expect(abs(cost.thirtyDay - 1.25) < 0.0001) // 1M billable input at codex-default
    }

    @Test func missingLogDirectoryYieldsZero() {
        let account = Account(
            provider: .claude, path: "/nonexistent/agentbar-test", label: "x", hidden: false)
        #expect(UsageCostFetcher.cost(for: account, now: now) == .zero)
    }

    @Test func cursorHasNoLocalCost() {
        let account = Account(provider: .cursor, path: "/tmp/no-such-cursor", label: "Cursor", hidden: false)
        #expect(UsageCostFetcher.cost(for: account, now: Date()).isZero)
    }
}
