import Foundation
import Testing
@testable import AgentBarCore

@Suite struct CodexTokenRefresherTests {
    private func makeAuthFile(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func refreshRotatesTokensAndPreservesUnknownKeys() async throws {
        let url = try makeAuthFile("""
        {"tokens":{"access_token":"old-at","refresh_token":"old-rt","custom_field":"keep-me"},
        "last_refresh":"2026-06-01T00:00:00Z","some_future_key":{"a":1}}
        """)
        let transport = MockTransport(status: 200, json:
            #"{"access_token":"new-at","refresh_token":"new-rt","id_token":"x.y.z"}"#)
        let creds = try CodexCredentials.load(homeDir: url.deletingLastPathComponent().path)
        let now = ISO8601.parse("2026-07-03T00:00:00Z")!

        let updated = try await CodexTokenRefresher.refresh(
            authFileURL: url, credentials: creds, transport: transport, now: now)

        #expect(updated.accessToken == "new-at")
        #expect(updated.refreshToken == "new-rt")

        // Request shape
        let req = transport.requests[0]
        #expect(req.url?.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(req.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
        #expect(body?["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(body?["grant_type"] == "refresh_token")
        #expect(body?["refresh_token"] == "old-rt")
        #expect(body?["scope"] == "openid profile email")

        // File round-trip: unknown keys preserved, tokens + last_refresh updated
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let tokens = raw?["tokens"] as? [String: Any]
        #expect(tokens?["access_token"] as? String == "new-at")
        #expect(tokens?["refresh_token"] as? String == "new-rt")
        #expect(tokens?["custom_field"] as? String == "keep-me")
        #expect(raw?["some_future_key"] != nil)
        #expect(raw?["last_refresh"] as? String == "2026-07-03T00:00:00Z")

        // Permissions 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func http401ThrowsUnauthorized() async throws {
        let url = try makeAuthFile(#"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#)
        let creds = try CodexCredentials.load(homeDir: url.deletingLastPathComponent().path)
        let transport = MockTransport(status: 401, json: #"{"error":"refresh_token_expired"}"#)
        await #expect(throws: FetchError.unauthorized) {
            _ = try await CodexTokenRefresher.refresh(
                authFileURL: url, credentials: creds, transport: transport, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func missingRefreshTokenThrows() async throws {
        let url = try makeAuthFile(#"{"OPENAI_API_KEY":"sk-x"}"#)
        let creds = try CodexCredentials.load(homeDir: url.deletingLastPathComponent().path)
        await #expect(throws: FetchError.self) {
            _ = try await CodexTokenRefresher.refresh(
                authFileURL: url, credentials: creds, transport: MockTransport(status: 200, json: "{}"),
                now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func tempFileRemovedWhenRenameFails() async throws {
        // Valid credentials from a real auth file…
        let sourceURL = try makeAuthFile(#"{"tokens":{"access_token":"a","refresh_token":"r"}}"#)
        let creds = try CodexCredentials.load(homeDir: sourceURL.deletingLastPathComponent().path)
        // …but write-back targets an immutable file (uchg flag), so the
        // atomic rename genuinely fails after the temp file was written.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentbar-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blockedTarget = dir.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: blockedTarget)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blockedTarget.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blockedTarget.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let transport = MockTransport(status: 200, json: #"{"access_token":"new-at","refresh_token":"new-rt"}"#)
        await #expect(throws: CocoaError.self) {
            _ = try await CodexTokenRefresher.refresh(
                authFileURL: blockedTarget, credentials: creds, transport: transport, now: Date())
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!leftovers.contains { $0.hasPrefix(".auth.json.tmp-") })
    }
}
