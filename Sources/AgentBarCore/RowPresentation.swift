import Foundation

/// One row of the hover readout: the measurement's name and its reading.
public struct ReadoutLine: Sendable, Hashable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum RowPresentation {
    /// Hover-card body: every window (both the unscoped and each scoped one)
    /// per dimension — session first, then weekly — plus the cost line. The
    /// collapsed bar shows only the worst window; the card lists them all.
    /// Over-pace windows show the projected "full" moment (when usage hits
    /// 100%) and the reset countdown; otherwise the reset countdown alone.
    /// Label/value pairs only — the
    /// view renders the name line and the column layout itself.
    public static func hoverReadout(
        _ snap: UsageSnapshot, cost: UsageCost?, alerts: AlertsConfig, now: Date
    ) -> [ReadoutLine] {
        var lines: [ReadoutLine] = []
        for session in ([snap.session].compactMap { $0 }) + snap.scopedSession {
            lines.append(windowLine(session, unit: session.periodLabel ?? "5h", kind: .session, alerts: alerts, now: now))
        }
        for weekly in ([snap.weekly].compactMap { $0 }) + snap.scopedWeekly {
            lines.append(windowLine(weekly, unit: weekly.periodLabel ?? "wk", kind: .weekly, alerts: alerts, now: now))
        }
        if let pace = paceLine(snap, now: now) {
            lines.append(pace)
        }
        if let plan = snap.planLabel {
            lines.append(ReadoutLine(label: "plan", value: plan))
        }
        if let costText = costLine(cost) {
            lines.append(ReadoutLine(label: "cost", value: costText))
        }
        if let spend = snap.spendSummary {
            lines.append(ReadoutLine(label: "spend", value: spend))   // overage/credits — from the old caption
        }
        return lines
    }

    /// "$4.20 today · $61.53/mo"; nil when there is no cost data yet — the
    /// card omits the line rather than showing "$0".
    public static func costLine(_ cost: UsageCost?) -> String? {
        guard let cost, !cost.isZero else { return nil }
        return "\(dollars(cost.today)) today · \(dollars(cost.thirtyDay))/mo"
    }

    /// Footer total, explicitly labelled an estimate at API rates.
    public static func footerCostLine(_ cost: UsageCost) -> String? {
        costLine(cost).map { "\($0) · API rates" }
    }

    /// Compact reset countdown for the collapsed row: "2:05" hours:minutes
    /// left. nil without a reset date or >= 24h out (true of Cursor's
    /// month-long session slot for most of its cycle, never of a Claude or
    /// Codex session window); "now" once the reset moment has passed — the
    /// next refresh clears the row. The hover card keeps the wordier
    /// countdown form.
    public static func resetCaption(resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 { return "now" }
        guard interval < 24 * 3600 else { return nil }
        let minutes = Int(interval / 60)
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// Row cost caption: today's estimate alone ("$6.40"), under the percent
    /// reading. nil when there is no cost data at all — the row omits the
    /// caption rather than faking $0.
    public static func rowCostCaption(_ cost: UsageCost?) -> String? {
        guard let cost, !cost.isZero else { return nil }
        return dollars(cost.today)
    }

    private static func dollars(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    private static func windowLine(
        _ window: RateWindow, unit: String, kind: WindowKind, alerts: AlertsConfig, now: Date
    ) -> ReadoutLine {
        let name = window.label.map { "\($0) \(unit)" } ?? unit
        var text = "\(Int(window.usedPercent))%"
        // Same gate as the row cue (RiskPresentation.riskProjection): a window
        // below its warning mark reports its level, never a projected full.
        if window.usedPercent >= alerts.threshold(for: kind),
           let full = PaceProjection.emptyAt(
            usedPercent: window.usedPercent, resetsAt: window.resetsAt, startsAt: window.startsAt,
            now: now, kind: kind) {
            // "in" for a duration (2h13m), "by" for a day name (Mon) — the 24h
            // split matches Aggregation.countdown's own hours-vs-day boundary.
            let connector = full.timeIntervalSince(now) < 24 * 3600 ? "in" : "by"
            text += " · full \(connector) \(Aggregation.countdown(to: full, from: now))"
        }
        if let resets = window.resetsAt {
            text += " · resets \(Aggregation.countdown(to: resets, from: now))"
        }
        return ReadoutLine(label: name, value: text)
    }

    /// Under-pace verdict across the session windows. Over-pace windows
    /// already carry "full in X" on their own line, so this appears only when
    /// the news is good everywhere: every session window can be judged and
    /// every one is at or behind the clock, so the current burn survives to
    /// the reset. One over-pace or dateless window and the verdict is out —
    /// "under" must never sit beside a "full in X" line.
    private static func paceLine(_ snap: UsageSnapshot, now: Date) -> ReadoutLine? {
        let sessions = ([snap.session].compactMap { $0 }) + snap.scopedSession
        guard !sessions.isEmpty else { return nil }
        for window in sessions {
            guard let elapsed = PaceProjection.elapsedFraction(
                      resetsAt: window.resetsAt, startsAt: window.startsAt, now: now, kind: .session),
                  window.usedPercent / 100 <= elapsed
            else { return nil }
        }
        return ReadoutLine(label: "pace", value: "under — clear past reset")
    }

    /// Whether the menu shows a row: not hidden by the user and not signed
    /// out. Signed-out rows keep refreshing, so they return on sign-in.
    public static func isShown(_ account: Account, state: AccountState) -> Bool {
        !account.hidden && state != .signedOut
    }

    /// Applies the user's saved order (unknown ids keep their incoming
    /// relative position, after ordered ones), then lifts the pinned
    /// account to the front. Provider grouping happens at render time,
    /// so "front of the list" is "top of its group" in the menu.
    public static func ordered(_ accounts: [Account], order: [String], pinned: String?) -> [Account] {
        // `order` is persisted config (may be stale or hand-edited), so
        // tolerate duplicate ids: the first occurrence wins.
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var sorted = accounts.enumerated().sorted { lhs, rhs in
            let l = position[lhs.element.id] ?? order.count + lhs.offset
            let r = position[rhs.element.id] ?? order.count + rhs.offset
            return l < r
        }.map(\.element)
        if let pinned, let index = sorted.firstIndex(where: { $0.id == pinned }) {
            let account = sorted.remove(at: index)
            sorted.insert(account, at: 0)
        }
        return sorted
    }

    /// 30 daily-cost slots, oldest→today, absent days zero — the hover card's
    /// histogram. nil (row omitted) when no day has any cost.
    public static func dailyCostSeries(_ cost: UsageCost?, now: Date) -> [Double]? {
        guard let cost, cost.daily.values.contains(where: { $0 > 0 }) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<30).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 0 }
            return cost.daily[day] ?? 0
        }
    }

    /// Ordered weekly-% values for the hover card's line. nil (row omitted)
    /// below two points — one point draws nothing honest.
    public static func weeklySeries(_ entries: [HistoryEntry]) -> [Double]? {
        let values = entries.compactMap(\.weekly)
        return values.count >= 2 ? values : nil
    }

    /// The order to persist after a drag. The pin lifts its row to the front
    /// at render time (`ordered`), so the pinned id must not be baked into
    /// the saved order: keep it at the slot `previousOrder` already had for
    /// it, or omit it entirely if it was never ordered.
    public static func persistedOrder(visual: [String], pinned: String?, previousOrder: [String]) -> [String] {
        guard let pinned else { return visual }
        var order = visual.filter { $0 != pinned }
        if let old = previousOrder.firstIndex(of: pinned) {
            order.insert(pinned, at: min(old, order.count))
        }
        return order
    }
}

public enum IconState: Sendable, Equatable {
    case normal(percent: Double, tint: Tint)
    case allErrored
    case noAccounts
}

public enum IconStateBuilder {
    /// Menu-bar number source: the pinned account when it has usable data,
    /// else the worst session percent across accounts. `◆ !` only when every
    /// account is errored/stale; `◆ ?` when there is nothing to show at all.
    public static func build(states: [(id: String, state: AccountState)], pinnedID: String?) -> IconState {
        guard !states.isEmpty else { return .noAccounts }
        let allErrored = states.allSatisfy { entry in
            switch entry.state {
            case .error, .stale: true
            case .ok, .loading, .signedOut: false
            }
        }
        if allErrored { return .allErrored }

        if let pinnedID,
           let pinned = states.first(where: { $0.id == pinnedID }),
           case .ok(let snap) = pinned.state {
            return .normal(
                percent: snap.worstSession?.usedPercent ?? 0,
                tint: Aggregation.tint(
                    session: snap.worstSession?.usedPercent, weekly: snap.worstWeekly?.usedPercent))
        }
        let worst = Aggregation.worstSessionPercent(states.map(\.state)) ?? 0
        return .normal(percent: worst, tint: Aggregation.tint(for: worst))
    }
}
