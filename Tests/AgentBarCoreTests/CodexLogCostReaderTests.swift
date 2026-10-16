import Foundation
import Testing
@testable import AgentBarCore

@Suite struct CodexLogCostReaderTests {
    let now = Date()

    /// One token_count event. Defaults price to exactly $1.575:
    /// billable input 400k * $1.25/M = $0.50, cached 600k * $0.125/M = $0.075,
    /// output 100k * $10/M = $1.00. total_token_usage carries huge cumulative
    /// numbers that would dwarf this if a reader summed them by mistake.
    private func event(at date: Date, input: Int = 1_000_000, cached: Int = 600_000,
                       output: Int = 100_000) -> String {
        let last = "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),"
            + "\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}"
        let total = "{\"input_tokens\":99000000,\"cached_input_tokens\":50000000,"
            + "\"output_tokens\":9000000,\"reasoning_output_tokens\":0,\"total_tokens\":108000000}"
        return "{\"timestamp\":\"\(CostFixtures.iso(date))\",\"type\":\"event_msg\","
            + "\"payload\":{\"type\":\"token_count\",\"info\":"
            + "{\"last_token_usage\":\(last),\"total_token_usage\":\(total)}}}"
    }

    @Test func sumsLastTokenUsageNotCumulativeTotals() throws {
        let dir = try CostFixtures.makeDir()
        try CostFixtures.write(
            lines: [event(at: now), event(at: now)],
            to: dir.appendingPathComponent("sessions/2026/07/04/rollout-abc.jsonl"))
        let cost = CodexLogCostReader.cost(codexDir: dir, now: now)
        // 2 * $1.575 — if total_token_usage were summed this would be >$200.
        #expect(abs(cost.thirtyDay - 3.15) < 0.0001)
        #expect(abs(cost.today - 3.15) < 0.0001)
    }

    @Test func bucketsByEventDay() throws {
        let dir = try CostFixtures.makeDir()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-1)
        try CostFixtures.write(
            lines: [event(at: now), event(at: yesterday)],
            to: dir.appendingPathComponent("sessions/2026/07/04/rollout-abc.jsonl"))
        let cost = CodexLogCostReader.cost(codexDir: dir, now: now)
        #expect(abs(cost.today - 1.575) < 0.0001)
        #expect(abs(cost.thirtyDay - 3.15) < 0.0001)
    }

    @Test func archivedSessionsAreIncluded() throws {
        let dir = try CostFixtures.makeDir()
        try CostFixtures.write(
            lines: [event(at: now)],
            to: dir.appendingPathComponent("archived_sessions/2026/06/01/rollout-old.jsonl"))
        let cost = CodexLogCostReader.cost(codexDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 1.575) < 0.0001)
    }

    @Test func nonTokenCountEventsAndGarbageAreSkipped() throws {
        let dir = try CostFixtures.makeDir()
        let other = "{\"timestamp\":\"\(CostFixtures.iso(now))\",\"type\":\"event_msg\","
            + "\"payload\":{\"type\":\"agent_message\"}}"
        try CostFixtures.write(
            lines: ["garbage", other, event(at: now)],
            to: dir.appendingPathComponent("sessions/2026/07/04/rollout-abc.jsonl"))
        let cost = CodexLogCostReader.cost(codexDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 1.575) < 0.0001)
    }
}
