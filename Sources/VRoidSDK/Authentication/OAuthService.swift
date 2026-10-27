import Foundation
import VRoidSDKCore

/// Performs the OAuth 2.0 requests (token exchange, refresh, revoke) that
/// ``VRoidHubAPI`` describes.
struct OAuthService: Sendable {
    let api: VRoidHubAPI
    let transport: any HTTPTransport

    func authorizationURL(pkce: PKCE, state: String, redirectURI: URL) throws -> URL {
        try api.authorizationURL(codeChallenge: pkce.codeChallenge, state: state, redirectURI: redirectURI)
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws -> VRoidOAuthToken {
        try await perform(api.tokenExchange(authorizationCode: code, codeVerifier: codeVerifier, redirectURI: redirectURI))
    }

    func refresh(_ token: VRoidOAuthToken) async throws -> VRoidOAuthToken {
        try await perform(api.tokenRefresh(token))
    }

    func revoke(accessToken: String) async throws {
        try await perform(api.tokenRevocation(accessToken: accessToken))
    }

    private func perform<Result>(_ call: VRoidHubCall<Result>) async throws -> Result {
        try call.result(from: await transport.send(call.request))
    }
}
