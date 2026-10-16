import Foundation
import Testing
@testable import AgentBarCore

@Suite struct StatusFetcherTests {
    @Test func onlyIncidentsHaveDescriptions() {
        #expect(StatusIndicator.none.incidentDescription == nil)
        #expect(StatusIndicator.unknown.incidentDescription == nil)
        #expect(StatusIndicator.minor.incidentDescription == "service disruption")
        #expect(StatusIndicator.major.incidentDescription == "service disruption")
        #expect(StatusIndicator.critical.incidentDescription == "service outage")
    }

    @Test func parsesStatuspageIndicator() async {
        let transport = MockTransport(status: 200, json:
            #"{"status":{"indicator":"minor","description":"Partially degraded service"}}"#)
        let s = await StatusFetcher.fetch(provider: .claude, transport: transport)
        #expect(s.indicator == .minor)
        #expect(s.description == "Partially degraded service")
        #expect(transport.requests[0].url?.absoluteString == "https://status.claude.com/api/v2/status.json")
    }

    @Test func codexUsesOpenAIStatusPage() async {
        let transport = MockTransport(status: 200, json:
            #"{"status":{"indicator":"none","description":"All Systems Operational"}}"#)
        _ = await StatusFetcher.fetch(provider: .codex, transport: transport)
        #expect(transport.requests[0].url?.absoluteString == "https://status.openai.com/api/v2/status.json")
    }

    @Test func failureYieldsUnknownNotThrow() async {
        let transport = MockTransport([{ _ in throw URLError(.notConnectedToInternet) }])
        let s = await StatusFetcher.fetch(provider: .claude, transport: transport)
        #expect(s.indicator == .unknown)
    }

    @Test func unrecognizedIndicatorYieldsUnknown() async {
        let transport = MockTransport(status: 200, json: #"{"status":{"indicator":"weird"}}"#)
        let s = await StatusFetcher.fetch(provider: .claude, transport: transport)
        #expect(s.indicator == .unknown)
    }

    @Test func cursorStatusURL() {
        #expect(StatusFetcher.url(for: .cursor).absoluteString == "https://status.cursor.com/api/v2/status.json")
    }
}
