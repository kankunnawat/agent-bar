import Foundation

public enum ClaudeUsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(
        accessToken: String,
        transport: any HTTPTransport,
        now: Date
    ) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let response = try await transport.send(request)
        try response.requireOK(now: now)
        guard let anyRoot = try? JSONSerialization.jsonObject(with: response.data) else {
            throw FetchError.decoding("malformed JSON in usage response")
        }
        guard let root = anyRoot as? [String: Any] else {
            throw FetchError.decoding("usage response is not a JSON object")
        }
        let limits = parseLimits(root["limits"])
        let spend = spendSummary(root["spend"])
        guard !limits.isEmpty else {
            return UsageSnapshot(
                session: window(root["five_hour"]),
                weekly: window(root["seven_day"]),
                spendSummary: spend,
                fetchedAt: now)
        }
        return UsageSnapshot(
            session: limits.first { $0.group == "session" && $0.window.label == nil }?.window,
            weekly: limits.first { $0.group == "weekly" && $0.window.label == nil }?.window,
            scopedSession: limits.filter { $0.group == "session" && $0.window.label != nil }.map(\.window),
            scopedWeekly: limits.filter { $0.group == "weekly" && $0.window.label != nil }.map(\.window),
            spendSummary: spend,
            fetchedAt: now)
    }

    private static func window(_ value: Any?) -> RateWindow? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double else { return nil }
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String { resetsAt = ISO8601.parse(s) }
        return RateWindow(usedPercent: utilization, resetsAt: resetsAt)
    }

    private static func parseLimits(_ value: Any?) -> [(group: String, window: RateWindow)] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let group = entry["group"] as? String,
                  let percent = (entry["percent"] as? Double) ?? (entry["percent"] as? Int).map(Double.init)
            else { return nil }
            let resetsAt = (entry["resets_at"] as? String).flatMap(ISO8601.parse)
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            let label = model?["display_name"] as? String
            return (group, RateWindow(usedPercent: percent, resetsAt: resetsAt, label: label))
        }
    }

    /// nil unless spend is enabled or money was actually used — the display
    /// stays dormant on accounts without extra usage.
    private static func spendSummary(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any],
              let used = money(dict["used"]) else { return nil }
        let enabled = dict["enabled"] as? Bool ?? false
        guard enabled || used.amount > 0 else { return nil }
        if let limit = money(dict["limit"]) { return "extra \(used.text) of \(limit.text)" }
        return "extra \(used.text)"
    }

    /// Assumes USD ("$") — the API's currency field is ignored; all observed accounts are USD.
    private static func money(_ value: Any?) -> (amount: Double, text: String)? {
        guard let dict = value as? [String: Any],
              let minor = (dict["amount_minor"] as? Double) ?? (dict["amount_minor"] as? Int).map(Double.init)
        else { return nil }
        let exponent = (dict["exponent"] as? Int) ?? 2
        let amount = minor / pow(10, Double(exponent))
        return (amount, String(format: "$%.\(exponent)f", amount))
    }
}
