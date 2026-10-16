import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex, cursor

    public var displayName: String { rawValue.capitalized }

    /// Company whose status page covers this provider.
    public var statusName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "OpenAI"
        case .cursor: "Cursor"
        }
    }
}

public struct Account: Identifiable, Hashable, Sendable {
    public let provider: Provider
    /// Absolute config-dir (Claude), home-dir (Codex), or app-support dir
    /// (Cursor) path, no trailing slash.
    public let path: String
    public var label: String
    public var hidden: Bool

    public var id: String { "\(provider.rawValue):\(path)" }

    public init(provider: Provider, path: String, label: String, hidden: Bool) {
        self.provider = provider
        self.path = path
        self.label = label
        self.hidden = hidden
    }
}

public struct RateWindow: Sendable, Equatable {
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Model/limit name for scoped windows ("Fable"); nil = unscoped.
    public var label: String?
    /// Window start when the provider reports it (Cursor billing cycle);
    /// nil = the slot's fixed length (5h session, 7d weekly).
    public var startsAt: Date?
    /// Unit word for this window's length ("mo"); nil = the slot default
    /// ("5h" session, "wk"/"weekly" weekly).
    public var periodLabel: String?
    public init(usedPercent: Double, resetsAt: Date?, label: String? = nil,
                startsAt: Date? = nil, periodLabel: String? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.label = label
        self.startsAt = startsAt
        self.periodLabel = periodLabel
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var session: RateWindow?
    public var weekly: RateWindow?
    public var scopedSession: [RateWindow]
    public var scopedWeekly: [RateWindow]
    public var spendSummary: String?
    public var planLabel: String?
    public var fetchedAt: Date

    public init(session: RateWindow?, weekly: RateWindow?,
                scopedSession: [RateWindow] = [], scopedWeekly: [RateWindow] = [],
                spendSummary: String? = nil, planLabel: String? = nil, fetchedAt: Date) {
        self.session = session
        self.weekly = weekly
        self.scopedSession = scopedSession
        self.scopedWeekly = scopedWeekly
        self.spendSummary = spendSummary
        self.planLabel = planLabel
        self.fetchedAt = fetchedAt
    }

    /// Tightest session window; unscoped wins ties so labels appear only
    /// when a scoped window is strictly tighter.
    public var worstSession: RateWindow? { Self.worst(session, scopedSession) }
    /// Tightest weekly window; same tie-break as `worstSession`.
    public var worstWeekly: RateWindow? { Self.worst(weekly, scopedWeekly) }

    private static func worst(_ unscoped: RateWindow?, _ scoped: [RateWindow]) -> RateWindow? {
        var best = unscoped
        for window in scoped where window.usedPercent > (best?.usedPercent ?? -1) {
            best = window
        }
        return best
    }
}

public enum AccountState: Sendable, Equatable {
    case loading
    case ok(UsageSnapshot)
    case stale(String)
    case error(String)
    /// Installed but no login stored (Cursor): the menu hides the row and
    /// polling continues, so it reappears on sign-in.
    case signedOut
}

public enum FetchError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case server(Int)
    case decoding(String)
    case credentialsMissing(String)
    /// The app is installed but holds no login; see `AccountState.signedOut`.
    case signedOut
    /// Candidate keychain slots for one config dir hold different accounts
    /// (subscriptionType disagrees) — picking either would show the wrong
    /// account's usage under this row's label.
    case conflictingCredentials(String)
    case keychainDenied
}

public enum ISO8601 {
    public static func parse(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

public enum RetryAfter {
    public static func parse(_ value: String?, now: Date) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let seconds = Double(value) { return now.addingTimeInterval(seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value)
    }
}
