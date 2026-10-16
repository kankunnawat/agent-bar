import Foundation

/// Estimated API-rate value of local usage: same local calendar day as
/// "today", the trailing 30 days, and a per-day breakdown, in USD.
public struct UsageCost: Sendable, Equatable {
    public var today: Double
    public var thirtyDay: Double
    /// USD per local calendar day (startOfDay-keyed), trailing 30 days.
    public var daily: [Date: Double]

    public init(today: Double, thirtyDay: Double, daily: [Date: Double] = [:]) {
        self.today = today
        self.thirtyDay = thirtyDay
        self.daily = daily
    }

    public static let zero = UsageCost(today: 0, thirtyDay: 0)

    public var isZero: Bool { today == 0 && thirtyDay == 0 }

    public static func + (lhs: UsageCost, rhs: UsageCost) -> UsageCost {
        UsageCost(today: lhs.today + rhs.today,
                  thirtyDay: lhs.thirtyDay + rhs.thirtyDay,
                  daily: lhs.daily.merging(rhs.daily, uniquingKeysWith: +))
    }
}
