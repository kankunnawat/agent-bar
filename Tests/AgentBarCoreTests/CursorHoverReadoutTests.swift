import Foundation
import Testing
@testable import AgentBarCore

@Suite struct CursorHoverReadoutTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func hoverReadoutListsCursorPoolsAndGrokWeek() {
        let end = now.addingTimeInterval(20 * 86400), start = now.addingTimeInterval(-10 * 86400)
        let snap = UsageSnapshot(
            session: nil,
            weekly: RateWindow(usedPercent: 4.7, resetsAt: now.addingTimeInterval(6 * 86400), label: "Grok"),
            scopedSession: [
                RateWindow(usedPercent: 3, resetsAt: end, label: "api", startsAt: start, periodLabel: "mo"),
                RateWindow(usedPercent: 0.13, resetsAt: end, label: "auto", startsAt: start, periodLabel: "mo"),
            ],
            fetchedAt: now)
        let lines = RowPresentation.hoverReadout(snap, cost: nil, alerts: AlertsConfig(), now: now)
        #expect(lines.prefix(3).map(\.label) == ["api mo", "auto mo", "Grok wk"])
        #expect(lines.prefix(3).map { $0.value.prefix(3) } == ["3% ", "0% ", "4% "])
    }
}
