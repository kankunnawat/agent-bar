import Foundation

public struct ClaudeCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now > expiresAt
    }

    /// Payload shape (keychain item and .credentials.json are identical):
    /// { "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" (epoch ms),
    ///   "scopes", "subscriptionType" } }
    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let anyRoot = try? JSONSerialization.jsonObject(with: data) else {
            throw FetchError.decoding("malformed JSON in credentials")
        }
        guard
            let root = anyRoot as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
        else {
            throw FetchError.decoding("claudeAiOauth.accessToken missing")
        }
        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// Keychain first (every candidate service name for the config dir, keeping
    /// the credential with the latest expiry), then <dir>/.credentials.json.
    /// Keychain denial is surfaced as `FetchError.keychainDenied` so the UI can
    /// distinguish it from "no credentials anywhere".
    ///
    /// Latest-expiry-wins assumes every candidate slot holds the SAME account
    /// (a stale duplicate from a config-dir-env quirk). When the slots disagree
    /// on `subscriptionType` they hold different accounts — seen live 2026-08-27
    /// when another app rewrote the bare slot — and picking either would render
    /// the wrong account's usage, so that is a fault, not a race.
    public static func load(
        configDir: String,
        homeDir: String,
        keychainRead: (String) -> KeychainReadResult = ClaudeKeychainCLI.readGenericPassword
    ) throws -> ClaudeCredentials {
        let services = ClaudeKeychain.serviceNames(forConfigDir: configDir, homeDir: homeDir)
        var found: [ClaudeCredentials] = []
        var denied = false
        for service in services {
            switch keychainRead(service) {
            case .found(let data):
                if let creds = try? parse(data) { found.append(creds) }
            case .denied:
                denied = true
            case .notFound:
                break
            }
        }
        let types = Set(found.compactMap(\.subscriptionType))
        if types.count > 1 {
            throw FetchError.conflictingCredentials(
                "keychain holds two accounts (\(types.sorted().joined(separator: " vs "))) — re-login claude")
        }
        // A credential without an expiry never expires — treat as freshest.
        let best = found.max {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
        if let best { return best }
        if denied { throw FetchError.keychainDenied }
        let fileURL = URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: fileURL) {
            return try parse(data)
        }
        throw FetchError.credentialsMissing(
            "no keychain item '\(services.joined(separator: "' / '"))' and no .credentials.json in \(configDir)")
    }
}
