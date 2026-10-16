import Foundation

public enum Tint: Sendable, Equatable {
    case normal, warning, critical
}

public enum Aggregation {
    public static func worstSessionPercent(_ states: [AccountState]) -> Double? {
        let percents = states.compactMap { state -> Double? in
            if case .ok(let snap) = state { return snap.worstSession?.usedPercent }
            return nil
        }
        return percents.max()
    }

    public static func tint(for percent: Double) -> Tint {
        switch percent {
        case ..<70: .normal
        case ..<90: .warning
        default: .critical
        }
    }

    /// Worst tint across the session and weekly windows (nil window = 0%).
    public static func tint(session: Double?, weekly: Double?) -> Tint {
        tint(for: max(session ?? 0, weekly ?? 0))
    }

    public static func countdown(to date: Date, from now: Date,
                                 timeZone: TimeZone = .current,
                                 locale: Locale = .autoupdatingCurrent) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        if interval < 24 * 3600 { return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m" }
        return weekdayDateTime(date, timeZone: timeZone, locale: locale)
    }

    /// The ">= 24h out" form: weekday, date, and wall-clock time in the
    /// *display* zone. A bare GMT weekday carried no hour, was off by a day
    /// east of London, and left "which Wednesday?" open. Field order follows
    /// the locale (en_US puts the month first). No year: a window never resets
    /// more than about a month out (Cursor's billing cycle), and a Thai locale
    /// would render it "2569 BE".
    private static func weekdayDateTime(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let is12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?
            .contains("a") ?? true
        let onTheHour = calendar.component(.minute, from: date) == 0
        // Two formatters: one covering both fields splices in the locale's
        // connector ("Wed, 29 Jul at 10:00"), too wordy for a telemetry line.
        let dayFormatter = formatter(timeZone: timeZone, locale: locale)
        dayFormatter.dateFormat = dayPattern(locale)
        let timeFormatter = formatter(timeZone: timeZone, locale: locale)
        timeFormatter.setLocalizedDateFormatFromTemplate(is12Hour && onTheHour ? "j" : "jmm")
        return "\(dayFormatter.string(from: date)), \(timeFormatter.string(from: date))"
    }

    /// Locale weekday+date pattern minus the comma ICU puts after the weekday:
    /// the time is appended with a comma of our own, and "Wed, 29 Jul, 10:00"
    /// reads choppy where "Wed 29 Jul, 10:00" does not.
    private static func dayPattern(_ locale: Locale) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "EEEdMMM", options: 0, locale: locale)
        return (pattern ?? "EEE d MMM").replacingOccurrences(of: "EEE,", with: "EEE")
    }

    private static func formatter(timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter
    }
}
