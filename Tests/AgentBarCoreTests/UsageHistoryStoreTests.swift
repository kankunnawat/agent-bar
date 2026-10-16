import Foundation
import Testing
@testable import AgentBarCore

@Suite struct UsageHistoryStoreTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private var store: UsageHistoryStore { UsageHistoryStore(home: home) }

    @Test func recordsAndReturnsSeries() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let series = await store.record(accountID: "claude:/tmp/a", session: 40, weekly: 60, at: now)
        #expect(series.count == 1)
        #expect(series[0].session == 40)
        #expect(series[0].weekly == 60)
    }

    @Test func sameHourKeepsMaxPerDimension() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = self.store
        _ = await store.record(accountID: "a", session: 40, weekly: 60, at: now)
        let series = await store.record(
            accountID: "a", session: 55, weekly: 30, at: now.addingTimeInterval(120))
        #expect(series.count == 1)
        #expect(series[0].session == 55)   // raised
        #expect(series[0].weekly == 60)    // kept
    }

    @Test func distinctHoursAppendInOrder() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = self.store
        _ = await store.record(accountID: "a", session: 10, weekly: nil, at: now.addingTimeInterval(3_600))
        let series = await store.record(accountID: "a", session: 20, weekly: nil, at: now)
        #expect(series.count == 2)
        #expect(series[0].hour < series[1].hour)
    }

    @Test func prunesPastRetention() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = self.store
        _ = await store.record(accountID: "a", session: 10, weekly: nil, at: now)
        let later = now.addingTimeInterval(31 * 86_400)
        let series = await store.record(accountID: "a", session: 20, weekly: nil, at: later)
        #expect(series.count == 1)
        #expect(series[0].session == 20)
    }

    @Test func persistsAcrossInstances() async {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = await UsageHistoryStore(home: home)
            .record(accountID: "codex:/Users/x", session: 12, weekly: 34, at: now)
        let series = await UsageHistoryStore(home: home).series(accountID: "codex:/Users/x")
        #expect(series.count == 1)
        #expect(series[0].weekly == 34)
    }

    @Test func corruptFileResetsToEmpty() async throws {
        let dir = home.appendingPathComponent("Library/Application Support/AgentBar/history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("a.json"))
        let series = await store.series(accountID: "a")
        #expect(series.isEmpty)
    }

    @Test func nothingToRecordWritesNothing() async {
        let series = await store.record(accountID: "a", session: nil, weekly: nil, at: Date())
        #expect(series.isEmpty)
        let dir = home.appendingPathComponent("Library/Application Support/AgentBar/history")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.json").path))
    }
}
