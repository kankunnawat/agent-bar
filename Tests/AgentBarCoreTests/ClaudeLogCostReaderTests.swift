import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ClaudeLogCostReaderTests {
    let now = Date()

    /// One assistant log line. Defaults price to exactly $5 (1M opus input).
    /// When `id`/`requestId` are non-empty they are embedded so the scanner can
    /// dedupe the repeated per-content-block lines Claude Code writes per message.
    private func line(model: String = "claude-opus-4-6", at date: Date,
                      input: Int = 1_000_000, output: Int = 0,
                      cacheRead: Int = 0, cacheWrite: Int = 0,
                      id: String = "", requestId: String = "") -> String {
        let usage = "{\"input_tokens\":\(input),\"output_tokens\":\(output),"
            + "\"cache_creation_input_tokens\":\(cacheWrite),\"cache_read_input_tokens\":\(cacheRead)}"
        let idField = id.isEmpty ? "" : "\"id\":\"\(id)\","
        let requestField = requestId.isEmpty ? "" : "\"requestId\":\"\(requestId)\","
        return "{\"timestamp\":\"\(CostFixtures.iso(date))\",\(requestField)"
            + "\"message\":{\(idField)\"model\":\"\(model)\",\"usage\":\(usage)}}"
    }

    @Test func bucketsTodayVersusTrailingThirtyDays() throws {
        let dir = try CostFixtures.makeDir()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-1)
        try CostFixtures.write(
            lines: [line(at: now), line(at: yesterday)],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.today - 5) < 0.0001)      // only the line at `now`
        #expect(abs(cost.thirtyDay - 10) < 0.0001) // both lines
    }

    @Test func timestampsOlderThanThirtyDaysAreExcluded() throws {
        let dir = try CostFixtures.makeDir()
        let old = now.addingTimeInterval(-40 * 86_400)
        try CostFixtures.write(
            lines: [line(at: old), line(at: now)],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001)
    }

    @Test func staleFilesAreSkippedByMtime() throws {
        let dir = try CostFixtures.makeDir()
        try CostFixtures.write(
            lines: [line(at: now)],
            to: dir.appendingPathComponent("projects/proj/old.jsonl"),
            mtime: now.addingTimeInterval(-40 * 86_400))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(cost == .zero) // file never opened — mtime bound
    }

    @Test func accountsAreIsolated() throws {
        let dirA = try CostFixtures.makeDir()
        let dirB = try CostFixtures.makeDir()
        try CostFixtures.write(
            lines: [line(at: now)],
            to: dirA.appendingPathComponent("projects/proj/a.jsonl"))
        try CostFixtures.write(
            lines: [line(at: now), line(at: now)],
            to: dirB.appendingPathComponent("projects/proj/b.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dirA, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001) // dirB never bleeds in
    }

    @Test func malformedAndUsagelessLinesAreTolerated() throws {
        let dir = try CostFixtures.makeDir()
        let usageless = "{\"timestamp\":\"\(CostFixtures.iso(now))\","
            + "\"message\":{\"model\":\"claude-opus-4-6\"}}"
        try CostFixtures.write(
            lines: ["not json at all", usageless, line(at: now)],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001) // only the valid line counts
    }

    @Test func duplicateContentBlockLinesCountOnce() throws {
        let dir = try CostFixtures.makeDir()
        // Claude Code writes one line per content block, each repeating the full
        // usage; the shared (id, requestId) key must collapse them to one charge.
        let dup = line(at: now, id: "msg_01Lwmp", requestId: "req_011Capt")
        try CostFixtures.write(
            lines: [dup, dup, dup],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001) // one API call, not three
        #expect(abs(cost.today - 5) < 0.0001)
    }

    @Test func duplicateLinesAcrossFilesCountOnce() throws {
        let dir = try CostFixtures.makeDir()
        // A resume/fork copies the same line into another file — dedupe must span
        // the whole scan, not just within one file.
        let dup = line(at: now, id: "msg_01Lwmp", requestId: "req_011Capt")
        try CostFixtures.write(lines: [dup], to: dir.appendingPathComponent("projects/proj/a.jsonl"))
        try CostFixtures.write(lines: [dup], to: dir.appendingPathComponent("projects/proj/b.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 5) < 0.0001)
    }

    @Test func differentMessagesEachCount() throws {
        let dir = try CostFixtures.makeDir()
        try CostFixtures.write(
            lines: [line(at: now, id: "msg_A", requestId: "req_A"),
                    line(at: now, id: "msg_B", requestId: "req_B")],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 10) < 0.0001) // distinct keys → both count
    }

    @Test func cacheBucketsArePricedSeparately() throws {
        let dir = try CostFixtures.makeDir()
        // 1M cacheRead ($0.50) + 1M cacheWrite ($6.25), zero plain input.
        try CostFixtures.write(
            lines: [line(at: now, input: 0, cacheRead: 1_000_000, cacheWrite: 1_000_000)],
            to: dir.appendingPathComponent("projects/proj/session.jsonl"))
        let cost = ClaudeLogCostReader.cost(configDir: dir, now: now)
        #expect(abs(cost.thirtyDay - 6.75) < 0.0001)
    }
}
