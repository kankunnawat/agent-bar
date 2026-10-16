import Foundation

public enum CodexTokenRefresher {
    static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public static func refresh(
        authFileURL: URL,
        credentials: CodexCredentials,
        transport: any HTTPTransport,
        now: Date
    ) async throws -> CodexCredentials {
        guard let refreshToken = credentials.refreshToken else {
            throw FetchError.credentialsMissing("no refresh_token in auth.json")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ] as [String: String])

        let response = try await transport.send(request)
        switch response.status {
        case 200: break
        case 400, 401, 403:
            Log.refresh.error("codex token refresh unauthorized (status \(response.status))")
            throw FetchError.unauthorized
        default:
            Log.refresh.error("codex token refresh failed (status \(response.status))")
            throw FetchError.server(response.status)
        }
        guard
            let body = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let newAccess = body["access_token"] as? String, !newAccess.isEmpty
        else {
            throw FetchError.decoding("refresh response missing access_token")
        }
        let newRefresh = (body["refresh_token"] as? String) ?? refreshToken
        let newIDToken = body["id_token"] as? String

        try writeBack(authFileURL: authFileURL, accessToken: newAccess,
                      refreshToken: newRefresh, idToken: newIDToken, now: now)

        var updated = credentials
        updated.accessToken = newAccess
        updated.refreshToken = newRefresh
        updated.lastRefresh = now
        if updated.accountID == nil, let newIDToken {
            updated.accountID = CodexCredentials.accountID(fromIDToken: newIDToken)
        }
        return updated
    }

    /// Rewrites auth.json in place, preserving keys we don't understand
    /// (the Codex CLI owns this file; we only update what we rotated).
    private static func writeBack(
        authFileURL: URL, accessToken: String, refreshToken: String,
        idToken: String?, now: Date
    ) throws {
        var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: authFileURL)) as? [String: Any]) ?? [:]
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        tokens["refresh_token"] = refreshToken
        if let idToken { tokens["id_token"] = idToken }
        root["tokens"] = tokens
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        root["last_refresh"] = f.string(from: now)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let tempURL = authFileURL.deletingLastPathComponent()
            .appendingPathComponent(".auth.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        do {
            _ = try FileManager.default.replaceItemAt(authFileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFileURL.path)
    }
}
