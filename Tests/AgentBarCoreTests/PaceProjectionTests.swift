import Foundation
import Testing
@testable import AgentBarCore

@Suite struct PaceProjectionTests {
    let now = Date(timeIntervalSince1970: 1_751_600_000)

    @Test func elapsedIsZeroAtWindowStart() {
        let resets = now.addingTimeInterval(WindowKind.session.duration)
        #expect(PaceProjection.elapsedFraction(resetsAt: resets, now: now, kind: .session) == 0)
    }

    @Test func elapsedIsHalfMidWindow() {
        let resets = now.addingTimeInterval(WindowKind.session.duration / 2)
        #expect(PaceProjection.elapsedFraction(resetsAt: resets, now: now, kind: .session) == 0.5)
    }

    @Test func elapsedClampsToOneWhenResetIsNow() {
        #expect(PaceProjection.elapsedFraction(resetsAt: now, now: now, kind: .session) == 1)
    }

    @Test func elapsedClampsToOneWhenResetIsInThePast() {
        let resets = now.addingTimeInterval(-600)
        #expect(PaceProjection.elapsedFraction(resetsAt: resets, now: now, kind: .session) == 1)
    }

    @Test func elapsedClampsToZeroWhenResetBeyondWindow() {
        let resets = now.addingTimeInterval(WindowKind.weekly.duration * 2)
        #expect(PaceProjection.elapsedFraction(resetsAt: resets, now: now, kind: .weekly) == 0)
    }

    @Test func elapsedIsNilWithoutReset() {
        #expect(PaceProjection.elapsedFraction(resetsAt: nil, now: now, kind: .session) == nil)
    }

    @Test func overPaceProjectsFiniteEmptyDate() throws {
        // Half the window elapsed (2.5h consumed 75%): the remaining 25%
        // lasts 9000s * 0.25/0.75 = 3000s.
        let resets = now.addingTimeInterval(WindowKind.session.duration / 2)
        let empty = try #require(
            PaceProjection.emptyAt(usedPercent: 75, resetsAt: resets, now: now, kind: .session))
        #expect(abs(empty.timeIntervalSince(now) - 3000) < 0.001)
    }

    @Test func underPaceSuppressesETA() {
        let resets = now.addingTimeInterval(WindowKind.session.duration / 2)
        #expect(PaceProjection.emptyAt(usedPercent: 30, resetsAt: resets, now: now, kind: .session) == nil)
    }

    @Test func zeroBurnSuppressesETA() {
        #expect(PaceProjection.emptyAt(usedPercent: 0, resetsAt: now, now: now, kind: .session) == nil)
    }

    @Test func nilResetSuppressesETA() {
        #expect(PaceProjection.emptyAt(usedPercent: 90, resetsAt: nil, now: now, kind: .session) == nil)
    }

    @Test func etaNeverExceedsTheWindowReset() throws {
        // Barely over pace is the worst case for the linear projection —
        // the absurd-ETA cap must keep the projection at or before reset.
        let resets = now.addingTimeInterval(WindowKind.weekly.duration * 0.1) // elapsed 0.9
        let empty = try #require(
            PaceProjection.emptyAt(usedPercent: 91, resetsAt: resets, now: now, kind: .weekly))
        #expect(empty <= resets)
    }

    @Test func startsAtSetsWindowLengthForMonthlyCycle() {
        let start = now.addingTimeInterval(-10 * 86400)
        let reset = now.addingTimeInterval(21 * 86400) // 31-day cycle, 10 days in
        let elapsed = PaceProjection.elapsedFraction(resetsAt: reset, startsAt: start, now: now, kind: .session)
        #expect(abs((elapsed ?? -1) - 10.0 / 31.0) < 1e-9)
    }

    @Test func startsAtDrivesEmptyAtProjection() {
        let start = now.addingTimeInterval(-10 * 86400)
        let reset = now.addingTimeInterval(20 * 86400) // 30-day cycle, 1/3 elapsed
        // 50% used at 1/3 elapsed: 10 days burned 50%, so the rest empties in 10 days.
        let full = PaceProjection.emptyAt(usedPercent: 50, resetsAt: reset, startsAt: start, now: now, kind: .session)
        #expect(full.map { abs($0.timeIntervalSince(now) - 10 * 86400) < 1 } == true)
    }

    @Test func startsAtNotBeforeResetFallsBackToKindDuration() {
        let reset = now.addingTimeInterval(WindowKind.session.duration / 2)
        let bad = PaceProjection.elapsedFraction(resetsAt: reset, startsAt: reset, now: now, kind: .session)
        let plain = PaceProjection.elapsedFraction(resetsAt: reset, now: now, kind: .session)
        #expect(bad == plain)
        #expect(bad == 0.5)
    }

    @Test func nilStartsAtKeepsExistingWeeklyMath() {
        let reset = now.addingTimeInterval(WindowKind.weekly.duration / 4)
        #expect(PaceProjection.elapsedFraction(resetsAt: reset, startsAt: nil, now: now, kind: .weekly) == 0.75)
    }
}
