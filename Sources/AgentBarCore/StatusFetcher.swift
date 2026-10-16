import Foundation

public enum StatusIndicator: String, Sendable {
    case none, minor, major, critical, unknown

    public var incidentDescription: String? {
        switch self {
        case .minor, .major: "service disruption"
        case .critical: "service outage"
        case .none, .unknown: nil
        }
    }
}

public struct ProviderStatus: Sendable, Equatable {
    public var indicator: StatusIndicator
    public var description: String
    public init(indicator: StatusIndicator, description: String) {
        self.indicator = indicator
        self.description = description
    }
}

public enum StatusFetcher {
    static func url(for provider: Provider) -> URL {
        switch provider {
        case .claude: URL(string: "https://status.claude.com/api/v2/status.json")!
        case .codex: URL(string: "https://status.openai.com/api/v2/status.json")!
        case .cursor: URL(string: "https://status.cursor.com/api/v2/status.json")!
        }
    }

    public static func fetch(provider: Provider, transport: any HTTPTransport) async -> ProviderStatus {
        var request = URLRequest(url: url(for: provider))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let response = try? await transport.send(request),
            response.status == 200,
            let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = root["status"] as? [String: Any],
            let raw = status["indicator"] as? String
        else {
            return ProviderStatus(indicator: .unknown, description: "status unavailable")
        }
        let indicator = StatusIndicator(rawValue: raw) ?? .unknown
        let description = (status["description"] as? String) ?? raw
        return ProviderStatus(indicator: indicator, description: description)
    }
}
