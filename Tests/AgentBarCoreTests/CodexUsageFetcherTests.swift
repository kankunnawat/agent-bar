import Foundation
import Testing
@testable import AgentBarCore

private let codexFixture = """
{"plan_type":"pro",
 "rate_limit":{
   "primary_window":{"used_percent":29,"reset_at":1751514120,"limit_window_seconds":18000},
   "secondary_window":{"used_percent":55,"reset_at":1751846400,"limit_window_seconds":604800}},
 "credits":{"has_credits":false,"unlimited":false}}
"""

@Suite struct CodexUsageFetcherTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    @Test func parsesWindowsAndSendsHeaders() async throws {
        let transport = MockTransport(status: 200, json: codexFixture)
        let snap = try await CodexUsageFetcher.fetch(
            accessToken: "tok", accountID: "acct-1", transport: transport, now: now)

        #expect(snap.session?.usedPercent == 29)
        #expect(snap.session?.resetsAt == Date(timeIntervalSince1970: 1_751_514_120))
        #expect(snap.weekly?.usedPercent == 55)
        #expect(snap.planLabel == "pro")

        let req = transport.requests[0]
        #expect(req.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "AgentBar")
    }

    @Test func nilAccountIDOmitsHeader() async throws {
        let transport = MockTransport(status: 200, json: codexFixture)
        _ = try await CodexUsageFetcher.fetch(accessToken: "tok", accountID: nil, transport: transport, now: now)
        #expect(transport.requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    @Test func missingRateLimitYieldsNilWindows() async throws {
        let snap = try await CodexUsageFetcher.fetch(
            accessToken: "tok", accountID: nil,
            transport: MockTransport(status: 200, json: #"{"plan_type":"plus"}"#), now: now)
        #expect(snap.session == nil)
        #expect(snap.weekly == nil)
        #expect(snap.planLabel == "plus")
    }

    /// prolite reports its only general limit — a weekly one — in
    /// `primary_window` with no secondary; the slot must not decide the bucket.
    @Test func weeklyOnlyPrimaryWindowLandsInWeekly() async throws {
        let json = """
        {"plan_type":"prolite",
         "rate_limit":{
           "primary_window":{"used_percent":14,"reset_at":1788761395,"limit_window_seconds":604800},
           "secondary_window":null}}
        """
        let snap = try await CodexUsageFetcher.fetch(
            accessToken: "tok", accountID: nil, transport: MockTransport(status: 200, json: json), now: now)
        #expect(snap.session == nil)
        #expect(snap.weekly?.usedPercent == 14)
        #expect(snap.weekly?.resetsAt == Date(timeIntervalSince1970: 1_788_761_395))
    }

    /// Without `limit_window_seconds` the slot position still decides.
    @Test func missingWindowSecondsFallsBackToSlotPosition() async throws {
        let json = """
        {"rate_limit":{
           "primary_window":{"used_percent":29,"reset_at":1751514120},
           "secondary_window":{"used_percent":55,"reset_at":1751846400}}}
        """
        let snap = try await CodexUsageFetcher.fetch(
            accessToken: "tok", accountID: nil, transport: MockTransport(status: 200, json: json), now: now)
        #expect(snap.session?.usedPercent == 29)
        #expect(snap.weekly?.usedPercent == 55)
    }

    @Test func errorMapping() async {
        await #expect(throws: FetchError.unauthorized) {
            _ = try await CodexUsageFetcher.fetch(
                accessToken: "t", accountID: nil, transport: MockTransport(status: 401, json: ""), now: now)
        }
        await #expect(throws: FetchError.server(503)) {
            _ = try await CodexUsageFetcher.fetch(
                accessToken: "t", accountID: nil, transport: MockTransport(status: 503, json: ""), now: now)
        }
    }

    @Test func malformedJSONIsDistinguished() async {
        await #expect(throws: FetchError.decoding("malformed JSON in usage response")) {
            _ = try await CodexUsageFetcher.fetch(
                accessToken: "t", accountID: nil,
                transport: MockTransport(status: 200, json: "<html>"), now: now)
        }
    }

    @Test func emptyAccountIDOmitsHeader() async throws {
        let transport = MockTransport(status: 200, json: codexFixture)
        _ = try await CodexUsageFetcher.fetch(accessToken: "tok", accountID: "", transport: transport, now: now)
        #expect(transport.requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }
}

@Suite struct CodexAdditionalLimitsTests {
    let now = Date(timeIntervalSince1970: 1_751_500_000)

    private func fetch(_ json: String) async throws -> UsageSnapshot {
        try await CodexUsageFetcher.fetch(
            accessToken: "tok", accountID: nil,
            transport: MockTransport(status: 200, json: json), now: now)
    }

    @Test func parsesAdditionalRateLimits() async throws {
        let snap = try await fetch(RealFixtures.codexProlite)
        #expect(snap.session?.usedPercent == 92)
        #expect(snap.weekly?.usedPercent == 41)
        #expect(snap.scopedSession == [RateWindow(
            usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_783_097_003),
            label: "GPT-5.3-Codex-Spark")])
        #expect(snap.scopedWeekly == [RateWindow(
            usedPercent: 0, resetsAt: Date(timeIntervalSince1970: 1_783_683_803),
            label: "GPT-5.3-Codex-Spark")])
        #expect(snap.spendSummary == nil) // no credits → hidden
        #expect(snap.planLabel == "prolite")
    }

    @Test func creditsBalanceShowsWhenPresent() async throws {
        let snap = try await fetch(
            #"{"rate_limit":{},"credits":{"has_credits":true,"balance":"5"}}"#)
        #expect(snap.spendSummary == "credits 5")
    }

    @Test func zeroBalanceWithoutHasCreditsIsHidden() async throws {
        let snap = try await fetch(
            #"{"rate_limit":{},"credits":{"has_credits":false,"balance":"0"}}"#)
        #expect(snap.spendSummary == nil)
    }

    @Test func malformedAdditionalLimitsAreSkipped() async throws {
        let snap = try await fetch(
            #"{"rate_limit":{},"additional_rate_limits":[{"limit_name":"X"},{"rate_limit":{}}]}"#)
        #expect(snap.scopedSession.isEmpty)
        #expect(snap.scopedWeekly.isEmpty)
    }
}
