import Foundation
import Testing
@testable import AgentBarCore

@Suite struct RiskPresentationTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)
    /// Zero marks keep these cases about the pace math and the copy; the
    /// warning-mark gate has its own tests below.
    let ungated = AlertsConfig(sessionThresholdPercent: 0, weeklyThresholdPercent: 0)

    @Test func healthyAndDatelessWindowsHaveNoCue() {
        let healthy = UsageSnapshot(
            session: RateWindow(
                usedPercent: 20,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration / 2)),
            weekly: nil,
            fetchedAt: now)
        let dateless = UsageSnapshot(
            session: RateWindow(usedPercent: 99, resetsAt: nil),
            weekly: nil,
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: healthy, alerts: ungated, now: now) == nil)
        #expect(RiskPresentation.caption(for: dateless, alerts: ungated, now: now) == nil)
    }

    @Test func sessionRiskUsesCompactFullCountdown() {
        let snapshot = UsageSnapshot(
            session: RateWindow(
                usedPercent: 75,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration / 2)),
            weekly: nil,
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: snapshot, alerts: ungated, now: now) == "FULL 0:50")
    }

    @Test func weeklyRiskNamesItsDimension() {
        let snapshot = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 25, resetsAt: now.addingTimeInterval(6 * 86_400)),
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: snapshot, alerts: ungated, now: now)?.hasPrefix("WK FULL ") == true)
    }

    @Test func alreadyFullNeedsNoResetDate() {
        let session = UsageSnapshot(
            session: RateWindow(usedPercent: 101, resetsAt: nil),
            weekly: nil,
            fetchedAt: now)
        let weekly = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 100, resetsAt: nil),
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: session, alerts: ungated, now: now) == "FULL")
        #expect(RiskPresentation.caption(for: weekly, alerts: ungated, now: now) == "WK FULL")
    }

    @Test func scopedRiskIsNotHiddenByUnderPaceWorstWindow() {
        let snapshot = UsageSnapshot(
            session: RateWindow(usedPercent: 44, resetsAt: now.addingTimeInterval(2_160)),
            weekly: nil,
            scopedSession: [RateWindow(
                usedPercent: 30,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration * 0.9),
                label: "Fable")],
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: snapshot, alerts: ungated, now: now)?.hasPrefix("FULL ") == true)
    }

    /// The reported case: a Codex weekly window one point ahead of the clock
    /// at 19% used. Loud under pace-only rules, silent under the warning mark.
    @Test func windowUnderItsWarningMarkStaysQuiet() {
        let snapshot = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 19, resetsAt: now.addingTimeInterval(496_800)),
            fetchedAt: now)
        #expect(RiskPresentation.caption(for: snapshot, alerts: ungated, now: now) != nil)
        #expect(RiskPresentation.caption(for: snapshot, alerts: AlertsConfig(), now: now) == nil)
    }

    /// Past the mark the same math still speaks — and, being past the mark,
    /// says something imminent.
    @Test func windowPastItsWarningMarkStillWarns() {
        let snapshot = UsageSnapshot(
            session: RateWindow(
                usedPercent: 85,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration / 2)),
            weekly: nil,
            fetchedAt: now)
        let caption = RiskPresentation.caption(for: snapshot, alerts: AlertsConfig(), now: now)
        #expect(caption?.hasPrefix("FULL ") == true)
    }

    /// A lowered mark is the user's own call: the cue follows the slider.
    @Test func loweredMarkRestoresTheCue() {
        let snapshot = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 19, resetsAt: now.addingTimeInterval(496_800)),
            fetchedAt: now)
        let lenient = AlertsConfig(weeklyThresholdPercent: 15)
        #expect(RiskPresentation.caption(for: snapshot, alerts: lenient, now: now)?
            .hasPrefix("WK FULL ") == true)
    }

    private func account(
        _ provider: Provider,
        _ path: String,
        hidden: Bool = false
    ) -> Account {
        Account(provider: provider, path: path, label: path, hidden: hidden)
    }

    private func snapshot(_ percent: Double, resetFraction: Double = 0.5) -> UsageSnapshot {
        UsageSnapshot(
            session: RateWindow(
                usedPercent: percent,
                resetsAt: now.addingTimeInterval(WindowKind.session.duration * resetFraction)),
            weekly: nil,
            fetchedAt: now)
    }

    @Test func lowestUsedSafeSameProviderAccountWins() {
        let work = account(.claude, "work")
        let personal = account(.claude, "personal")
        let experiment = account(.claude, "experiment")
        let codex = account(.codex, "codex")
        let rows: [(account: Account, state: AccountState)] = [
            (work, .ok(snapshot(75))),
            (personal, .ok(snapshot(20))),
            (experiment, .ok(snapshot(10))),
            (codex, .ok(snapshot(1))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: rows, alerts: ungated, now: now) == experiment.id)
    }

    @Test func hiddenAndNonOKCandidatesAreExcluded() {
        let work = account(.claude, "work")
        let hidden = account(.claude, "hidden", hidden: true)
        let stale = account(.claude, "stale")
        let error = account(.claude, "error")
        let loading = account(.claude, "loading")
        let safe = account(.claude, "safe")
        let rows: [(account: Account, state: AccountState)] = [
            (work, .ok(snapshot(75))),
            (hidden, .ok(snapshot(1))),
            (stale, .stale("old")),
            (error, .error("failed")),
            (loading, .loading),
            (safe, .ok(snapshot(25))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: rows, alerts: ungated, now: now) == safe.id)
    }

    @Test func datelessCandidateIsNotCalledSafe() {
        let work = account(.claude, "work")
        let unknown = account(.claude, "unknown")
        let rows: [(account: Account, state: AccountState)] = [
            (work, .ok(snapshot(75))),
            (unknown, .ok(UsageSnapshot(
                session: RateWindow(usedPercent: 1, resetsAt: nil),
                weekly: nil,
                fetchedAt: now))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: rows, alerts: ungated, now: now) == nil)
    }

    @Test func equalHeadroomKeepsExistingRowOrder() {
        let work = account(.claude, "work")
        let first = account(.claude, "first")
        let second = account(.claude, "second")
        let rows: [(account: Account, state: AccountState)] = [
            (work, .ok(snapshot(75))),
            (first, .ok(snapshot(20))),
            (second, .ok(snapshot(20))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: rows, alerts: ungated, now: now) == first.id)
    }

    @Test func providerIsolationCanLeaveNoAlternative() {
        let claude = account(.claude, "work")
        let codex = account(.codex, "personal")
        let rows: [(account: Account, state: AccountState)] = [
            (claude, .ok(snapshot(75))),
            (codex, .ok(snapshot(1))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: rows, alerts: ungated, now: now) == nil)
    }

    @Test func noRiskOrNoSafeAlternativeReturnsNil() {
        let first = account(.claude, "first")
        let second = account(.claude, "second")
        let healthy: [(account: Account, state: AccountState)] = [
            (first, .ok(snapshot(20))),
            (second, .ok(snapshot(10))),
        ]
        let allRisky: [(account: Account, state: AccountState)] = [
            (first, .ok(snapshot(75))),
            (second, .ok(snapshot(80))),
        ]
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: healthy, alerts: ungated, now: now) == nil)
        #expect(RiskPresentation.recommendedAlternativeID(
            for: .claude, among: allRisky, alerts: ungated, now: now) == nil)
    }
}
