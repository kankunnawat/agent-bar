import Foundation

public enum CodexUsageFetcher {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(
        accessToken: String,
        accountID: String?,
        transport: any HTTPTransport,
        now: Date
    ) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentBar", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let response = try await transport.send(request)
        try response.requireOK(now: now)
        guard let anyRoot = try? JSONSerialization.jsonObject(with: response.data) else {
            throw FetchError.decoding("malformed JSON in usage response")
        }
        guard let root = anyRoot as? [String: Any] else {
            throw FetchError.decoding("usage response is not a JSON object")
        }
        let general = split(root["rate_limit"])
        let additional = parseAdditional(root["additional_rate_limits"])
        return UsageSnapshot(
            session: general.session,
            weekly: general.weekly,
            scopedSession: additional.compactMap(\.session),
            scopedWeekly: additional.compactMap(\.weekly),
            spendSummary: creditsSummary(root["credits"]),
            planLabel: root["plan_type"] as? String,
            fetchedAt: now)
    }

    private static func window(_ value: Any?) -> RateWindow? {
        guard let dict = value as? [String: Any], let used = number(dict["used_percent"]) else { return nil }
        return RateWindow(usedPercent: used, resetsAt: number(dict["reset_at"]).map(Date.init(timeIntervalSince1970:)))
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    /// The window slots are positional, not semantic: a plan whose only
    /// general limit is weekly (prolite) reports it in `primary_window` with
    /// `secondary_window` null. Bucket by `limit_window_seconds`, falling back
    /// to slot position when the field is absent.
    private static func split(_ value: Any?) -> (session: RateWindow?, weekly: RateWindow?) {
        let rateLimit = value as? [String: Any]
        var session: RateWindow?
        var weekly: RateWindow?
        for (key, slotIsSession) in [("primary_window", true), ("secondary_window", false)] {
            guard let dict = rateLimit?[key] as? [String: Any], let parsed = window(dict) else { continue }
            let isSession = number(dict["limit_window_seconds"]).map { $0 < 24 * 3600 } ?? slotIsSession
            if isSession { session = session ?? parsed } else { weekly = weekly ?? parsed }
        }
        return (session, weekly)
    }

    private static func parseAdditional(_ value: Any?) -> [(session: RateWindow?, weekly: RateWindow?)] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["limit_name"] as? String else { return nil }
            var (session, weekly) = split(entry["rate_limit"])
            session?.label = name
            weekly?.label = name
            if session == nil, weekly == nil { return nil }
            return (session, weekly)
        }
    }

    /// nil unless the account actually has credits — dormant like Claude spend.
    private static func creditsSummary(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        let hasCredits = dict["has_credits"] as? Bool ?? false
        let balance = dict["balance"] as? String
        guard hasCredits || (balance.flatMap(Double.init) ?? 0) > 0 else { return nil }
        return "credits \(balance ?? "0")"
    }
}
