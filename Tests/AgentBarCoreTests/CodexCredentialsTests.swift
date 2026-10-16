import Foundation
import Testing
@testable import AgentBarCore

/// Builds an unsigned JWT whose payload carries the chatgpt_account_id claim.
private func makeIDToken(accountID: String) -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)"},"email":"x@y.z"}"#
    return b64url(#"{"alg":"none"}"#) + "." + b64url(payload) + ".sig"
}

@Suite struct CodexCredentialsTests {
    @Test func parsesSnakeCaseTokens() throws {
        let json = """
        {"tokens":{"access_token":"at-1","refresh_token":"rt-1","account_id":"acct-1",
        "id_token":"\(makeIDToken(accountID: "acct-jwt"))"},"last_refresh":"2026-07-01T00:00:00Z"}
        """
        let c = try CodexCredentials.parse(Data(json.utf8))
        #expect(c.accessToken == "at-1")
        #expect(c.refreshToken == "rt-1")
        #expect(c.accountID == "acct-1")           // explicit account_id wins over JWT
        #expect(c.lastRefresh == ISO8601.parse("2026-07-01T00:00:00Z"))
        #expect(!c.isAPIKey)
    }

    @Test func parsesCamelCaseAndFallsBackToJWTAccountID() throws {
        let json = """
        {"tokens":{"accessToken":"at-2","refreshToken":"rt-2",
        "idToken":"\(makeIDToken(accountID: "acct-from-jwt"))"}}
        """
        let c = try CodexCredentials.parse(Data(json.utf8))
        #expect(c.accessToken == "at-2")
        #expect(c.accountID == "acct-from-jwt")
    }

    @Test func apiKeyModeUsesKeyAsToken() throws {
        let c = try CodexCredentials.parse(Data(#"{"OPENAI_API_KEY":"sk-proj-123"}"#.utf8))
        #expect(c.accessToken == "sk-proj-123")
        #expect(c.isAPIKey)
        #expect(!c.needsRefresh(now: .distantFuture))
    }

    @Test func needsRefreshAfterEightDays() throws {
        let json = #"{"tokens":{"access_token":"at","refresh_token":"rt"},"last_refresh":"2026-07-01T00:00:00Z"}"#
        let c = try CodexCredentials.parse(Data(json.utf8))
        let base = ISO8601.parse("2026-07-01T00:00:00Z")!
        #expect(!c.needsRefresh(now: base.addingTimeInterval(7 * 86400)))
        #expect(c.needsRefresh(now: base.addingTimeInterval(9 * 86400)))
    }

    @Test func missingLastRefreshMeansNeedsRefresh() throws {
        let c = try CodexCredentials.parse(Data(#"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#.utf8))
        #expect(c.needsRefresh(now: Date(timeIntervalSince1970: 0)))
    }

    @Test func garbageThrows() {
        #expect(throws: FetchError.self) { try CodexCredentials.parse(Data("{}".utf8)) }
    }

    @Test func jwtExtraction() {
        #expect(CodexCredentials.accountID(fromIDToken: makeIDToken(accountID: "a-1")) == "a-1")
        #expect(CodexCredentials.accountID(fromIDToken: "not.a.jwt") == nil)
        #expect(CodexCredentials.accountID(fromIDToken: "nodots") == nil)
    }
}
