import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ModelsTests {
    @Test func accountIDCombinesProviderAndPath() {
        let a = Account(provider: .claude, path: "/Users/x/.claude-personal", label: "personal", hidden: false)
        #expect(a.id == "claude:/Users/x/.claude-personal")
    }

    @Test func iso8601ParsesFractionalAndPlain() {
        #expect(ISO8601.parse("2026-07-03T10:15:30.123Z") != nil)
        #expect(ISO8601.parse("2026-07-03T10:15:30Z") != nil)
        #expect(ISO8601.parse("not a date") == nil)
    }

    @Test func retryAfterParsesSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(RetryAfter.parse("120", now: now) == now.addingTimeInterval(120))
        #expect(RetryAfter.parse("Fri, 31 Dec 1999 23:59:59 GMT", now: now) != nil)
        #expect(RetryAfter.parse(nil, now: now) == nil)
        #expect(RetryAfter.parse("garbage", now: now) == nil)
    }

    @Test func providerNames() {
        #expect(Provider.cursor.displayName == "Cursor")
        #expect(Provider.allCases.map(\.statusName) == ["Claude", "OpenAI", "Cursor"])
    }
}

@Suite struct WorstWindowTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func scopedTighterWindowWinsAndKeepsLabel() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 29, resetsAt: nil),
            weekly: RateWindow(usedPercent: 71, resetsAt: nil),
            scopedWeekly: [RateWindow(usedPercent: 81, resetsAt: nil, label: "Fable")],
            fetchedAt: now)
        #expect(snap.worstWeekly?.usedPercent == 81)
        #expect(snap.worstWeekly?.label == "Fable")
        #expect(snap.worstSession?.usedPercent == 29)
    }

    @Test func unscopedWindowWinsTies() {
        let snap = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 50, resetsAt: nil),
            scopedWeekly: [RateWindow(usedPercent: 50, resetsAt: nil, label: "Fable")],
            fetchedAt: now)
        #expect(snap.worstWeekly?.label == nil)
    }

    @Test func emptyScopedArraysFallBackToUnscoped() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 12, resetsAt: nil),
            weekly: nil,
            fetchedAt: now)
        #expect(snap.worstSession?.usedPercent == 12)
        #expect(snap.worstWeekly == nil)
    }

    @Test func scopedWindowAloneWins() {
        let snap = UsageSnapshot(
            session: nil,
            weekly: nil,
            scopedSession: [RateWindow(usedPercent: 5, resetsAt: nil, label: "Spark")],
            fetchedAt: now)
        #expect(snap.worstSession?.label == "Spark")
    }

    @Test func worstOfMultipleScopedWindowsIsSelected() {
        let snap = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 40, resetsAt: nil),
            scopedWeekly: [
                RateWindow(usedPercent: 55, resetsAt: nil, label: "Opus"),
                RateWindow(usedPercent: 62, resetsAt: nil, label: "Sonnet"),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_751_500_000))
        #expect(snap.worstWeekly?.usedPercent == 62)
        #expect(snap.worstWeekly?.label == "Sonnet")
    }
}
