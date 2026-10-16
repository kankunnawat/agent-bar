import Foundation

public struct CodexCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var accountID: String?
    public var lastRefresh: Date?
    public var isAPIKey: Bool

    /// Codex CLI convention: refresh when last_refresh is older than 8 days
    /// (or unknown). API keys never refresh.
    public func needsRefresh(now: Date) -> Bool {
        if isAPIKey { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) > 8 * 86400
    }

    public static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decoding("auth.json is not a JSON object")
        }
        if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return CodexCredentials(accessToken: key, refreshToken: nil, accountID: nil,
                                    lastRefresh: nil, isAPIKey: true)
        }
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw FetchError.decoding("auth.json has neither OPENAI_API_KEY nor tokens")
        }
        func str(_ snake: String, _ camel: String) -> String? {
            (tokens[snake] as? String) ?? (tokens[camel] as? String)
        }
        guard let accessToken = str("access_token", "accessToken"), !accessToken.isEmpty else {
            throw FetchError.decoding("tokens.access_token missing")
        }
        var accountID = str("account_id", "accountId")
        if accountID == nil, let idToken = str("id_token", "idToken") {
            accountID = Self.accountID(fromIDToken: idToken)
        }
        var lastRefresh: Date?
        if let s = root["last_refresh"] as? String { lastRefresh = ISO8601.parse(s) }
        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: str("refresh_token", "refreshToken"),
            accountID: accountID,
            lastRefresh: lastRefresh,
            isAPIKey: false)
    }

    public static func load(homeDir: String) throws -> CodexCredentials {
        let url = URL(fileURLWithPath: homeDir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw FetchError.credentialsMissing("no auth.json in \(homeDir)")
        }
        return try parse(data)
    }

    /// Decodes the JWT payload and reads the ChatGPT account id claim.
    public static func accountID(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard
            let data = Data(base64Encoded: b64),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = obj["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}
