import Foundation
import Testing
@testable import AgentBarCore

@Suite struct RowPresentationTests {
    @Test func orderedPutsPinnedFirstInItsGroupAndRespectsOrder() {
        func acct(_ p: Provider, _ path: String) -> Account {
            Account(provider: p, path: path, label: (path as NSString).lastPathComponent, hidden: false)
        }
        let a = acct(.claude, "/a"), b = acct(.claude, "/b"), c = acct(.claude, "/c")
        let x = acct(.codex, "/x")
        let result = RowPresentation.ordered(
            [a, b, c, x], order: [c.id, a.id, b.id], pinned: b.id)
        #expect(result.map(\.id) == [b.id, c.id, a.id, x.id]) // pinned first, then saved order
    }

    @Test func orderedAppendsUnknownAccountsInGivenOrder() {
        func acct(_ path: String) -> Account {
            Account(provider: .claude, path: path, label: path, hidden: false)
        }
        let a = acct("/a"), b = acct("/b"), new = acct("/new")
        let result = RowPresentation.ordered([new, a, b], order: [b.id, a.id], pinned: nil)
        #expect(result.map(\.id) == [b.id, a.id, new.id])
    }

    @Test func orderedToleratesDuplicateIDsInSavedOrder() {
        func acct(_ path: String) -> Account {
            Account(provider: .claude, path: path, label: path, hidden: false)
        }
        let a = acct("/a"), b = acct("/b")
        let result = RowPresentation.ordered([a, b], order: [b.id, a.id, b.id], pinned: nil)
        #expect(result.map(\.id) == [b.id, a.id]) // first occurrence wins, no crash
    }

    @Test func iconStateNormalUsesPinnedAccount() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 7, resetsAt: nil),
            weekly: RateWindow(usedPercent: 14, resetsAt: nil), fetchedAt: Date())
        let other = UsageSnapshot(
            session: RateWindow(usedPercent: 90, resetsAt: nil), weekly: nil, fetchedAt: Date())
        let state = IconStateBuilder.build(
            states: [("pin", .ok(snap)), ("hot", .ok(other))], pinnedID: "pin")
        #expect(state == .normal(percent: 7, tint: .normal))
    }

    @Test func iconStateFallsBackToWorstWhenPinnedErrored() {
        let hot = UsageSnapshot(
            session: RateWindow(usedPercent: 90, resetsAt: nil), weekly: nil, fetchedAt: Date())
        let state = IconStateBuilder.build(
            states: [("pin", .error("x")), ("hot", .ok(hot))], pinnedID: "pin")
        #expect(state == .normal(percent: 90, tint: .critical))
    }

    @Test func iconStateFallsBackToWorstWhenPinnedAbsent() {
        let hot = UsageSnapshot(
            session: RateWindow(usedPercent: 90, resetsAt: nil), weekly: nil, fetchedAt: Date())
        let state = IconStateBuilder.build(states: [("a", .ok(hot))], pinnedID: "gone")
        #expect(state == .normal(percent: 90, tint: .critical))
    }

    @Test func iconStateAllErrored() {
        let state = IconStateBuilder.build(
            states: [("a", .error("x")), ("b", .stale("y"))], pinnedID: nil)
        #expect(state == .allErrored)
    }

    @Test func iconStateNoAccounts() {
        #expect(IconStateBuilder.build(states: [], pinnedID: nil) == .noAccounts)
    }

    @Test func signedOutAndHiddenRowsAreNotShown() {
        let cursor = Account(provider: .cursor, path: "/tmp/cursor", label: "Cursor", hidden: false)
        var hidden = cursor
        hidden.hidden = true
        #expect(!RowPresentation.isShown(cursor, state: .signedOut))
        #expect(!RowPresentation.isShown(hidden, state: .loading))
        #expect(RowPresentation.isShown(cursor, state: .loading))
        #expect(RowPresentation.isShown(cursor, state: .error("Cursor login unreadable — sign in to Cursor again")))
    }

    @Test func iconStateLoadingIsNotErrored() {
        let state = IconStateBuilder.build(states: [("a", .loading)], pinnedID: nil)
        #expect(state == .normal(percent: 0, tint: .normal))
    }

    @Test func persistedOrderWithoutPinIsVisualOrder() {
        #expect(RowPresentation.persistedOrder(
            visual: ["a", "b", "c"], pinned: nil, previousOrder: ["c", "a"]) == ["a", "b", "c"])
    }

    @Test func persistedOrderKeepsPinnedAtPreviousPosition() {
        // Visual order has the pin lifted to front; saved order keeps it at
        // its old slot (index 1) instead of baking the lift.
        #expect(RowPresentation.persistedOrder(
            visual: ["p", "b", "a"], pinned: "p", previousOrder: ["a", "p", "b"]) == ["b", "p", "a"])
    }

    @Test func persistedOrderOmitsPinnedNeverOrdered() {
        #expect(RowPresentation.persistedOrder(
            visual: ["p", "b", "a"], pinned: "p", previousOrder: ["b", "a"]) == ["b", "a"])
    }

    @Test func persistedOrderClampsStalePreviousIndex() {
        // Previous order may be stale/hand-edited: pinned sat at index 3 but
        // only 1 other row remains — insert clamps to the end, no crash.
        #expect(RowPresentation.persistedOrder(
            visual: ["p", "a"], pinned: "p", previousOrder: ["x", "y", "z", "p"]) == ["a", "p"])
    }
}

@Suite struct ScopedIconTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func pinnedIconTintReflectsScopedWeekly() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 29, resetsAt: nil),
            weekly: RateWindow(usedPercent: 71, resetsAt: nil),
            scopedWeekly: [RateWindow(usedPercent: 81, resetsAt: nil, label: "Fable")],
            fetchedAt: now)
        let state = IconStateBuilder.build(states: [("a", .ok(snap))], pinnedID: "a")
        #expect(state == .normal(percent: 29, tint: .warning))
    }

    @Test func worstSessionPercentUsesScopedWindows() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil),
            weekly: nil,
            scopedSession: [RateWindow(usedPercent: 95, resetsAt: nil, label: "Spark")],
            fetchedAt: now)
        #expect(Aggregation.worstSessionPercent([.ok(snap)]) == 95)
    }
}

@Suite struct HoverReadoutTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)
    /// Zero marks keep these cases about the pace math itself; the gate on
    /// projected-full lines has its own tests below.
    let ungated = AlertsConfig(sessionThresholdPercent: 0, weeklyThresholdPercent: 0)

    private func pairs(_ lines: [ReadoutLine]) -> [[String]] {
        lines.map { [$0.label, $0.value] }
    }

    @Test func underPaceWindowsShowResets() {
        // Session 44% with 36m left of a 5h window: elapsed 0.88 > fill 0.44.
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 44, resetsAt: now.addingTimeInterval(2160)),
            weekly: RateWindow(usedPercent: 21, resetsAt: nil),
            fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["5h", "44% · resets 36m"], ["wk", "21%"],
                ["pace", "under — clear past reset"]])
    }

    @Test func overPaceSessionShowsFullETA() throws {
        // Half the window elapsed, 75% burned -> over pace, ETA under 24h ("in").
        let resets = now.addingTimeInterval(WindowKind.session.duration / 2)
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 75, resetsAt: resets), weekly: nil, fetchedAt: now)
        let full = try #require(
            PaceProjection.emptyAt(usedPercent: 75, resetsAt: resets, now: now, kind: .session))
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["5h", "75% · full in \(Aggregation.countdown(to: full, from: now))"
                + " · resets \(Aggregation.countdown(to: resets, from: now))"]])
    }

    @Test func weeklyPaceUsesWeeklyWindowDuration() throws {
        // 90% burned one day into the week (elapsed ~0.143) -> over pace, ETA under 24h.
        let resets = now.addingTimeInterval(6 * 86_400)
        let snap = UsageSnapshot(
            session: nil, weekly: RateWindow(usedPercent: 90, resetsAt: resets), fetchedAt: now)
        let full = try #require(
            PaceProjection.emptyAt(usedPercent: 90, resetsAt: resets, now: now, kind: .weekly))
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["wk", "90% · full in \(Aggregation.countdown(to: full, from: now))"
                + " · resets \(Aggregation.countdown(to: resets, from: now))"]])
    }

    @Test func farOutETAUsesByWithDayName() throws {
        // 25% burned one day into the week -> over pace, ETA ~3 days out ("by Mon").
        let resets = now.addingTimeInterval(6 * 86_400)
        let snap = UsageSnapshot(
            session: nil, weekly: RateWindow(usedPercent: 25, resetsAt: resets), fetchedAt: now)
        let full = try #require(
            PaceProjection.emptyAt(usedPercent: 25, resetsAt: resets, now: now, kind: .weekly))
        #expect(full.timeIntervalSince(now) >= 24 * 3600) // day-name form -> "by"
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["wk", "25% · full by \(Aggregation.countdown(to: full, from: now))"
                + " · resets \(Aggregation.countdown(to: resets, from: now))"]])
    }

    @Test func scopedSessionListedAlongsideUnscoped() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil), weekly: nil,
            scopedSession: [RateWindow(usedPercent: 40, resetsAt: nil, label: "Spark")],
            fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["5h", "10%"], ["Spark 5h", "40%"]])
    }

    @Test func lowerScopedWeeklyStillShownAlongsideGeneral() {
        let snap = UsageSnapshot(
            session: nil, weekly: RateWindow(usedPercent: 15, resetsAt: nil),
            scopedWeekly: [RateWindow(usedPercent: 8, resetsAt: nil, label: "Fable")],
            fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now))
            == [["wk", "15%"], ["Fable wk", "8%"]])
    }

    @Test func costLineAppendedWhenPresent() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil), weekly: nil, fetchedAt: now)
        let lines = RowPresentation.hoverReadout(
            snap, cost: UsageCost(today: 4.2, thirtyDay: 61.53), alerts: ungated, now: now)
        #expect(pairs(lines) == [["5h", "10%"], ["cost", "$4.20 today · $61.53/mo"]])
    }

    @Test func costLineOmittedWhenZeroOrAbsent() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil), weekly: nil, fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: .zero, alerts: ungated, now: now)) == [["5h", "10%"]])
        #expect(pairs(RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now)) == [["5h", "10%"]])
    }

    @Test func spendSummaryAppendsAsFinalLine() {
        // Preserves the old caption's spend/overage surface: it appears only
        // when present, after the cost line.
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil), weekly: nil,
            spendSummary: "extra $1.23 of $10.00", fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(
            snap, cost: UsageCost(today: 4.2, thirtyDay: 61.53), alerts: ungated, now: now))
            == [["5h", "10%"], ["cost", "$4.20 today · $61.53/mo"], ["spend", "extra $1.23 of $10.00"]])
    }

    @Test func largeDollarAmountsDropCents() {
        #expect(RowPresentation.costLine(UsageCost(today: 4.2, thirtyDay: 123.4))
            == "$4.20 today · $123/mo")
    }

    @Test func footerLineIsLabelledAsAPIRates() {
        #expect(RowPresentation.footerCostLine(UsageCost(today: 1, thirtyDay: 30))
            == "$1.00 today · $30.00/mo · API rates")
        #expect(RowPresentation.footerCostLine(.zero) == nil)
    }

    @Test func paceLineOmittedWhenOverPaceOrUnresettable() {
        // Over pace: the 5h line already says "full in X" — no pace line.
        let resets = now.addingTimeInterval(WindowKind.session.duration / 2)
        let over = UsageSnapshot(
            session: RateWindow(usedPercent: 75, resetsAt: resets), weekly: nil, fetchedAt: now)
        #expect(!RowPresentation.hoverReadout(over, cost: nil, alerts: ungated, now: now)
            .contains { $0.label == "pace" })
        // No reset date: no pace math possible, no line.
        let dateless = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: nil), weekly: nil, fetchedAt: now)
        #expect(!RowPresentation.hoverReadout(dateless, cost: nil, alerts: ungated, now: now)
            .contains { $0.label == "pace" })
    }

    @Test func paceLineSuppressedByAnyOverPaceSessionWindow() {
        // Unscoped 44% at 0.88 elapsed is under pace and is the worst window,
        // but the scoped Fable window — 30% burned only 0.1 into its window —
        // is over pace and prints "full in X". No "under" verdict beside it.
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 44, resetsAt: now.addingTimeInterval(2160)),
            weekly: nil,
            scopedSession: [RateWindow(
                usedPercent: 30,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration * 0.9),
                label: "Fable")],
            fetchedAt: now)
        #expect(!RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now)
            .contains { $0.label == "pace" })
        // A dateless scoped window can't be judged — no verdict either.
        let unjudgeable = UsageSnapshot(
            session: RateWindow(usedPercent: 44, resetsAt: now.addingTimeInterval(2160)),
            weekly: nil,
            scopedSession: [RateWindow(usedPercent: 10, resetsAt: nil, label: "Fable")],
            fetchedAt: now)
        #expect(!RowPresentation.hoverReadout(unjudgeable, cost: nil, alerts: ungated, now: now)
            .contains { $0.label == "pace" })
    }

    @Test func paceLineSitsAfterWindowsBeforeCost() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(4 * 3600)),
            weekly: nil, fetchedAt: now)
        #expect(pairs(RowPresentation.hoverReadout(
            snap, cost: UsageCost(today: 4.2, thirtyDay: 61.53), alerts: ungated, now: now))
            == [["5h", "10% · resets 4h00m"], ["pace", "under — clear past reset"],
                ["cost", "$4.20 today · $61.53/mo"]])
    }

    @Test func hoverReadoutUsesPeriodLabelWhenSet() {
        let cycle = RateWindow(usedPercent: 42, resetsAt: now.addingTimeInterval(20 * 86400),
                               startsAt: now.addingTimeInterval(-10 * 86400), periodLabel: "mo")
        let snap = UsageSnapshot(session: cycle, weekly: nil, fetchedAt: now)
        let lines = RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now)
        #expect(lines.first?.label == "mo")
        #expect(!lines.contains { $0.label == "5h" })
    }

    @Test func hoverReadoutKeepsSlotUnitsWithoutPeriodLabel() {
        let snap = UsageSnapshot(
            session: RateWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(3600)),
            weekly: RateWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(86400)),
            fetchedAt: now)
        let labels = RowPresentation.hoverReadout(snap, cost: nil, alerts: ungated, now: now).map(\.label)
        #expect(labels.prefix(2) == ["5h", "wk"])
    }
}

@Suite struct HoverReadoutGateTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    /// The card obeys the row's rule: below the warning mark a window reports
    /// its level and reset, never a projected full.
    @Test func fullETAOnlyAppearsPastTheWarningMark() {
        let snap = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 19, resetsAt: now.addingTimeInterval(496_800)),
            fetchedAt: now)
        let quiet = RowPresentation.hoverReadout(snap, cost: nil, alerts: AlertsConfig(), now: now)
        #expect(quiet.allSatisfy { !$0.value.contains("full") })

        let hot = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(496_800)),
            fetchedAt: now)
        #expect(RowPresentation.hoverReadout(hot, cost: nil, alerts: AlertsConfig(), now: now)
            .contains { $0.value.contains("full") })
    }
}

@Suite struct HistorySeriesTests {
    let calendar = Calendar.current
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func dailyCostSeriesAligns30SlotsWithTodayLast() {
        let today = calendar.startOfDay(for: now)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let cost = UsageCost(today: 1, thirtyDay: 4, daily: [today: 1.0, twoDaysAgo: 3.0])
        let series = RowPresentation.dailyCostSeries(cost, now: now)
        #expect(series?.count == 30)
        #expect(series?[29] == 1.0)
        #expect(series?[27] == 3.0)
        #expect(series?[0] == 0)
    }

    @Test func dailyCostSeriesNilWhenNoData() {
        #expect(RowPresentation.dailyCostSeries(nil, now: now) == nil)
        #expect(RowPresentation.dailyCostSeries(UsageCost.zero, now: now) == nil)
        let allZero = UsageCost(today: 0, thirtyDay: 0, daily: [calendar.startOfDay(for: now): 0])
        #expect(RowPresentation.dailyCostSeries(allZero, now: now) == nil)
    }

    @Test func weeklySeriesNeedsTwoPoints() {
        let one = [HistoryEntry(hour: now, session: 10, weekly: 50)]
        #expect(RowPresentation.weeklySeries(one) == nil)
        let sessionOnly = [
            HistoryEntry(hour: now, session: 10, weekly: nil),
            HistoryEntry(hour: now.addingTimeInterval(3_600), session: 20, weekly: nil),
        ]
        #expect(RowPresentation.weeklySeries(sessionOnly) == nil)
        let two = one + [HistoryEntry(hour: now.addingTimeInterval(3_600), session: nil, weekly: 60)]
        #expect(RowPresentation.weeklySeries(two) == [50, 60])
    }
}

@Suite struct RowCaptionTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func resetCaptionIsHoursColonMinutes() {
        #expect(RowPresentation.resetCaption(
            resetsAt: now.addingTimeInterval(2 * 3600 + 5 * 60), now: now) == "2:05")
        #expect(RowPresentation.resetCaption(
            resetsAt: now.addingTimeInterval(48 * 60), now: now) == "0:48")
    }

    @Test func resetCaptionEdges() {
        #expect(RowPresentation.resetCaption(resetsAt: nil, now: now) == nil)
        #expect(RowPresentation.resetCaption(
            resetsAt: now.addingTimeInterval(-60), now: now) == "now")
        #expect(RowPresentation.resetCaption(
            resetsAt: now.addingTimeInterval(25 * 3600), now: now) == nil)
    }

    @Test func rowCostCaptionShowsTodayOnly() {
        #expect(RowPresentation.rowCostCaption(UsageCost(today: 6.4, thirtyDay: 118)) == "$6.40")
        #expect(RowPresentation.rowCostCaption(UsageCost(today: 123.4, thirtyDay: 900)) == "$123")
        // Data exists but today is genuinely zero: honest $0.00, not omitted.
        #expect(RowPresentation.rowCostCaption(UsageCost(today: 0, thirtyDay: 42)) == "$0.00")
    }

    @Test func rowCostCaptionOmittedWithoutData() {
        #expect(RowPresentation.rowCostCaption(nil) == nil)
        #expect(RowPresentation.rowCostCaption(.zero) == nil)
    }
}
