import Foundation
@testable import AgentBarCore

/// Queue-based mock: each send() pops the next handler.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(URLRequest) throws -> HTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ handlers: [(URLRequest) throws -> HTTPResponse]) { self.handlers = handlers }

    convenience init(status: Int, json: String, headers: [String: String] = [:]) {
        self.init([{ _ in HTTPResponse(status: status, data: Data(json.utf8), headers: headers) }])
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try lock.withLock {
            requests.append(request)
            precondition(!handlers.isEmpty, "MockTransport exhausted")
            let handler = handlers.count == 1 ? handlers[0] : handlers.removeFirst()
            return try handler(request)
        }
    }
}
