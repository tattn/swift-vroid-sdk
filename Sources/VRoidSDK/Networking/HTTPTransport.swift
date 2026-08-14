import Foundation

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Boundary for network I/O, injected so tests can run without a server.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, followRedirects: Bool) async throws -> HTTPResponse
}

extension HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request, followRedirects: true)
    }
}
