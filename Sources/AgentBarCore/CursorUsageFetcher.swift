import Foundation

/// Cursor plan usage from the endpoint behind cursor.com's own dashboard,
/// plus Grok Bot's weekly limit from the RPC behind its Usage & Billing pane.
/// Both undocumented: a shape change surfaces as a row error, never a crash.
public enum CursorUsageFetcher {
    static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!
    static let grokEndpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    public static func fetch(
        credentials: CursorCredentials, transport: any HTTPTransport, now: Date
    ) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(
            "WorkosCursorSessionToken=\(credentials.userID)%3A%3A\(credentials.accessToken)",
            forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")
        // The cookie above is the whole credential: URLSession must not merge
        // in a Set-Cookie it stored from an earlier response, which would go
        // stale once Cursor rotates its token.
        request.httpShouldHandleCookies = false

        let response = try await transport.send(request)
        try response.requireOK(now: now)
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw FetchError.decoding("malformed JSON in usage response")
        }
        let usage = root["individualUsage"] as? [String: Any]
        guard let plan = usage?["plan"] as? [String: Any] else {
            throw FetchError.decoding("usage-summary has no individualUsage.plan")
        }

        // The billing cycle rides in the session slot. The collapsed row's
        // countdown shows only in the cycle's last 24h; the hover card carries
        // the reset the rest of the month.
        let resetsAt = (root["billingCycleEnd"] as? String).flatMap(ISO8601.parse)
        let startsAt = (root["billingCycleStart"] as? String).flatMap(ISO8601.parse)
        func cycle(_ key: String, label: String?) -> RateWindow? {
            (plan[key] as? NSNumber).map {
                RateWindow(usedPercent: $0.doubleValue, resetsAt: resetsAt, label: label,
                           startsAt: startsAt, periodLabel: "mo")
            }
        }
        // The plan has two pools, and API models stop when the API pool is
        // full however low the total reads (totalPercentUsed weights the much
        // larger Auto pool: 0.13 beside api 3, 2026-10-04). Each pool is a
        // scoped window, so the row, alerts, and icon follow the fuller one
        // and the hover card lists both. Total is the fallback without pools.
        let pools = [cycle("apiPercentUsed", label: "api"), cycle("autoPercentUsed", label: "auto")]
            .compactMap { $0 }
        let total = pools.isEmpty ? cycle("totalPercentUsed", label: nil) : nil
        guard !pools.isEmpty || total != nil else {
            throw FetchError.decoding("usage-summary has no plan usage percent")
        }
        return UsageSnapshot(
            session: total,
            weekly: await grokWeekly(credentials: credentials, transport: transport, now: now),
            scopedSession: pools,
            spendSummary: onDemandSummary(usage?["onDemand"]),
            planLabel: (root["membershipType"] as? String) ?? credentials.membershipType,
            fetchedAt: now)
    }

    /// Grok Bot's weekly limit: a separate pool from the monthly plan above.
    /// nil when the account has no weekly allowance or the call fails — the
    /// monthly reading must not go dark because this second endpoint did.
    static func grokWeekly(
        credentials: CursorCredentials, transport: any HTTPTransport, now: Date
    ) async -> RateWindow? {
        var request = URLRequest(url: grokEndpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        guard let response = try? await transport.send(request),
              (try? response.requireOK(now: now)) != nil,
              let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              root["hasNonZeroIncludedLimit"] as? Bool == true,
              let percent = (root["usagePercent"] as? NSNumber)?.doubleValue
        else { return nil }
        return RateWindow(
            usedPercent: percent,
            resetsAt: (root["nextResetTimestampUtc"] as? String).flatMap(ISO8601.parse),
            label: "Grok",
            startsAt: (root["currentPeriodStart"] as? String).flatMap(ISO8601.parse))
    }

    /// "on-demand $3.20" from cents, only when on-demand is on and used.
    static func onDemandSummary(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any],
              dict["enabled"] as? Bool == true,
              let cents = (dict["used"] as? NSNumber)?.decimalValue, cents > 0
        else { return nil }
        let dollars = (cents / 100).formatted(
            .number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        return "on-demand $\(dollars)"
    }
}
