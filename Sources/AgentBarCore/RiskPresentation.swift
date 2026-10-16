import Foundation

/// Derives collapsed-dropdown copy and same-provider routing from existing
/// usage snapshots without fetching, persisting, or mutating account state.
public enum RiskPresentation {
    /// Formats the earliest projected-full window for one account.
    ///
    /// - Parameters:
    ///   - snapshot: The account's current session and weekly windows.
    ///   - alerts: The user's warning marks; a window under its mark stays quiet.
    ///   - now: The shared render timestamp used for pace math and countdowns.
    /// - Returns: A compact `FULL` or `WK FULL` cue, or nil when no window is actionable.
    public static func caption(for snapshot: UsageSnapshot, alerts: AlertsConfig, now: Date) -> String? {
        guard let risk = riskProjection(snapshot, alerts: alerts, now: now) else { return nil }
        let prefix = risk.kind == .session ? "FULL" : "WK FULL"
        guard risk.fullAt > now else { return prefix }
        let countdown = RowPresentation.resetCaption(resetsAt: risk.fullAt, now: now)
            ?? Aggregation.countdown(to: risk.fullAt, from: now)
        return "\(prefix) \(countdown)"
    }

    /// Selects the visible same-provider account with the most safe headroom.
    ///
    /// - Parameters:
    ///   - provider: The provider whose risky accounts need a fallback.
    ///   - rows: Current account states across all providers.
    ///   - alerts: The user's warning marks, applied to the risky account.
    ///   - now: The shared render timestamp used to judge candidate safety.
    /// - Returns: The selected account id, or nil without risk or a safe alternative.
    public static func recommendedAlternativeID(
        for provider: Provider,
        among rows: [(account: Account, state: AccountState)],
        alerts: AlertsConfig,
        now: Date
    ) -> String? {
        let rows = rows.filter { $0.account.provider == provider && !$0.account.hidden }
        guard let urgent = rows.compactMap({ projection(for: $0.state, alerts: alerts, now: now) })
            .min(by: { earlier($0, than: $1) })
        else { return nil }
        return rows.compactMap { candidate($0, for: urgent.kind, alerts: alerts, now: now) }
            .min(by: { $0.percent < $1.percent })?.id
    }

    private struct Projection {
        let kind: WindowKind
        let fullAt: Date
    }

    private static func projection(for state: AccountState, alerts: AlertsConfig, now: Date) -> Projection? {
        guard case .ok(let snapshot) = state else { return nil }
        return riskProjection(snapshot, alerts: alerts, now: now)
    }

    /// Only a window that has crossed its warning mark can raise a cue: below
    /// it a "runs out" claim is a long extrapolation of an integer percent —
    /// loud, unactionable, and wrong as often as not. Above it the same math
    /// is necessarily imminent (at 90% burned, empty is within a tenth of a
    /// window), so one gate buys both quiet and urgency.
    private static func riskProjection(_ snapshot: UsageSnapshot, alerts: AlertsConfig, now: Date) -> Projection? {
        let kinds: [WindowKind] = [.session, .weekly]
        return kinds.flatMap { kind in
            windows(in: snapshot, kind: kind)
                .filter { $0.usedPercent >= alerts.threshold(for: kind) }
                .compactMap { projection(window: $0, kind: kind, now: now) }
        }.min(by: { earlier($0, than: $1) })
    }

    private static func projection(
        window: RateWindow,
        kind: WindowKind,
        now: Date
    ) -> Projection? {
        if window.usedPercent >= 100 { return Projection(kind: kind, fullAt: now) }
        guard let fullAt = PaceProjection.emptyAt(
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            startsAt: window.startsAt,
            now: now,
            kind: kind)
        else { return nil }
        return Projection(kind: kind, fullAt: fullAt)
    }

    private static func candidate(
        _ row: (account: Account, state: AccountState),
        for kind: WindowKind,
        alerts: AlertsConfig,
        now: Date
    ) -> (id: String, percent: Double)? {
        guard case .ok(let snapshot) = row.state,
              riskProjection(snapshot, alerts: alerts, now: now) == nil,
              isSafe(snapshot, kind: kind, now: now),
              let percent = usagePercent(snapshot, kind: kind)
        else { return nil }
        return (row.account.id, percent)
    }

    private static func isSafe(
        _ snapshot: UsageSnapshot,
        kind: WindowKind,
        now: Date
    ) -> Bool {
        let windows = windows(in: snapshot, kind: kind)
        guard !windows.isEmpty else { return false }
        return windows.allSatisfy { window in
            guard window.usedPercent < 100,
                  let reset = window.resetsAt,
                  reset > now
            else { return false }
            return PaceProjection.emptyAt(
                usedPercent: window.usedPercent,
                resetsAt: reset,
                startsAt: window.startsAt,
                now: now,
                kind: kind) == nil
        }
    }

    private static func usagePercent(_ snapshot: UsageSnapshot, kind: WindowKind) -> Double? {
        switch kind {
        case .session: snapshot.worstSession?.usedPercent
        case .weekly: snapshot.worstWeekly?.usedPercent
        }
    }

    private static func windows(in snapshot: UsageSnapshot, kind: WindowKind) -> [RateWindow] {
        switch kind {
        case .session: ([snapshot.session].compactMap { $0 }) + snapshot.scopedSession
        case .weekly: ([snapshot.weekly].compactMap { $0 }) + snapshot.scopedWeekly
        }
    }

    private static func earlier(_ lhs: Projection, than rhs: Projection) -> Bool {
        if lhs.fullAt != rhs.fullAt { return lhs.fullAt < rhs.fullAt }
        return lhs.kind == .session && rhs.kind == .weekly
    }
}
