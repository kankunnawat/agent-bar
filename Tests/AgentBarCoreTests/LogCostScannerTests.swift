import Foundation
import Testing
@testable import AgentBarCore

@Suite struct LogCostScannerTests {
    let now = Date()

    /// One assistant line priced at exactly $5 (1M opus input). Non-empty
    /// `id`/`requestId` embed the dedupe key so copies collapse.
    private func line(at date: Date, id: String = "", requestId: String = "",
                      inputTokens: Int = 1_000_000) -> String {
        let usage = "{\"input_tokens\":\(inputTokens),\"output_tokens\":0,"
            + "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}"
        let idField = id.isEmpty ? "" : "\"id\":\"\(id)\","
        let reqField = requestId.isEmpty ? "" : "\"requestId\":\"\(requestId)\","
        return "{\"timestamp\":\"\(CostFixtures.iso(date))\",\(reqField)"
            + "\"message\":{\(idField)\"model\":\"claude-opus-4-6\",\"usage\":\(usage)}}"
    }

    private func file(_ dir: URL, _ name: String) -> URL {
        dir.appendingPathComponent("projects/proj/\(name)")
    }

    @Test func cacheHitYieldsSameTotalsAsColdScan() throws {
        let dir = try CostFixtures.makeDir()
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-1)
        try CostFixtures.write(lines: [line(at: now), line(at: yesterday)],
                               to: file(dir, "session.jsonl"))
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: cold.cache)
        #expect(!cold.cache.isEmpty)
        #expect(abs(warm.cost.today - cold.cost.today) < 0.0001)         // $5
        #expect(abs(warm.cost.thirtyDay - cold.cost.thirtyDay) < 0.0001) // $10
    }

    @Test func changedFileIsReparsed() throws {
        let dir = try CostFixtures.makeDir()
        let target = file(dir, "session.jsonl")
        try CostFixtures.write(lines: [line(at: now)], to: target)
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        // Append a second line (size AND mtime change → cache miss).
        try CostFixtures.write(lines: [line(at: now), line(at: now)],
                               to: target, mtime: now.addingTimeInterval(1))
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: cold.cache)
        #expect(abs(cold.cost.today - 5) < 0.0001)  // one line
        #expect(abs(warm.cost.today - 10) < 0.0001) // re-parsed, two lines
    }

    @Test func deletedFileIsPrunedFromCache() throws {
        let dir = try CostFixtures.makeDir()
        try CostFixtures.write(lines: [line(at: now)], to: file(dir, "a.jsonl"))
        try CostFixtures.write(lines: [line(at: now)], to: file(dir, "b.jsonl"))
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        #expect(cold.cache.count == 2)
        try FileManager.default.removeItem(at: file(dir, "b.jsonl"))
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: cold.cache)
        #expect(warm.cache.count == 1)                 // b pruned
        #expect(abs(warm.cost.today - 5) < 0.0001)     // only a counts
    }

    @Test func crossFileDedupSurvivesCaching() throws {
        let dir = try CostFixtures.makeDir()
        // Same keyed line copied into two files (resume/fork) → counts once.
        let dupe = line(at: now, id: "m1", requestId: "r1")
        try CostFixtures.write(lines: [dupe], to: file(dir, "a.jsonl"))
        try CostFixtures.write(lines: [dupe], to: file(dir, "b.jsonl"))
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: cold.cache)
        #expect(abs(cold.cost.today - 5) < 0.0001) // once, not twice
        #expect(abs(warm.cost.today - 5) < 0.0001) // still once from cache
    }

    /// A cache hit must serve the previously-parsed records, not reparse. Rewrite
    /// the file with different content of identical byte size and forced-identical
    /// mtime so the (mtime, size) key still matches: the warm total must reflect
    /// the ORIGINAL content ($5), not the new content ($10).
    @Test func cacheHitServesStaleRecordsWhenMtimeAndSizeUnchanged() throws {
        let dir = try CostFixtures.makeDir()
        let target = file(dir, "session.jsonl")
        let original = line(at: now, inputTokens: 1_000_000)   // $5
        let rewritten = line(at: now, inputTokens: 2_000_000)  // $10, equal length
        #expect(original.count == rewritten.count)             // equal-size precondition
        let mtime = now.addingTimeInterval(-60)
        try CostFixtures.write(lines: [original], to: target, mtime: mtime)
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        // Same file, same byte size, forced-same mtime → cache still hits.
        try CostFixtures.write(lines: [rewritten], to: target, mtime: mtime)
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: cold.cache)
        #expect(abs(cold.cost.today - 5) < 0.0001) // original content
        #expect(abs(warm.cost.today - 5) < 0.0001) // served from cache, not 10
    }

    /// Aging-out happens at scan time from cached records, with no reparse. A line
    /// dated "now" is in `today` at the first scan; scanning the unchanged file two
    /// days later must drop it from `today` while keeping it in `thirtyDay`.
    @Test func recordAgesOutOfTodayOnLaterNowWithoutReparse() throws {
        let dir = try CostFixtures.makeDir()
        let target = file(dir, "session.jsonl")
        let mtime = now.addingTimeInterval(-60)
        try CostFixtures.write(lines: [line(at: now)], to: target, mtime: mtime)
        let cold = ClaudeLogCostReader.cost(configDir: dir, now: now, cache: [:])
        #expect(abs(cold.cost.today - 5) < 0.0001) // dated now → today
        let later = now.addingTimeInterval(2 * 86_400)
        let warm = ClaudeLogCostReader.cost(configDir: dir, now: later, cache: cold.cache)
        #expect(abs(warm.cost.today) < 0.0001)         // aged out of today
        #expect(abs(warm.cost.thirtyDay - 5) < 0.0001) // still within 30 days
    }

    @Test func bucketsCostPerLocalDay() throws {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-daily-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Three lines: a deduped duplicate pair on `now`, one record yesterday.
        let lines = [
            #"{"key":"a","ts":\#(now.timeIntervalSince1970),"usd":1.0}"#,
            #"{"key":"a","ts":\#(now.timeIntervalSince1970),"usd":1.0}"#,
            #"{"key":"b","ts":\#(yesterday.timeIntervalSince1970),"usd":2.5}"#,
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: root.appendingPathComponent("log.jsonl"))
        let result = LogCostScanner.scan(
            roots: [root], now: now, fileManager: .default, cache: [:],
            priceLine: { object in
                guard let seconds = object["ts"] as? Double, let usd = object["usd"] as? Double
                else { return nil }
                return (object["key"] as? String, Date(timeIntervalSince1970: seconds), usd)
            })
        #expect(result.cost.daily[calendar.startOfDay(for: now)] == 1.0)
        #expect(result.cost.daily[calendar.startOfDay(for: yesterday)] == 2.5)
        #expect(result.cost.daily.count == 2)
    }
}
