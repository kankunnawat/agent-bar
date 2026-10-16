import CryptoKit
import Foundation
import Security

public enum ClaudeKeychain {
    public static let baseService = "Claude Code-credentials"

    /// Canonical service name for a config dir — used as the token-cache key.
    public static func serviceName(forConfigDir path: String, homeDir: String) -> String {
        serviceNames(forConfigDir: path, homeDir: homeDir)[0]
    }

    /// All service names the CLI may store this dir's credentials under.
    /// Non-default dirs use "<base>-<first 8 hex of SHA-256(absolute path,
    /// no trailing slash)>". The default dir (~/.claude) has TWO candidates:
    /// the CLI writes the bare name when CLAUDE_CONFIG_DIR is unset, but the
    /// hashed name when the env var is set explicitly — even when it points
    /// at ~/.claude (observed live 2026-07-17).
    public static func serviceNames(forConfigDir path: String, homeDir: String) -> [String] {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let hashed = "\(baseService)-\(hex.prefix(8))"
        if normalized == homeDir + "/.claude" { return [baseService, hashed] }
        return [hashed]
    }
}

public enum KeychainReadResult: Sendable, Equatable {
    case found(Data)
    case notFound
    case denied(Int32)
}

public struct KeychainItem: Sendable {
    public let account: String?
    public let modified: Date?
    public init(account: String?, modified: Date?) {
        self.account = account
        self.modified = modified
    }
}

extension ClaudeKeychain {
    /// Duplicate items on one service exist in the wild (observed live
    /// 2026-07-03: a stale acct="unknown" item shadowing the CLI's).
    /// Prefer the item written by the current console user — the CLI keys
    /// its own reads/writes on the username — else take the newest.
    /// Returns the index of the winning item.
    public static func select(_ items: [KeychainItem], currentUser: String) -> Int? {
        let indexed = Array(items.enumerated())
        let pool = indexed.filter { $0.element.account == currentUser }
        let candidates = pool.isEmpty ? indexed : pool
        return candidates
            .max { ($0.element.modified ?? .distantPast) < ($1.element.modified ?? .distantPast) }?
            .offset
    }

    /// Reads the best-matching generic-password item for `service` in two
    /// phases: batch data reads fail with errSecParam (observed live, and
    /// macOS never shows the consent prompt for multi-item data requests),
    /// so list attributes+refs first, pick the item, then read only that
    /// item's data — the single-item read raises the consent prompt.
    public static func readGenericPassword(service: String) -> KeychainReadResult {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        switch listStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .notFound
        default:
            Log.keychain.error("keychain list for \(service, privacy: .public) failed: OSStatus \(listStatus)")
            return .denied(listStatus)
        }
        let dicts = (listResult as? [[String: Any]]) ?? []
        let items = dicts.map { dict in
            KeychainItem(
                account: dict[kSecAttrAccount as String] as? String,
                modified: dict[kSecAttrModificationDate as String] as? Date)
        }
        guard let index = select(items, currentUser: NSUserName()),
              let ref = dicts[index][kSecValueRef as String] else { return .notFound }

        let dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchItemList as String: [ref],
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var dataResult: AnyObject?
        let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
        switch dataStatus {
        case errSecSuccess:
            guard let data = dataResult as? Data else { return .notFound }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            Log.keychain.error("keychain read for \(service, privacy: .public) failed: OSStatus \(dataStatus)")
            return .denied(dataStatus)
        }
    }
}
