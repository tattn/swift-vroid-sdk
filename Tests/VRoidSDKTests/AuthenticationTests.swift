import Foundation
import Testing
@testable import VRoidSDK
@testable import VRoidSDKCore

@Suite
struct AuthenticationTests {
    @Test
    @MainActor
    func usesEffectiveLoopbackRedirectURIForAuthorizationAndTokenExchange() async throws {
        let effectiveRedirectURI = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let userAgent = MockLoopbackUserAgent(effectiveRedirectURI: effectiveRedirectURI)
        let transport = MockHTTPTransport()
        transport.route(method: "POST", path: "/oauth/token") { request in
            #expect(Self.formValue("redirect_uri", in: request) == effectiveRedirectURI.absoluteString)
            return .json("""
            { "access_token": "a1", "refresh_token": "r1", "expires_in": 3600 }
            """)
        }
        transport.route(method: "GET", path: "/api/account") { _ in
            .json("""
            { "data": { "user_detail": { "user": { "id": "u1" } } }, "error": null, "_links": null }
            """)
        }
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = makeTestClient(
            transport: transport,
            cacheDirectory: directory,
            callback: .loopbackServer(redirectURI: URL(string: "http://127.0.0.1/oauth/callback")!),
            userAgent: userAgent
        )

        let account = try await client.signIn()

        #expect(account.user.id == "u1")
        #expect(userAgent.authorizationRedirectURI == effectiveRedirectURI)
    }

    @Test
    func authenticatesTokenRevocationRequest() async throws {
        let transport = MockHTTPTransport()
        transport.route(method: "POST", path: "/oauth/revoke") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(Self.formValue("token", in: request) == "access-token")
            return VRoidHubResponse(statusCode: 200)
        }
        let dateProvider = FixedDateProvider(now: Date(timeIntervalSince1970: 1_000_000))
        let oauth = OAuthService(
            api: VRoidHubAPI(
                credential: VRoidCredential(clientID: "cid", clientSecret: "secret"),
                dateProvider: dateProvider
            ),
            transport: transport
        )

        try await oauth.revoke(accessToken: "access-token")
    }

    private static func formValue(_ name: String, in request: URLRequest) -> String? {
        // FormBody percent-encodes everything outside the unreserved set,
        // so the body parses as a URL query string.
        guard let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) else {
            return nil
        }
        var components = URLComponents()
        components.percentEncodedQuery = body
        return components.queryItems?.first { $0.name == name }?.value
    }
}

@MainActor
private final class MockLoopbackUserAgent: AuthorizationUserAgent {
    let effectiveRedirectURI: URL
    private(set) var authorizationRedirectURI: URL?

    init(effectiveRedirectURI: URL) {
        self.effectiveRedirectURI = effectiveRedirectURI
    }

    func authenticate(
        redirectURI: URL,
        authorizationURL: @MainActor (URL) throws -> URL
    ) async throws -> URL {
        let url = try authorizationURL(effectiveRedirectURI)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        authorizationRedirectURI = queryItems.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
        let state = try #require(queryItems.first { $0.name == "state" }?.value)
        var callback = URLComponents(url: effectiveRedirectURI, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "state", value: state),
        ]
        return try #require(callback.url)
    }
}
