import Foundation
import Testing
@testable import AgentBarCore

private let usageFixture = """
{"five_hour":{"utilization":82.0,"resets_at":"2026-07-03T14:32:00.000Z"},
 "seven_day":{"utilization":41.5,"resets_at":"2026-07-07T00:00:00Z"},
 "seven_day_opus":{"utilization":12.0,"resets_at":"2026-07-07T00:00:00Z"},
 "extra_usage":{"is_enabled":false}}
"""

@Suite struct ClaudeUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func parsesWindowsAndSendsHeaders() async throws {
        let transport = MockTransport(status: 200, json: usageFixture)
        let snap = try await ClaudeUsageFetcher.fetch(accessToken: "tok", transport: transport, now: now)

        #expect(snap.session?.usedPercent == 82.0)
        #expect(snap.session?.resetsAt == ISO8601.parse("2026-07-03T14:32:00.000Z"))
        #expect(snap.weekly?.usedPercent == 41.5)
        #expect(snap.fetchedAt == now)

        let req = transport.requests[0]
        #expect(req.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    }

    @Test func missingWindowsYieldNil() async throws {
        let snap = try await ClaudeUsageFetcher.fetch(
            accessToken: "tok", transport: MockTransport(status: 200, json: "{}"), now: now)
        #expect(snap.session == nil)
        #expect(snap.weekly == nil)
    }

    @Test func http401ThrowsUnauthorized() async {
        await #expect(throws: FetchError.unauthorized) {
            _ = try await ClaudeUsageFetcher.fetch(
                accessToken: "tok", transport: MockTransport(status: 401, json: "{}"), now: now)
        }
    }

    @Test func http429CarriesRetryAfter() async {
        let transport = MockTransport(status: 429, json: "{}", headers: ["Retry-After": "60"])
        await #expect(throws: FetchError.rateLimited(retryAfter: now.addingTimeInterval(60))) {
            _ = try await ClaudeUsageFetcher.fetch(accessToken: "tok", transport: transport, now: now)
        }
    }

    @Test func http500ThrowsServer() async {
        await #expect(throws: FetchError.server(500)) {
            _ = try await ClaudeUsageFetcher.fetch(
                accessToken: "tok", transport: MockTransport(status: 500, json: ""), now: now)
        }
    }

    @Test func malformedJSONIsDistinguished() async {
        await #expect(throws: FetchError.decoding("malformed JSON in usage response")) {
            _ = try await ClaudeUsageFetcher.fetch(
                accessToken: "t", transport: MockTransport(status: 200, json: "not json"), now: Date())
        }
    }
}

@Suite struct ClaudeLimitsParsingTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    private func fetch(_ json: String) async throws -> UsageSnapshot {
        try await ClaudeUsageFetcher.fetch(
            accessToken: "tok", transport: MockTransport(status: 200, json: json), now: now)
    }

    @Test func limitsArrayIsPrimarySource() async throws {
        let snap = try await fetch(RealFixtures.claudeExperimental)
        #expect(snap.session?.usedPercent == 29)
        #expect(snap.session?.resetsAt == ISO8601.parse("2026-07-03T14:20:00.251883+00:00"))
        #expect(snap.weekly?.usedPercent == 71)
        #expect(snap.scopedWeekly == [RateWindow(
            usedPercent: 81,
            resetsAt: ISO8601.parse("2026-07-05T08:00:00.252313+00:00"),
            label: "Fable")])
        #expect(snap.scopedSession.isEmpty)
        #expect(snap.spendSummary == nil) // disabled + $0 → hidden
    }

    @Test func missingLimitsFallsBackToLegacyFields() async throws {
        let snap = try await fetch(RealFixtures.claudeLegacyShape)
        #expect(snap.session?.usedPercent == 82.0)
        #expect(snap.weekly?.usedPercent == 41.5)
        #expect(snap.scopedWeekly.isEmpty)
    }

    @Test func emptyLimitsArrayFallsBackToLegacyFields() async throws {
        let snap = try await fetch(
            #"{"limits":[],"five_hour":{"utilization":10.0},"seven_day":{"utilization":20.0}}"#)
        #expect(snap.session?.usedPercent == 10.0)
        #expect(snap.weekly?.usedPercent == 20.0)
    }

    @Test func enabledSpendIsFormatted() async throws {
        let snap = try await fetch("""
        {"limits":[{"group":"session","percent":1}],
         "spend":{"enabled":true,
                  "used":{"amount_minor":123,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":1000,"currency":"USD","exponent":2}}}
        """)
        #expect(snap.spendSummary == "extra $1.23 of $10.00")
    }

    @Test func spendWithoutLimitOmitsSuffix() async throws {
        let snap = try await fetch("""
        {"limits":[{"group":"session","percent":1}],
         "spend":{"enabled":false,"used":{"amount_minor":50,"currency":"USD","exponent":2}}}
        """)
        #expect(snap.spendSummary == "extra $0.50") // used > 0 shows even when disabled
    }
}
