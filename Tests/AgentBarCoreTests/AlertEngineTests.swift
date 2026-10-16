import Foundation
import Testing
@testable import AgentBarCore

private func account(_ label: String, provider: Provider = .claude) -> Account {
    Account(provider: provider, path: "/Users/x/.\(provider.rawValue)-\(label)", label: label, hidden: false)
}

private func ok(_ percent: Double, resetsAt: Date?) -> AccountState {
    .ok(UsageSnapshot(session: RateWindow(usedPercent: percent, resetsAt: resetsAt),
                      weekly: nil, fetchedAt: Date(timeIntervalSince1970: 0)))
}

@Suite struct AlertEngineTests {
    let now = ISO8601.parse("2026-07-03T10:00:00Z")!
    var reset: Date { now.addingTimeInterval(7200) }

    @Test func firesOnceAboveThresholdAndNamesHeadroom() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [
            (account("work"), ok(82, resetsAt: reset)),
            (account("personal"), ok(12, resetsAt: reset)),
        ]
        let events = engine.evaluate(rows, now: now)
        #expect(events.count == 1)
        #expect(events[0].accountID == rows[0].account.id)
        #expect(events[0].body.contains("personal"))   // headroom suggestion
        #expect(events[0].title.contains("82"))

        // Same window: no refire.
        #expect(engine.evaluate(rows, now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func refiresAfterWindowReset() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows1: [(account: Account, state: AccountState)] = [(account("work"), ok(85, resetsAt: reset))]
        #expect(engine.evaluate(rows1, now: now).count == 1)

        // New window (later resetsAt), still above threshold -> refire.
        let laterReset = reset.addingTimeInterval(18000)
        let rows2: [(account: Account, state: AccountState)] = [(account("work"), ok(81, resetsAt: laterReset))]
        #expect(engine.evaluate(rows2, now: reset.addingTimeInterval(60)).count == 1)
    }

    @Test func belowThresholdNeverFires() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [(account("work"), ok(79.9, resetsAt: reset))]
        #expect(engine.evaluate(rows, now: now).isEmpty)
    }

    @Test func headroomOnlyConsidersSameProvider() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [
            (account("work", provider: .claude), ok(90, resetsAt: reset)),
            (account("default", provider: .codex), ok(5, resetsAt: reset)),
        ]
        let events = engine.evaluate(rows, now: now)
        #expect(events.count == 1)
        #expect(!events[0].body.contains("default"))
    }

    @Test func titleNamesProvider() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [
            (account("personal", provider: .claude), ok(86, resetsAt: reset)),
            (account("personal", provider: .codex), ok(91, resetsAt: reset)),
        ]
        let events = engine.evaluate(rows, now: now)
        #expect(events.count == 2)
        #expect(events[0].title == "Claude · personal is at 86% of its 5h limit")
        #expect(events[1].title == "Codex · personal is at 91% of its 5h limit")
    }

    @Test func nonOKStatesIgnored() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [
            (account("work"), .error("boom")), (account("personal"), .stale("expired")),
        ]
        #expect(engine.evaluate(rows, now: now).isEmpty)
    }
}

@Suite struct ScopedAlertTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)
    let account = Account(provider: .codex, path: "/Users/x/.codex", label: "kan", hidden: false)

    @Test func scopedSessionWindowFiresAndIsNamed() {
        var engine = AlertEngine(thresholdPercent: 80)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil),
            weekly: nil,
            scopedSession: [RateWindow(
                usedPercent: 95, resetsAt: now.addingTimeInterval(3600),
                label: "GPT-5.3-Codex-Spark")],
            fetchedAt: now)
        let events = engine.evaluate([(account: account, state: .ok(snap))], now: now)
        #expect(events.count == 1)
        #expect(events[0].title == "Codex · kan is at 95% of its GPT-5.3-Codex-Spark 5h limit")
    }

    @Test func unscopedTitleIsUnchanged() {
        var engine = AlertEngine(thresholdPercent: 80)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 92, resetsAt: nil), weekly: nil, fetchedAt: now)
        let events = engine.evaluate([(account: account, state: .ok(snap))], now: now)
        #expect(events[0].title == "Codex · kan is at 92% of its 5h limit")
    }
}

@Suite struct WeeklyAlertTests {
    let now = ISO8601.parse("2026-07-03T10:00:00Z")!
    var sessionReset: Date { now.addingTimeInterval(7200) }
    var weeklyReset: Date { now.addingTimeInterval(3 * 86400) }

    private func account(_ label: String, provider: Provider = .claude) -> Account {
        Account(provider: provider, path: "/Users/x/.\(provider.rawValue)-\(label)", label: label, hidden: false)
    }

    @Test func weeklyCrossingFiresOnceAndNamesDuration() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: sessionReset),
            weekly: RateWindow(usedPercent: 92, resetsAt: weeklyReset),
            fetchedAt: now)
        let rows: [(account: Account, state: AccountState)] = [(account("work"), .ok(snap))]
        let events = engine.evaluate(rows, now: now)
        #expect(events.count == 1)
        #expect(events[0].title == "Claude · work is at 92% of its weekly limit")
        // Same window: no refire.
        #expect(engine.evaluate(rows, now: now.addingTimeInterval(60)).isEmpty)
    }

    @Test func weeklyBelowThresholdDoesNotFire() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: sessionReset),
            weekly: RateWindow(usedPercent: 89.9, resetsAt: weeklyReset),
            fetchedAt: now)
        #expect(engine.evaluate([(account("work"), .ok(snap))], now: now).isEmpty)
    }

    @Test func sessionAndWeeklyFireIndependentlyForSameAccount() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 85, resetsAt: sessionReset),
            weekly: RateWindow(usedPercent: 95, resetsAt: weeklyReset),
            fetchedAt: now)
        let events = engine.evaluate([(account("work"), .ok(snap))], now: now)
        #expect(events.count == 2)
        #expect(events.contains { $0.title == "Claude · work is at 85% of its 5h limit" })
        #expect(events.contains { $0.title == "Claude · work is at 95% of its weekly limit" })
    }

    @Test func weeklyBodyNamesSiblingWithMostWeeklyHeadroom() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let hot = UsageSnapshot(
            session: RateWindow(usedPercent: 5, resetsAt: sessionReset),
            weekly: RateWindow(usedPercent: 93, resetsAt: weeklyReset), fetchedAt: now)
        let cool = UsageSnapshot(
            session: RateWindow(usedPercent: 5, resetsAt: sessionReset),
            weekly: RateWindow(usedPercent: 20, resetsAt: weeklyReset), fetchedAt: now)
        let rows: [(account: Account, state: AccountState)] = [
            (account("work"), .ok(hot)), (account("personal"), .ok(cool)),
        ]
        let events = engine.evaluate(rows, now: now)
        #expect(events.count == 1)
        #expect(events[0].body.contains("personal"))
        #expect(events[0].body.contains("20%"))
    }

    @Test func scopedWeeklyWindowIsNamed() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 5, resetsAt: sessionReset),
            weekly: nil,
            scopedWeekly: [RateWindow(usedPercent: 96, resetsAt: weeklyReset, label: "Fable")],
            fetchedAt: now)
        let events = engine.evaluate([(account("kan", provider: .codex), .ok(snap))], now: now)
        #expect(events.count == 1)
        #expect(events[0].title == "Codex · kan is at 96% of its Fable weekly limit")
    }
}

@Suite struct ResetClearTests {
    let now = ISO8601.parse("2026-07-03T10:00:00Z")!
    var reset: Date { now.addingTimeInterval(7200) }

    private func account(_ label: String, provider: Provider = .claude) -> Account {
        Account(provider: provider, path: "/Users/x/.\(provider.rawValue)-\(label)", label: label, hidden: false)
    }
    private func sessionSnap(_ percent: Double, resetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(session: RateWindow(usedPercent: percent, resetsAt: resetsAt), weekly: nil, fetchedAt: now)
    }

    @Test func firesOnceAfterRealResetWhenAccountIsClear() {
        var engine = AlertEngine(thresholdPercent: 80)
        let rows: [(account: Account, state: AccountState)] = [(account("work"), .ok(sessionSnap(85, resetsAt: reset)))]
        #expect(engine.evaluate(rows, now: now).count == 1)   // limit alert

        // After the reset time, account is now in a fresh, low window.
        let after = reset.addingTimeInterval(60)
        let clearRows: [(account: Account, state: AccountState)] =
            [(account("work"), .ok(sessionSnap(3, resetsAt: after.addingTimeInterval(18000))))]
        let events = engine.evaluate(clearRows, now: after)
        #expect(events.count == 1)
        #expect(events[0].title == "Claude · work — 5h limit reset")
        #expect(events[0].body == "You're clear.")
        // Never again.
        #expect(engine.evaluate(clearRows, now: after.addingTimeInterval(60)).isEmpty)
    }

    @Test func noResetClearWhenFiredWindowHadNoResetDate() {
        var engine = AlertEngine(thresholdPercent: 80)
        // Alert fires on a window with nil resetsAt (fallback prune at now+5h).
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(90, resetsAt: nil)))], now: now).count == 1)
        // Past the synthetic 5h fallback, account clear -> still no "you're clear".
        let after = now.addingTimeInterval(5 * 3600 + 60)
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(2, resetsAt: nil)))], now: after).isEmpty)
    }

    @Test func noResetClearWhenAccountErroredAtResetTime() {
        var engine = AlertEngine(thresholdPercent: 80)
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(88, resetsAt: reset)))], now: now).count == 1)
        let after = reset.addingTimeInterval(60)
        #expect(engine.evaluate([(account("work"), .error("boom"))], now: after).isEmpty)
    }

    @Test func noResetClearWhenAccountStaleAtResetTime() {
        var engine = AlertEngine(thresholdPercent: 80)
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(88, resetsAt: reset)))], now: now).count == 1)
        let after = reset.addingTimeInterval(60)
        #expect(engine.evaluate([(account("work"), .stale("expired"))], now: after).isEmpty)
    }

    @Test func noResetClearWhenAccountAbsentAtResetTime() {
        var engine = AlertEngine(thresholdPercent: 80)
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(88, resetsAt: reset)))], now: now).count == 1)
        let after = reset.addingTimeInterval(60)
        #expect(engine.evaluate([], now: after).isEmpty)
    }

    @Test func noResetClearWhenStillAboveThresholdInNewWindow() {
        var engine = AlertEngine(thresholdPercent: 80)
        #expect(engine.evaluate([(account("work"), .ok(sessionSnap(88, resetsAt: reset)))], now: now).count == 1)
        // New window already hot again: a fresh limit alert fires, but no "clear".
        let after = reset.addingTimeInterval(60)
        let hotRows: [(account: Account, state: AccountState)] =
            [(account("work"), .ok(sessionSnap(91, resetsAt: after.addingTimeInterval(18000))))]
        let events = engine.evaluate(hotRows, now: after)
        #expect(events.count == 1)
        #expect(events[0].title == "Claude · work is at 91% of its 5h limit")
    }

    @Test func weeklyResetAlsoClears() {
        var engine = AlertEngine(thresholdPercent: 80, weeklyThresholdPercent: 90)
        let weeklyReset = now.addingTimeInterval(3 * 86400)
        let hot = UsageSnapshot(session: RateWindow(usedPercent: 5, resetsAt: nil),
                                weekly: RateWindow(usedPercent: 95, resetsAt: weeklyReset), fetchedAt: now)
        #expect(engine.evaluate([(account("work"), .ok(hot))], now: now).count == 1)
        let after = weeklyReset.addingTimeInterval(60)
        let cleared = UsageSnapshot(session: RateWindow(usedPercent: 5, resetsAt: nil),
                                    weekly: RateWindow(usedPercent: 4, resetsAt: after.addingTimeInterval(86400)),
                                    fetchedAt: now)
        let events = engine.evaluate([(account("work"), .ok(cleared))], now: after)
        #expect(events.count == 1)
        #expect(events[0].title == "Claude · work — weekly limit reset")
    }
}

@Suite struct AlertEnginePeriodLabelTests {
    let now = Date(timeIntervalSince1970: 1_751_600_000)

    private func cursorAccount() -> Account {
        Account(provider: .cursor, path: "/tmp/cursor", label: "Cursor", hidden: false)
    }

    @Test func thresholdAlertNamesThePeriod() {
        var engine = AlertEngine(thresholdPercent: 80)
        let cycle = RateWindow(usedPercent: 85, resetsAt: now.addingTimeInterval(20 * 86400), periodLabel: "mo")
        let events = engine.evaluate(
            [(cursorAccount(), .ok(UsageSnapshot(session: cycle, weekly: nil, fetchedAt: now)))], now: now)
        #expect(events.count == 1)
        #expect(events.first?.title == "Cursor is at 85% of its mo limit")
    }

    @Test func resetAlertNamesThePeriod() {
        var engine = AlertEngine(thresholdPercent: 80)
        let reset = now.addingTimeInterval(60)
        let hot = RateWindow(usedPercent: 85, resetsAt: reset, periodLabel: "mo")
        _ = engine.evaluate([(cursorAccount(), .ok(UsageSnapshot(session: hot, weekly: nil, fetchedAt: now)))], now: now)
        let later = now.addingTimeInterval(120)
        let clear = RateWindow(usedPercent: 1, resetsAt: later.addingTimeInterval(30 * 86400), periodLabel: "mo")
        let events = engine.evaluate(
            [(cursorAccount(), .ok(UsageSnapshot(session: clear, weekly: nil, fetchedAt: later)))], now: later)
        #expect(events.count == 1)
        #expect(events.first?.title == "Cursor — mo limit reset")
    }
}
