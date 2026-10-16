import Foundation
import Testing
@testable import AgentBarCore

private func okState(session: Double) -> AccountState {
    .ok(UsageSnapshot(session: RateWindow(usedPercent: session, resetsAt: nil),
                      weekly: nil, fetchedAt: Date(timeIntervalSince1970: 0)))
}

/// Fixed zones/locales so the weekday form is asserted without inheriting the
/// test machine's settings. Bangkok is +07 with no DST; Kolkata's :30 offset
/// pushes a whole-hour UTC reset off the hour locally.
private let bangkok = TimeZone(secondsFromGMT: 7 * 3600)!
private let kolkata = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!
private let us12 = Locale(identifier: "en_US")   // j -> "h a"
private let gb24 = Locale(identifier: "en_GB")   // j -> "HH"

/// ICU separates the time from AM/PM with U+202F (narrow no-break space);
/// assertions are written against a plain space.
private func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
}

@Suite struct AggregationTests {
    @Test func worstPicksMaxAcrossOKStates() {
        let states: [AccountState] = [okState(session: 12), okState(session: 82), .error("x"), .loading]
        #expect(Aggregation.worstSessionPercent(states) == 82)
    }

    @Test func noOKStatesYieldsNil() {
        #expect(Aggregation.worstSessionPercent([.error("x"), .loading, .stale("y")]) == nil)
    }

    @Test func okStateWithoutSessionWindowIsIgnored() {
        let noSession = AccountState.ok(UsageSnapshot(session: nil, weekly: nil,
                                                      fetchedAt: Date(timeIntervalSince1970: 0)))
        #expect(Aggregation.worstSessionPercent([noSession]) == nil)
        #expect(Aggregation.worstSessionPercent([noSession, okState(session: 5)]) == 5)
    }

    @Test func tintThresholds() {
        #expect(Aggregation.tint(for: 0) == .normal)
        #expect(Aggregation.tint(for: 69.9) == .normal)
        #expect(Aggregation.tint(for: 70) == .warning)
        #expect(Aggregation.tint(for: 89.9) == .warning)
        #expect(Aggregation.tint(for: 90) == .critical)
        #expect(Aggregation.tint(for: 100) == .critical)
    }

    @Test func countdownFormats() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!
        #expect(Aggregation.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
        #expect(Aggregation.countdown(to: now.addingTimeInterval(37 * 60), from: now) == "37m")
        #expect(Aggregation.countdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60), from: now) == "2h14m")
        // > 24h away -> weekday + date + local time (2026-07-06 is a Monday)
        #expect(plainSpaces(Aggregation.countdown(to: ISO8601.parse("2026-07-06T10:00:00Z")!,
                                                 from: now, timeZone: bangkok, locale: us12))
            == "Mon Jul 6, 5 PM")
    }

    /// Regression: the weekday was formatted in GMT, so a reset landing in the
    /// small hours of a UTC+7 morning was named the *previous* day — and the
    /// hour was missing entirely, so a correct day still didn't say when.
    @Test func countdownWeekdayUsesDisplayZone() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!        // Fri 17:00 in +07
        let target = ISO8601.parse("2026-07-08T20:00:00Z")!     // Wed in GMT, Thu 03:00 in +07
        #expect(plainSpaces(Aggregation.countdown(to: target, from: now,
                                                 timeZone: bangkok, locale: us12))
            == "Thu Jul 9, 3 AM")
        #expect(plainSpaces(Aggregation.countdown(to: target, from: now,
                                                 timeZone: .gmt, locale: us12))
            == "Wed Jul 8, 8 PM")
    }

    /// 24h locales keep ":00" — a bare "Thu 03" would not read as a time.
    /// en_GB also orders the date day-first and needs no comma stripped.
    @Test func countdownWeekdayFollowsHourCycle() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!
        let target = ISO8601.parse("2026-07-08T20:00:00Z")!
        #expect(Aggregation.countdown(to: target, from: now, timeZone: bangkok, locale: gb24)
            == "Thu 9 Jul, 03:00")
    }

    /// A whole-hour UTC reset is off the hour in a :30 zone, so minutes stay.
    @Test func countdownWeekdayKeepsOffsetMinutes() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!
        let target = ISO8601.parse("2026-07-06T10:00:00Z")!     // Mon 15:30 in +05:30
        #expect(plainSpaces(Aggregation.countdown(to: target, from: now,
                                                 timeZone: kolkata, locale: us12))
            == "Mon Jul 6, 3:30 PM")
        #expect(Aggregation.countdown(to: target, from: now, timeZone: kolkata, locale: gb24)
            == "Mon 6 Jul, 15:30")
    }

    /// Weekly windows reset on a 7-day cadence, so just after a reset the next
    /// one lands on today's weekday. The date is what disambiguates it — a bare
    /// "Fri 3 PM" would have read as hours rather than a week away.
    @Test func countdownSevenDaysOutCarriesDate() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!        // Fri 17:00 in +07
        let target = ISO8601.parse("2026-07-10T08:00:00Z")!     // Fri 15:00 in +07, ~7d out
        #expect(plainSpaces(Aggregation.countdown(to: target, from: now,
                                                 timeZone: bangkok, locale: us12))
            == "Fri Jul 10, 3 PM")
        // Crossing a month boundary still carries no year.
        #expect(plainSpaces(Aggregation.countdown(to: ISO8601.parse("2026-08-01T08:00:00Z")!,
                                                 from: ISO8601.parse("2026-07-28T10:00:00Z")!,
                                                 timeZone: bangkok, locale: us12))
            == "Sat Aug 1, 3 PM")
    }

    @Test func worstOfWindowsTint() {
        #expect(Aggregation.tint(session: 10, weekly: 10) == .normal)
        #expect(Aggregation.tint(session: 10, weekly: 75) == .warning)   // weekly drives
        #expect(Aggregation.tint(session: 92, weekly: 10) == .critical)  // session drives
        #expect(Aggregation.tint(session: nil, weekly: nil) == .normal)
        #expect(Aggregation.tint(session: nil, weekly: 91) == .critical)
    }

    @Test func countdownBoundaries() {
        let now = ISO8601.parse("2026-07-03T10:00:00Z")!        // Fri 17:00 in +07
        #expect(Aggregation.countdown(to: now.addingTimeInterval(3_599), from: now) == "59m")
        #expect(Aggregation.countdown(to: now.addingTimeInterval(3_600), from: now) == "1h00m")
        #expect(Aggregation.countdown(to: now.addingTimeInterval(24 * 3_600 - 60), from: now) == "23h59m")
        // exactly 24h falls through to the dated form (Sat 17:00 in +07)
        #expect(plainSpaces(Aggregation.countdown(to: now.addingTimeInterval(24 * 3_600),
                                                 from: now, timeZone: bangkok, locale: us12))
            == "Sat Jul 4, 5 PM")
    }
}
