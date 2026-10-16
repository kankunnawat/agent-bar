import Foundation

public struct AlertEvent: Equatable, Sendable {
    public var accountID: String
    public var title: String
    public var body: String
}

/// Which rate-limit window an alert concerns. Drives the duration word in
/// titles ("5h" vs "weekly") and keeps session/weekly dedup keys distinct.
enum AlertDimension: Sendable {
    case session, weekly

    var durationLabel: String { self == .session ? "5h" : "weekly" }
    var keyToken: String { self == .session ? "session" : "weekly" }
}

public struct AlertEngine: Sendable {
    public var thresholdPercent: Double
    public var weeklyThresholdPercent: Double

    /// A limit alert already delivered, retained until its window resets so we
    /// can (a) dedup re-fires and (b) emit a one-shot reset-clear.
    private struct Fired {
        let accountID: String
        let dimension: AlertDimension
        /// Genuine reset date; nil means the window reported no reset, so no
        /// reset-clear is ever emitted for it.
        let resetsAt: Date?
        /// When to stop tracking this entry (real reset, or a 5h fallback).
        let prunesAt: Date
        /// The window's own unit word ("mo"); nil = the dimension default.
        let periodLabel: String?
    }
    /// Keyed "accountID|dimension|resetEpoch".
    private var fired: [String: Fired] = [:]

    public init(thresholdPercent: Double, weeklyThresholdPercent: Double = 90) {
        self.thresholdPercent = thresholdPercent
        self.weeklyThresholdPercent = weeklyThresholdPercent
    }

    public mutating func evaluate(
        _ rows: [(account: Account, state: AccountState)],
        now: Date
    ) -> [AlertEvent] {
        let accountByID = Dictionary(rows.map { ($0.account.id, $0.account) }, uniquingKeysWith: { first, _ in first })
        let stateByID = Dictionary(rows.map { ($0.account.id, $0.state) }, uniquingKeysWith: { first, _ in first })

        var events: [AlertEvent] = []

        // 1. Reset-clear: drop every fired window whose reset has passed, and
        //    emit an all-clear for the ones that genuinely reset while the
        //    account is now observed clear.
        for (key, entry) in fired where entry.prunesAt <= now {
            fired[key] = nil
            guard entry.resetsAt != nil,
                  let account = accountByID[entry.accountID],
                  case .ok(let snap)? = stateByID[entry.accountID] else { continue }
            let current = entry.dimension == .session ? snap.worstSession : snap.worstWeekly
            let threshold = entry.dimension == .session ? thresholdPercent : weeklyThresholdPercent
            guard (current?.usedPercent ?? 0) < threshold else { continue } // still hot: fresh alert covers it
            let period = entry.periodLabel ?? entry.dimension.durationLabel
            events.append(AlertEvent(
                accountID: account.id,
                title: "\(Self.name(account)) — \(period) limit reset",
                body: "You're clear."))
        }

        // 2. Threshold crossings for both windows of every ok account.
        for (account, state) in rows {
            guard case .ok(let snap) = state else { continue }
            events += fire(.session, window: snap.worstSession,
                           account: account, rows: rows, now: now)
            events += fire(.weekly, window: snap.worstWeekly,
                           account: account, rows: rows, now: now)
        }
        return events
    }

    private mutating func fire(
        _ dimension: AlertDimension,
        window: RateWindow?,
        account: Account,
        rows: [(account: Account, state: AccountState)],
        now: Date
    ) -> [AlertEvent] {
        let threshold = dimension == .session ? thresholdPercent : weeklyThresholdPercent
        guard let window, window.usedPercent >= threshold else { return [] }
        let resetKey = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let key = "\(account.id)|\(dimension.keyToken)|\(resetKey)"
        guard fired[key] == nil else { return [] }
        fired[key] = Fired(
            accountID: account.id, dimension: dimension, resetsAt: window.resetsAt,
            prunesAt: window.resetsAt ?? now.addingTimeInterval(5 * 3600),
            periodLabel: window.periodLabel)

        var body = "Resets \(window.resetsAt.map { Aggregation.countdown(to: $0, from: now) } ?? "later")."
        if let alt = headroom(among: rows, provider: account.provider, dimension: dimension, excluding: account.id) {
            body += " \(alt.label) has the most headroom (\(Int(alt.percent))%)."
        }
        let period = window.periodLabel ?? dimension.durationLabel
        let limitName = window.label.map { "\($0) \(period)" } ?? period
        return [AlertEvent(
            accountID: account.id,
            title: "\(Self.name(account)) is at \(Int(window.usedPercent))% of its \(limitName) limit",
            body: body)]
    }

    /// "Claude · work"; just "Cursor" when the label repeats the provider
    /// (Cursor's single account is labelled after the app).
    private static func name(_ account: Account) -> String {
        let provider = account.provider.displayName
        return account.label == provider ? provider : "\(provider) · \(account.label)"
    }

    private func headroom(
        among rows: [(account: Account, state: AccountState)],
        provider: Provider,
        dimension: AlertDimension,
        excluding id: String
    ) -> (label: String, percent: Double)? {
        rows.compactMap { row -> (String, Double)? in
            guard row.account.provider == provider, row.account.id != id,
                  case .ok(let snap) = row.state else { return nil }
            let window = dimension == .session ? snap.worstSession : snap.worstWeekly
            guard let window else { return nil }
            return (row.account.label, window.usedPercent)
        }
        .min { $0.1 < $1.1 }
        .map { (label: $0.0, percent: $0.1) }
    }
}
