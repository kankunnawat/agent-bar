import Foundation
import Testing
@testable import AgentBarCore

/// Shape copied from the live 2026-10-04 response; values made up.
private let cursorFixture = """
{"billingCycleStart":"2026-10-04T08:08:25.000Z","billingCycleEnd":"2026-11-04T08:08:25.000Z",
 "membershipType":"pro_plus","limitType":"user","isUnlimited":false,
 "individualUsage":{
   "plan":{"enabled":true,"used":2975,"limit":7000,"remaining":4025,
           "breakdown":{"included":2975,"bonus":0,"total":2975},
           "autoPercentUsed":10,"apiPercentUsed":32.5,"totalPercentUsed":42.5},
   "onDemand":{"enabled":true,"used":320,"limit":null,"remaining":null}},
 "teamUsage":{}}
"""

/// Shape copied from the live 2026-10-04 GetSandUsageStatus response; values made up.
private let grokFixture = """
{"currentPeriodStart":"2026-10-04T08:10:04.556Z","nextResetTimestampUtc":"2026-10-11T08:10:04.556Z",
 "usagePercent":4.5,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,
 "grokPlanLabel":"SuperGrok","cursorPlanName":"Pro+","billingBrand":"BILLING_BRAND_CURSOR"}
"""

private func reply(_ status: Int, _ json: String) -> (URLRequest) throws -> HTTPResponse {
    { _ in HTTPResponse(status: status, data: Data(json.utf8), headers: [:]) }
}

@Suite struct CursorUsageFetcherTests {
    let now = ISO8601.parse("2026-10-14T08:08:25.000Z")!
    let creds = CursorCredentials(accessToken: "tok.en.sig", userID: "user_01ABC",
                                  expiresAt: nil, membershipType: "pro")

    @Test func mapsPlanPoolsIntoSessionSlotAndSendsCookie() async throws {
        let transport = MockTransport(status: 200, json: cursorFixture)
        let snap = try await CursorUsageFetcher.fetch(credentials: creds, transport: transport, now: now)

        let start = ISO8601.parse("2026-10-04T08:08:25.000Z"), end = ISO8601.parse("2026-11-04T08:08:25.000Z")
        #expect(snap.session == nil) // the total hides a full API pool, so pools replace it
        #expect(snap.scopedSession == [
            RateWindow(usedPercent: 32.5, resetsAt: end, label: "api", startsAt: start, periodLabel: "mo"),
            RateWindow(usedPercent: 10, resetsAt: end, label: "auto", startsAt: start, periodLabel: "mo"),
        ])
        #expect(snap.worstSession?.usedPercent == 32.5) // the row shows the fuller pool
        #expect(snap.weekly == nil)
        #expect(snap.planLabel == "pro_plus")
        #expect(snap.spendSummary == "on-demand $3.20")
        #expect(snap.fetchedAt == now)

        let req = transport.requests[0]
        #expect(req.url?.absoluteString == "https://cursor.com/api/usage-summary")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user_01ABC%3A%3Atok.en.sig")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "AgentBar")
        #expect(req.httpShouldHandleCookies == false)
    }

    @Test func noSpendWhenOnDemandDisabledOrZero() async throws {
        for onDemand in [#"{"enabled":false,"used":500}"#, #"{"enabled":true,"used":0}"#] {
            let json = #"{"membershipType":"pro","individualUsage":{"plan":{"totalPercentUsed":5},"onDemand":\#(onDemand)}}"#
            let snap = try await CursorUsageFetcher.fetch(
                credentials: creds, transport: MockTransport(status: 200, json: json), now: now)
            #expect(snap.spendSummary == nil)
        }
    }

    @Test func missingCycleDatesKeepPercentWithoutReset() async throws {
        let json = #"{"individualUsage":{"plan":{"totalPercentUsed":7}}}"#
        let snap = try await CursorUsageFetcher.fetch(
            credentials: creds, transport: MockTransport(status: 200, json: json), now: now)
        #expect(snap.session?.usedPercent == 7) // no pools: the total is the fallback
        #expect(snap.scopedSession.isEmpty)
        #expect(snap.session?.resetsAt == nil)
        #expect(snap.session?.startsAt == nil)
        #expect(snap.planLabel == "pro") // falls back to the stored membership type
    }

    @Test func missingPlanPercentIsDecodingError() async {
        await #expect(throws: FetchError.decoding("usage-summary has no individualUsage.plan")) {
            try await CursorUsageFetcher.fetch(
                credentials: creds, transport: MockTransport(status: 200, json: #"{"teamUsage":{}}"#), now: now)
        }
        await #expect(throws: FetchError.decoding("usage-summary has no plan usage percent")) {
            try await CursorUsageFetcher.fetch(
                credentials: creds, transport: MockTransport(status: 200, json: #"{"individualUsage":{"plan":{"used":5}}}"#),
                now: now)
        }
    }

    @Test func mapsHTTPFailures() async {
        await #expect(throws: FetchError.unauthorized) {
            try await CursorUsageFetcher.fetch(credentials: creds, transport: MockTransport(status: 401, json: "{}"), now: now)
        }
        await #expect(throws: FetchError.unauthorized) {
            try await CursorUsageFetcher.fetch(credentials: creds, transport: MockTransport(status: 403, json: "{}"), now: now)
        }
        await #expect(throws: FetchError.rateLimited(retryAfter: now.addingTimeInterval(30))) {
            try await CursorUsageFetcher.fetch(
                credentials: creds, transport: MockTransport(status: 429, json: "{}", headers: ["Retry-After": "30"]), now: now)
        }
        await #expect(throws: FetchError.server(500)) {
            try await CursorUsageFetcher.fetch(credentials: creds, transport: MockTransport(status: 500, json: "{}"), now: now)
        }
        await #expect(throws: FetchError.decoding("malformed JSON in usage response")) {
            try await CursorUsageFetcher.fetch(credentials: creds, transport: MockTransport(status: 200, json: "<html>"), now: now)
        }
    }

    @Test func mapsGrokWeeklyLimitIntoWeeklySlot() async throws {
        let transport = MockTransport([reply(200, cursorFixture), reply(200, grokFixture)])
        let snap = try await CursorUsageFetcher.fetch(credentials: creds, transport: transport, now: now)

        #expect(snap.worstSession?.usedPercent == 32.5) // monthly plan stays in the session slot
        #expect(snap.weekly == RateWindow(
            usedPercent: 4.5, resetsAt: ISO8601.parse("2026-10-11T08:10:04.556Z"), label: "Grok",
            startsAt: ISO8601.parse("2026-10-04T08:10:04.556Z")))

        let req = transport.requests[1]
        #expect(req.url?.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")
        #expect(req.httpMethod == "POST")
        #expect(req.httpBody == Data("{}".utf8))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok.en.sig")
        #expect(req.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(req.httpShouldHandleCookies == false)
    }

    @Test func grokFailureOrNoAllowanceKeepsMonthlyReading() async throws {
        let noAllowance = #"{"usagePercent":0,"includedLimitZero":true}"#
        for grok in [reply(500, "{}"), reply(401, "{}"), reply(200, "<html>"), reply(200, noAllowance)] {
            let snap = try await CursorUsageFetcher.fetch(
                credentials: creds, transport: MockTransport([reply(200, cursorFixture), grok]), now: now)
            #expect(snap.worstSession?.usedPercent == 32.5)
            #expect(snap.weekly == nil)
        }
    }
}
