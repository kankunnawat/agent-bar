import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ClaudeTokenCacheTests {
    private let svc = "Claude Code-credentials-abcd1234"

    private func creds(expiresAt: Date?) -> ClaudeCredentials {
        ClaudeCredentials(accessToken: "tok", expiresAt: expiresAt, subscriptionType: "max")
    }

    @Test func servesNothingWhenEmpty() async {
        let cache = ClaudeTokenCache()
        #expect(await cache.serve(service: svc, now: Date()) == nil)
    }

    @Test func servesNonExpiredTokenWithinBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(3600)), readAt: now)
        let within = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        #expect(await cache.serve(service: svc, now: within) == .credentials(creds(expiresAt: now.addingTimeInterval(3600))))
    }

    // Unexpired tokens must still be re-read past the backoff: a keychain
    // rewrite (account swap) otherwise stays invisible until token expiry.
    @Test func reReadsNonExpiredTokenPastBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(28_800)), readAt: now)
        let past = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff + 1)
        #expect(await cache.serve(service: svc, now: past) == nil)
    }

    @Test func servesExpiredTokenWithinBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Expired immediately, but read just now — avoid re-prompting each cycle.
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(-1)), readAt: now)
        let within = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        #expect(await cache.serve(service: svc, now: within) == .credentials(creds(expiresAt: now.addingTimeInterval(-1))))
    }

    @Test func dropsExpiredTokenPastBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(-1)), readAt: now)
        let past = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff + 1)
        #expect(await cache.serve(service: svc, now: past) == nil)
    }

    @Test func invalidateForcesFreshRead() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(3600)), readAt: now)
        await cache.invalidate(service: svc)
        #expect(await cache.serve(service: svc, now: now) == nil)
    }

    @Test func failedReadWithinBackoffSuppressesFreshReadWhenEmpty() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.recordFailedRead(service: svc, at: now, failure: .keychainDenied)

        let within = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        #expect(await cache.serve(service: svc, now: within) == .failedRead(.keychainDenied))
    }

    @Test func failedReadPastBackoffAllowsFreshReadWhenEmpty() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.recordFailedRead(service: svc, at: now, failure: .keychainDenied)

        let past = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff + 1)
        #expect(await cache.serve(service: svc, now: past) == nil)
    }

    @Test func failedReadKeepsExpiredTokenWithinFailureBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = creds(expiresAt: now.addingTimeInterval(-1))
        await cache.store(service: svc, credentials: expired, readAt: now.addingTimeInterval(-600))
        await cache.recordFailedRead(service: svc, at: now, failure: .keychainDenied)

        let within = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        #expect(await cache.serve(service: svc, now: within) == .credentials(expired))
    }

    @Test func storeAfterFailedReadRecoversNormalBehavior() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.recordFailedRead(service: svc, at: now, failure: .keychainDenied)
        let readAt = now.addingTimeInterval(10)
        let expired = creds(expiresAt: now.addingTimeInterval(-1))
        await cache.store(service: svc, credentials: expired, readAt: readAt)

        let within = readAt.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        let past = readAt.addingTimeInterval(ClaudeTokenCache.staleReadBackoff + 1)
        #expect(await cache.serve(service: svc, now: within) == .credentials(expired))
        #expect(await cache.serve(service: svc, now: past) == nil)
    }

    // A slot conflict must not be shadowed by a previously cached credential:
    // that credential may belong to the wrong account.
    @Test func conflictFailureDropsCachedCredentials() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.store(service: svc, credentials: creds(expiresAt: now.addingTimeInterval(-1)), readAt: now - 600)
        let conflict = FetchError.conflictingCredentials("keychain holds two accounts (max vs team) — re-login claude")
        await cache.recordFailedRead(service: svc, at: now, failure: conflict)

        let within = now.addingTimeInterval(ClaudeTokenCache.staleReadBackoff - 1)
        #expect(await cache.serve(service: svc, now: within) == .failedRead(conflict))
    }

    @Test func invalidateClearsFailedReadBackoff() async {
        let cache = ClaudeTokenCache()
        let now = Date(timeIntervalSince1970: 1_000_000)
        await cache.recordFailedRead(service: svc, at: now, failure: .keychainDenied)
        await cache.invalidate(service: svc)

        #expect(await cache.serve(service: svc, now: now) == nil)
    }
}
