import Foundation
import Testing
@testable import AgentBarCore

private let fixture = """
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-xyz",
"expiresAt":1751500000000,"scopes":["user:inference"],"subscriptionType":"max"}}
"""

@Suite struct ClaudeCredentialsTests {
    @Test func parsesKeychainPayload() throws {
        let c = try ClaudeCredentials.parse(Data(fixture.utf8))
        #expect(c.accessToken == "sk-ant-oat01-abc")
        #expect(c.subscriptionType == "max")
        // expiresAt is epoch MILLISECONDS
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_751_500_000))
    }

    @Test func expiryComparesAgainstNow() throws {
        let c = try ClaudeCredentials.parse(Data(fixture.utf8))
        #expect(c.isExpired(now: Date(timeIntervalSince1970: 1_751_500_001)))
        #expect(!c.isExpired(now: Date(timeIntervalSince1970: 1_751_499_999)))
    }

    @Test func missingRootKeyThrowsDecoding() {
        #expect(throws: FetchError.self) { try ClaudeCredentials.parse(Data("{}".utf8)) }
    }

    @Test func emptyAccessTokenRejected() {
        let payload = #"{"claudeAiOauth":{"accessToken":""}}"#
        #expect(throws: FetchError.decoding("claudeAiOauth.accessToken missing")) {
            _ = try ClaudeCredentials.parse(Data(payload.utf8))
        }
    }

    @Test func malformedCredentialsJSONDistinguished() {
        #expect(throws: FetchError.decoding("malformed JSON in credentials")) {
            _ = try ClaudeCredentials.parse(Data("garbage".utf8))
        }
    }

    @Test func loadPrefersKeychainThenFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(fixture.utf8).write(to: dir.appendingPathComponent(".credentials.json"))

        // Keychain miss -> file fallback
        let c = try ClaudeCredentials.load(configDir: dir.path, homeDir: "/nonexistent", keychainRead: { _ in .notFound })
        #expect(c.accessToken == "sk-ant-oat01-abc")

        // Keychain hit wins
        let kc = fixture.replacingOccurrences(of: "sk-ant-oat01-abc", with: "sk-ant-oat01-FROM-KEYCHAIN")
        let c2 = try ClaudeCredentials.load(
            configDir: dir.path, homeDir: "/nonexistent", keychainRead: { _ in .found(Data(kc.utf8)) })
        #expect(c2.accessToken == "sk-ant-oat01-FROM-KEYCHAIN")
    }

    // ~/.claude has two candidate keychain items (bare + hashed service name);
    // the freshest token must win regardless of which item holds it.
    @Test func loadPicksFreshestAcrossDefaultDirCandidates() throws {
        let home = "/Users/x"
        let stale = fixture // expiresAt 1751500000000
        let fresh = fixture
            .replacingOccurrences(of: "sk-ant-oat01-abc", with: "sk-ant-oat01-FRESH")
            .replacingOccurrences(of: "1751500000000", with: "1751600000000")

        let bareStale = try ClaudeCredentials.load(
            configDir: "\(home)/.claude", homeDir: home,
            keychainRead: { service in
                .found(Data((service == "Claude Code-credentials" ? stale : fresh).utf8))
            })
        #expect(bareStale.accessToken == "sk-ant-oat01-FRESH")

        let hashedStale = try ClaudeCredentials.load(
            configDir: "\(home)/.claude", homeDir: home,
            keychainRead: { service in
                .found(Data((service == "Claude Code-credentials" ? fresh : stale).utf8))
            })
        #expect(hashedStale.accessToken == "sk-ant-oat01-FRESH")
    }

    // Latest-expiry-wins is only valid between copies of the SAME account.
    // When the two ~/.claude slots hold different accounts (subscriptionType
    // disagrees — seen live 2026-08-27 when another app rewrote the bare
    // slot), picking either renders the wrong account's usage: fail instead.
    @Test func loadThrowsWhenDefaultDirCandidatesHoldDifferentAccounts() {
        let home = "/Users/x"
        let team = fixture.replacingOccurrences(of: "\"max\"", with: "\"team\"")
        #expect(throws: FetchError.conflictingCredentials(
            "keychain holds two accounts (max vs team) — re-login claude")) {
            _ = try ClaudeCredentials.load(
                configDir: "\(home)/.claude", homeDir: home,
                keychainRead: { service in
                    .found(Data((service == "Claude Code-credentials" ? fixture : team).utf8))
                })
        }
    }

    // A candidate without subscriptionType (older CLI payloads) is not
    // evidence of a different account — no conflict, freshest still wins.
    @Test func loadToleratesMissingSubscriptionTypeOnOneCandidate() throws {
        let home = "/Users/x"
        let untyped = fixture
            .replacingOccurrences(of: ",\"subscriptionType\":\"max\"", with: "")
            .replacingOccurrences(of: "sk-ant-oat01-abc", with: "sk-ant-oat01-UNTYPED")
            .replacingOccurrences(of: "1751500000000", with: "1751600000000")
        let creds = try ClaudeCredentials.load(
            configDir: "\(home)/.claude", homeDir: home,
            keychainRead: { service in
                .found(Data((service == "Claude Code-credentials" ? fixture : untyped).utf8))
            })
        #expect(creds.accessToken == "sk-ant-oat01-UNTYPED")
    }

    @Test func loadUsesRemainingCandidateWhenOneIsMissing() throws {
        let home = "/Users/x"
        let creds = try ClaudeCredentials.load(
            configDir: "\(home)/.claude", homeDir: home,
            keychainRead: { service in
                service == "Claude Code-credentials" ? .notFound : .found(Data(fixture.utf8))
            })
        #expect(creds.accessToken == "sk-ant-oat01-abc")
    }

    @Test func loadThrowsWhenNoSource() {
        #expect(throws: FetchError.self) {
            try ClaudeCredentials.load(configDir: "/nonexistent/dir", homeDir: "/nonexistent", keychainRead: { _ in .notFound })
        }
    }

    @Test func loadThrowsKeychainDenied() {
        #expect(throws: FetchError.keychainDenied) {
            try ClaudeCredentials.load(
                configDir: "/nonexistent/dir", homeDir: "/nonexistent",
                keychainRead: { _ in .denied(-25293) })
        }
    }

    @Test func loadFallsToFileOnNotFound() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = #"{"claudeAiOauth":{"accessToken":"tok-file"}}"#
        try Data(payload.utf8).write(to: dir.appendingPathComponent(".credentials.json"))
        let creds = try ClaudeCredentials.load(
            configDir: dir.path, homeDir: "/nonexistent", keychainRead: { _ in .notFound })
        #expect(creds.accessToken == "tok-file")
    }
}
