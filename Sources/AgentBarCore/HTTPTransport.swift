import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public var headers: [String: String]
    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Maps a non-200 status to the shared `FetchError` every usage fetcher reports.
    public func requireOK(now: Date) throws {
        switch status {
        case 200: return
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited(retryAfter: RetryAfter.parse(header("Retry-After"), now: now))
        default: throw FetchError.server(status)
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return HTTPResponse(status: 0, data: data)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(status: http.statusCode, data: data, headers: headers)
    }
}
