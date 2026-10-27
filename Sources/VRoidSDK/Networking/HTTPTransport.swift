import Foundation
import VRoidSDKCore

/// Boundary for network I/O, injected so tests can run without a server.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, followRedirects: Bool) async throws -> VRoidHubResponse
}

extension HTTPTransport {
    func send(_ request: URLRequest) async throws -> VRoidHubResponse {
        try await send(request, followRedirects: true)
    }

    func send(_ request: VRoidHubRequest) async throws -> VRoidHubResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return try await send(urlRequest, followRedirects: request.followsRedirects)
    }
}
