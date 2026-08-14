import Foundation
import Testing
@testable import VRoidSDK

struct TokenManagerTests {
    private func makeManager(
        token: OAuthToken?,
        transport: MockHTTPTransport,
        store: (any TokenStore)? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TokenManager {
        let dateProvider = FixedDateProvider(now: now)
        let oauth = OAuthService(
            api: APIClient(transport: transport, dateProvider: dateProvider),
            credential: VRoidCredential(clientID: "cid", clientSecret: "secret"),
            dateProvider: dateProvider
        )
        let tokenStore: any TokenStore = store ?? InMemoryTokenStore(token: token)
        return TokenManager(store: tokenStore, oauth: oauth, dateProvider: dateProvider)
    }

    private func stubRefresh(_ transport: MockHTTPTransport, accessToken: String) {
        transport.route(method: "POST", path: "/oauth/token") { _ in
            .json("""
            { "access_token": "\(accessToken)", "refresh_token": "r2", "expires_in": 3600, "token_type": "Bearer" }
            """)
        }
    }

    @Test
    func returnsStoredTokenWhileValid() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transport = MockHTTPTransport()
        let manager = makeManager(
            token: OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(3600)),
            transport: transport,
            now: now
        )
        #expect(try await manager.validAccessToken() == "a1")
        #expect(transport.requests.isEmpty)
    }

    @Test
    func refreshesExpiredToken() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transport = MockHTTPTransport()
        stubRefresh(transport, accessToken: "a2")
        let manager = makeManager(
            token: OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(-10)),
            transport: transport,
            now: now
        )
        #expect(try await manager.validAccessToken() == "a2")
        #expect(transport.requests(method: "POST", path: "/oauth/token").count == 1)
    }

    @Test
    func coalescesConcurrentRefreshes() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transport = MockHTTPTransport()
        stubRefresh(transport, accessToken: "a2")
        let manager = makeManager(
            token: OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(-10)),
            transport: transport,
            now: now
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.validAccessToken() }
            }
            var results: [String] = []
            for try await token in group {
                results.append(token)
            }
            return results
        }

        #expect(tokens.allSatisfy { $0 == "a2" })
        #expect(transport.requests(method: "POST", path: "/oauth/token").count == 1)
    }

    @Test
    func reportsPersistenceFailureToAllRefreshWaiters() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let staleToken = OAuthToken(
            accessToken: "a1",
            refreshToken: "r1",
            expiresAt: now.addingTimeInterval(-10)
        )
        let transport = MockHTTPTransport()
        stubRefresh(transport, accessToken: "a2")
        let store = SaveFailingTokenStore(token: staleToken)
        let manager = makeManager(token: staleToken, transport: transport, store: store, now: now)

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await manager.validAccessToken()
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(failures.allSatisfy { $0 })
        #expect(try await manager.currentToken()?.accessToken == "a1")
    }

    @Test
    func skipsRefreshWhenAnotherTaskAlreadyRefreshed() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transport = MockHTTPTransport()
        stubRefresh(transport, accessToken: "a3")
        let manager = makeManager(
            token: OAuthToken(accessToken: "a2", refreshToken: "r1", expiresAt: now.addingTimeInterval(3600)),
            transport: transport,
            now: now
        )
        // A request failed with a token that is no longer current;
        // the manager should hand back the newer token without refreshing.
        let token = try await manager.tokenAfterAuthorizationFailure(staleAccessToken: "a1")
        #expect(token == "a2")
        #expect(transport.requests.isEmpty)
    }

    @Test
    func clearDuringRefreshDoesNotResurrectToken() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiredToken = OAuthToken(
            accessToken: "a1",
            refreshToken: "r1",
            expiresAt: now.addingTimeInterval(-10)
        )
        let transport = MockHTTPTransport()
        let requested = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        transport.route(method: "POST", path: "/oauth/token") { _ in
            requested.continuation.finish()
            // Hold the response until the test signs out, then complete
            // anyway — emulating a transport whose response wins the race
            // against cancellation.
            for await _ in release.stream {}
            return .json("""
            { "access_token": "a2", "refresh_token": "r2", "expires_in": 3600, "token_type": "Bearer" }
            """)
        }
        let store = InMemoryTokenStore(token: expiredToken)
        let manager = makeManager(token: expiredToken, transport: transport, store: store, now: now)

        let refreshWaiter = Task {
            try? await manager.validAccessToken()
        }
        for await _ in requested.stream {}

        try await manager.clear()
        release.continuation.finish()
        _ = await refreshWaiter.value

        // The refresh that completed after sign-out must not be re-saved.
        #expect(try await manager.currentToken() == nil)
        #expect(try store.load() == nil)
    }

    @Test
    func staleRefreshDoesNotOverwriteNewerSession() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiredToken = OAuthToken(
            accessToken: "a1",
            refreshToken: "r1",
            expiresAt: now.addingTimeInterval(-10)
        )
        let transport = MockHTTPTransport()
        let requested = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        transport.route(method: "POST", path: "/oauth/token") { _ in
            requested.continuation.finish()
            for await _ in release.stream {}
            return .json("""
            { "access_token": "a2", "refresh_token": "r2", "expires_in": 3600, "token_type": "Bearer" }
            """)
        }
        let store = InMemoryTokenStore(token: expiredToken)
        let manager = makeManager(token: expiredToken, transport: transport, store: store, now: now)

        let refreshWaiter = Task {
            try await manager.validAccessToken()
        }
        for await _ in requested.stream {}

        // A new sign-in replaces the session while the refresh is in flight.
        let signedInToken = OAuthToken(
            accessToken: "a3",
            refreshToken: "r3",
            expiresAt: now.addingTimeInterval(3600)
        )
        try await manager.replace(signedInToken)
        release.continuation.finish()

        // The stale refresh result must not overwrite the newer session,
        // and waiters receive the newer token.
        #expect(try await refreshWaiter.value == "a3")
        #expect(try store.load() == signedInToken)
    }

    @Test
    func throwsUnauthorizedWithoutSession() async {
        let manager = makeManager(token: nil, transport: MockHTTPTransport())
        let error = await #expect(throws: VRoidHubError.self) {
            _ = try await manager.validAccessToken()
        }
        guard case .unauthorized = error else {
            Issue.record("Expected unauthorized, got \(String(describing: error))")
            return
        }
    }
}

private final class SaveFailingTokenStore: TokenStore {
    private let token: OAuthToken?

    init(token: OAuthToken?) {
        self.token = token
    }

    func load() throws -> OAuthToken? {
        token
    }

    func save(_ token: OAuthToken) throws {
        throw PersistenceError.failed
    }

    func clear() throws {}

    private enum PersistenceError: Error {
        case failed
    }
}
