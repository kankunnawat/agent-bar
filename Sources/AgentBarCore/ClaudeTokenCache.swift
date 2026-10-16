import Foundation

/// In-memory cache of resolved Claude credentials, keyed by keychain service
/// name.
///
/// On macOS 26 a self-signed, non-notarized app is re-prompted for SecItem
/// keychain reads even after "Always Allow" — the OS no longer honors the
/// stored ACL grant (verified live: `/usr/bin/security`, Apple-signed and in
/// the same item ACL, reads silently while AgentBar does not). UsageStore uses
/// `/usr/bin/security` first; this cache still throttles expired-token and
/// fallback SecItem read attempts.
///
/// Read-only by design: nothing is written back, so the Claude-token invariant
/// (never refresh or rotate the CLI's credential) holds.
public enum ClaudeTokenCacheServeResult: Sendable, Equatable {
    case credentials(ClaudeCredentials)
    case failedRead(FetchError)
}

public actor ClaudeTokenCache {
    /// Credential reads happen at most this often per service — every serve
    /// inside the window comes from cache, expired or not. Bounding the cache
    /// age (not just failed-read retries) keeps the app at most 5 minutes
    /// behind a keychain rewrite; an unexpired token served until expiry
    /// showed a swapped-in wrong account for 8 hours (live, 2026-08-28). The
    /// primary `/usr/bin/security` path is silent; the SecItem fallback can
    /// still prompt.
    public static let staleReadBackoff: TimeInterval = 300

    private struct Entry {
        let credentials: ClaudeCredentials?
        let lastAttempt: Date
        let failure: FetchError?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Credentials or a recorded failure served without touching the keychain,
    /// while the last read is younger than `staleReadBackoff`. Returns nil when
    /// a fresh keychain read is warranted.
    public func serve(service: String, now: Date) -> ClaudeTokenCacheServeResult? {
        guard let entry = entries[service],
              now.timeIntervalSince(entry.lastAttempt) < Self.staleReadBackoff else { return nil }
        if let credentials = entry.credentials { return .credentials(credentials) }
        if let failure = entry.failure { return .failedRead(failure) }
        return nil
    }

    public func store(service: String, credentials: ClaudeCredentials, readAt: Date) {
        entries[service] = Entry(credentials: credentials, lastAttempt: readAt, failure: nil)
    }

    /// Keeps any cached credentials so an expired-token row stays informative
    /// through transient read failures — except on a slot conflict, where the
    /// cached credential may belong to the wrong account and serving it would
    /// shadow the conflict error until the token expires.
    public func recordFailedRead(service: String, at: Date, failure: FetchError) {
        var credentials = entries[service]?.credentials
        if case .conflictingCredentials = failure { credentials = nil }
        entries[service] = Entry(credentials: credentials, lastAttempt: at, failure: failure)
    }

    /// Drops the entry so the next read hits the keychain — used on a 401 (token
    /// rotated) and on explicit per-account retry.
    public func invalidate(service: String) {
        entries[service] = nil
    }
}
