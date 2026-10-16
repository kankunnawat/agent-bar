import Foundation

/// Window length assumed for pace math — the same durations `AlertEngine`
/// already assumes for session (5h) and weekly (7d) windows.
public enum WindowKind: Sendable, Equatable {
    case session, weekly

    public var duration: TimeInterval {
        switch self {
        case .session: 5 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }
}

/// Pure on-pace math for a rate window: how far through the window we are
/// in *time* (the meter tick), and a linear projection of when the window
/// empties when usage is running ahead of the clock (the "empty" ETA).
public enum PaceProjection {
    /// Fraction of the window elapsed, clamped to [0, 1].
    /// nil when the window has no reset date — no tick can be drawn.
    public static func elapsedFraction(
        resetsAt: Date?, startsAt: Date? = nil, now: Date, kind: WindowKind
    ) -> Double? {
        guard let resetsAt else { return nil }
        let elapsed = 1 - resetsAt.timeIntervalSince(now) / length(resetsAt: resetsAt, startsAt: startsAt, kind: kind)
        return min(max(elapsed, 0), 1)
    }

    /// Projected moment the window hits 100%, by linear extrapolation of the
    /// current burn: timeToEmpty = elapsedSeconds * (1 - burned) / burned.
    /// nil when there is no reset date, nothing burned, usage is at or under
    /// pace (fill <= tick), or the projection exceeds one full window (cap).
    public static func emptyAt(
        usedPercent: Double, resetsAt: Date?, startsAt: Date? = nil, now: Date, kind: WindowKind
    ) -> Date? {
        guard let resetsAt,
              let elapsed = elapsedFraction(resetsAt: resetsAt, startsAt: startsAt, now: now, kind: kind)
        else { return nil }
        let duration = length(resetsAt: resetsAt, startsAt: startsAt, kind: kind)
        let burned = usedPercent / 100
        guard burned > 0, burned > elapsed else { return nil } // only meaningful over pace
        let elapsedSeconds = elapsed * duration
        guard elapsedSeconds > 0 else { return nil }
        let timeToEmpty = elapsedSeconds * (1 - burned) / burned
        guard timeToEmpty <= duration else { return nil }  // absurd-ETA cap
        return now.addingTimeInterval(timeToEmpty)
    }

    /// Reported window length when the provider gives a start, else the
    /// slot's fixed length. A start at or after the reset is bad data.
    private static func length(resetsAt: Date, startsAt: Date?, kind: WindowKind) -> TimeInterval {
        guard let startsAt, resetsAt > startsAt else { return kind.duration }
        return resetsAt.timeIntervalSince(startsAt)
    }
}
