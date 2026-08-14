import Foundation

/// Performs authenticated API requests with a single retry after a
/// coalesced token refresh when the API responds with 401.
struct AuthenticatedAPIClient: Sendable {
    private let api: APIClient
    private let tokenManager: TokenManager

    init(api: APIClient, tokenManager: TokenManager) {
        self.api = api
        self.tokenManager = tokenManager
    }

    func get<Payload: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Payload {
        let response = try await send { token in
            api.makeRequest(method: "GET", path: path, query: query, accessToken: token)
        }
        return try api.decodePayload(Payload.self, from: response).payload
    }

    func post<Payload: Decodable>(_ path: String, formBody: [String: String]) async throws -> Payload {
        let response = try await send { token in
            api.makeRequest(method: "POST", path: path, accessToken: token, formBody: formBody)
        }
        return try api.decodePayload(Payload.self, from: response).payload
    }

    func delete(_ path: String) async throws {
        let response = try await send { token in
            api.makeRequest(method: "DELETE", path: path, accessToken: token)
        }
        try api.validate(response)
    }

    // MARK: Pagination

    func page<Element: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> VRoidPage<Element> {
        let response = try await send { token in
            api.makeRequest(method: "GET", path: path, query: query, accessToken: token)
        }
        return try makePage(from: response)
    }

    /// Fetches the page referenced by a `_links.next` URL, refusing URLs that
    /// do not belong to the API origin.
    func page<Element: Decodable & Sendable>(at url: URL) async throws -> VRoidPage<Element> {
        guard Self.isSameOrigin(url, api.baseURL) else {
            throw VRoidHubError.invalidConfiguration("Page URL does not belong to the VRoid Hub API")
        }
        let response = try await send { token in
            api.makeRequest(method: "GET", url: url, accessToken: token)
        }
        return try makePage(from: response)
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host(),
              let rhsHost = rhs.host(),
              lhsHost.caseInsensitiveCompare(rhsHost) == .orderedSame
        else {
            return false
        }
        return effectivePort(of: lhs, scheme: lhsScheme) == effectivePort(of: rhs, scheme: rhsScheme)
    }

    private static func effectivePort(of url: URL, scheme: String) -> Int? {
        if let port = url.port {
            return port
        }
        return switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    private func makePage<Element: Decodable & Sendable>(
        from response: HTTPResponse
    ) throws -> VRoidPage<Element> {
        let (items, links) = try api.decodePayload([Element].self, from: response)
        return VRoidPage(items: items, next: api.resolve(link: links?.next))
    }

    // MARK: Raw access

    /// Sends a request without interpreting the response body, optionally
    /// keeping redirects unfollowed. Used by the model downloader.
    func sendRaw(method: String, path: String, followRedirects: Bool) async throws -> HTTPResponse {
        try await send(followRedirects: followRedirects) { token in
            api.makeRequest(method: method, path: path, accessToken: token)
        }
    }

    func validate(_ response: HTTPResponse) throws {
        try api.validate(response)
    }

    private func send(
        followRedirects: Bool = true,
        _ makeRequest: @Sendable (_ accessToken: String) -> URLRequest
    ) async throws -> HTTPResponse {
        let token = try await tokenManager.validAccessToken()
        let response = try await api.transport.send(makeRequest(token), followRedirects: followRedirects)
        guard response.statusCode == 401 else {
            return response
        }
        let refreshedToken = try await tokenManager.tokenAfterAuthorizationFailure(staleAccessToken: token)
        return try await api.transport.send(makeRequest(refreshedToken), followRedirects: followRedirects)
    }
}
