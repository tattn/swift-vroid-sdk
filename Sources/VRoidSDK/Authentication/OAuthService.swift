import Foundation

/// Builds and performs the OAuth 2.0 requests (authorize URL, token exchange,
/// refresh, revoke) against VRoid Hub.
struct OAuthService: Sendable {
    let api: APIClient
    let credential: VRoidCredential
    let dateProvider: any DateProviding

    private var clientSecret: String {
        credential.clientSecret
    }

    func authorizationURL(pkce: PKCE, state: String, redirectURI: URL) throws -> URL {
        var components = URLComponents(
            url: api.baseURL.appending(path: "/oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credential.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "default"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw VRoidHubError.invalidConfiguration("Could not build the authorization URL")
        }
        return url
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> OAuthToken {
        try await requestToken(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": credential.clientID,
            "client_secret": clientSecret,
            "code_verifier": codeVerifier,
        ], currentRefreshToken: nil, failureError: .authenticationFailed)
    }

    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        try await requestToken(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": credential.clientID,
            "client_secret": clientSecret,
        ], currentRefreshToken: token.refreshToken, failureError: .unauthorized)
    }

    func revoke(accessToken: String) async throws {
        let request = api.makeRequest(
            method: "POST",
            path: "/oauth/revoke",
            accessToken: accessToken,
            formBody: [
                "client_id": credential.clientID,
                "client_secret": clientSecret,
                "token": accessToken,
            ]
        )
        let response = try await api.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw VRoidHubError.invalidResponse
        }
    }

    private func requestToken(
        parameters: [String: String],
        currentRefreshToken: String?,
        failureError: VRoidHubError
    ) async throws -> OAuthToken {
        // The token endpoint speaks plain OAuth, not the API envelope, so
        // failures are mapped here instead of through APIClient.validate.
        let request = api.makeRequest(method: "POST", path: "/oauth/token", formBody: parameters)
        let response = try await api.transport.send(request)
        switch response.statusCode {
        case 200..<300:
            break
        case 400, 401:
            // The grant or the credentials were rejected.
            throw failureError
        case 429:
            throw VRoidHubError.rateLimited(retryAfter: api.retryAfterDate(from: response))
        default:
            // Transient server failures must not be mistaken for a revoked
            // session (restoreSession clears the stored token on unauthorized).
            throw VRoidHubError.invalidResponse
        }
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
            throw VRoidHubError.invalidResponse
        }
        guard let refreshToken = payload.refreshToken ?? currentRefreshToken else {
            throw VRoidHubError.invalidResponse
        }
        return OAuthToken(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            expiresAt: dateProvider.now.addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
