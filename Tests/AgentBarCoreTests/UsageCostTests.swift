import Foundation
import Testing
@testable import AgentBarCore

@Suite struct UsageCostTests {
    @Test func zeroIsZero() {
        #expect(UsageCost.zero.isZero)
        #expect(!UsageCost(today: 0.01, thirtyDay: 0).isZero)
        #expect(!UsageCost(today: 0, thirtyDay: 0.01).isZero)
    }

    @Test func additionSumsBothBuckets() {
        let sum = UsageCost(today: 1.5, thirtyDay: 10) + UsageCost(today: 0.5, thirtyDay: 20)
        #expect(sum == UsageCost(today: 2.0, thirtyDay: 30))
    }

    @Test func reduceSumsAcrossAccounts() {
        // The shape UsageStore.totalCost uses: sum of per-account costs.
        let costs = [
            UsageCost(today: 1, thirtyDay: 10),
            UsageCost(today: 2, thirtyDay: 20),
            UsageCost.zero,
        ]
        #expect(costs.reduce(.zero, +) == UsageCost(today: 3, thirtyDay: 30))
    }

    @Test func plusMergesDailyByDay() {
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let other = Date(timeIntervalSinceReferenceDate: 86_400)
        let a = UsageCost(today: 1, thirtyDay: 2, daily: [day: 1.5])
        let b = UsageCost(today: 3, thirtyDay: 4, daily: [day: 0.5, other: 2])
        #expect((a + b).daily == [day: 2.0, other: 2.0])
    }

    @Test func zeroHasEmptyDaily() {
        #expect(UsageCost.zero.daily.isEmpty)
    }
}
