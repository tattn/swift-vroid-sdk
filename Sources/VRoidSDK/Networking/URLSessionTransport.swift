import Foundation

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest, followRedirects: Bool) async throws -> HTTPResponse {
        let delegate = followRedirects ? nil : RedirectBlockingDelegate()
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VRoidHubError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }
}

/// Stops automatic redirect handling so that a 302 response is returned as-is.
/// Used for the download endpoint, whose `Location` must be requested without
/// the API authorization headers.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
