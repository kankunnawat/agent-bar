import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ClaudeKeychainTests {
    // Hash rule (SHA-256 prefix of the dir path) verified against real Keychain entries.
    @Test func defaultDirUsesUnsuffixedService() {
        #expect(ClaudeKeychain.serviceName(forConfigDir: "/Users/x/.claude", homeDir: "/Users/x")
            == "Claude Code-credentials")
    }

    @Test func nonDefaultDirAppendsSHA256Prefix8() {
        #expect(ClaudeKeychain.serviceName(forConfigDir: "/Users/x/.claude-personal", homeDir: "/Users/x")
            == "Claude Code-credentials-89762802")
        #expect(ClaudeKeychain.serviceName(forConfigDir: "/Users/x/.claude-experimental", homeDir: "/Users/x")
            == "Claude Code-credentials-de5f8052")
    }

    @Test func trailingSlashIsNormalized() {
        #expect(ClaudeKeychain.serviceName(forConfigDir: "/Users/x/.claude-personal/", homeDir: "/Users/x")
            == "Claude Code-credentials-89762802")
        #expect(ClaudeKeychain.serviceName(forConfigDir: "/Users/x/.claude/", homeDir: "/Users/x")
            == "Claude Code-credentials")
    }

    // The CLI uses the bare name only when CLAUDE_CONFIG_DIR is unset; when it
    // is set explicitly — even to ~/.claude — it writes under the hashed name.
    // Hashed-name rule for an explicit ~/.claude verified live 2026-07-17.
    @Test func defaultDirHasBareAndHashedCandidates() {
        #expect(ClaudeKeychain.serviceNames(forConfigDir: "/Users/x/.claude", homeDir: "/Users/x")
            == ["Claude Code-credentials", "Claude Code-credentials-c72cc1ce"])
    }

    @Test func nonDefaultDirHasSingleHashedCandidate() {
        #expect(ClaudeKeychain.serviceNames(forConfigDir: "/Users/x/.claude-personal", homeDir: "/Users/x")
            == ["Claude Code-credentials-89762802"])
    }

    @Test func selectPrefersCurrentUserAccount() {
        let stale = KeychainItem(account: "unknown", modified: Date(timeIntervalSince1970: 100))
        let live = KeychainItem(account: "x", modified: Date(timeIntervalSince1970: 50))
        #expect(ClaudeKeychain.select([stale, live], currentUser: "x") == 1)
    }

    @Test func selectFallsBackToNewest() {
        let old = KeychainItem(account: "unknown", modified: Date(timeIntervalSince1970: 100))
        let new = KeychainItem(account: "other", modified: Date(timeIntervalSince1970: 200))
        #expect(ClaudeKeychain.select([old, new], currentUser: "x") == 1)
    }

    @Test func selectNewestAmongCurrentUserDuplicates() {
        let a = KeychainItem(account: "x", modified: Date(timeIntervalSince1970: 100))
        let b = KeychainItem(account: "x", modified: Date(timeIntervalSince1970: 200))
        #expect(ClaudeKeychain.select([a, b], currentUser: "x") == 1)
    }

    @Test func selectEmptyReturnsNil() {
        #expect(ClaudeKeychain.select([], currentUser: "x") == nil)
    }

    @Test func selectTreatsNilModifiedAsOldest() {
        let undated = KeychainItem(account: "other", modified: nil)
        let dated = KeychainItem(account: "other", modified: Date(timeIntervalSince1970: 1))
        #expect(ClaudeKeychain.select([undated, dated], currentUser: "x") == 1)
        #expect(ClaudeKeychain.select([undated], currentUser: "x") == 0) // sole undated item still wins
    }
}
