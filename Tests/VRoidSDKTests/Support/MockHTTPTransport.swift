import CryptoKit
import Foundation
import Synchronization
@testable import VRoidSDK
@testable import VRoidSDKCore

/// Routes requests to registered handlers and records every request.
final class MockHTTPTransport: HTTPTransport {
    struct Route {
        let matches: @Sendable (URLRequest) -> Bool
        let respond: @Sendable (URLRequest) async throws -> VRoidHubResponse
    }

    private struct State {
        var routes: [Route] = []
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    func route(
        method: String,
        path: String,
        respond: @escaping @Sendable (URLRequest) async throws -> VRoidHubResponse
    ) {
        let route = Route(matches: Self.matcher(method: method, path: path), respond: respond)
        state.withLock { $0.routes.append(route) }
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func requests(method: String, path: String) -> [URLRequest] {
        let matches = Self.matcher(method: method, path: path)
        return state.withLock { $0.requests.filter(matches) }
    }

    func send(_ request: URLRequest, followRedirects: Bool) async throws -> VRoidHubResponse {
        let route = state.withLock { state in
            state.requests.append(request)
            return state.routes.first { $0.matches(request) }
        }
        guard let route else {
            throw VRoidHubError.invalidResponse
        }
        return try await route.respond(request)
    }

    private static func matcher(method: String, path: String) -> @Sendable (URLRequest) -> Bool {
        { $0.httpMethod == method && $0.url?.path() == path }
    }
}

struct FixedDateProvider: DateProviding {
    var now: Date
}

/// Advances by one second per access so that LRU ordering is deterministic.
final class IncrementingDateProvider: DateProviding {
    private let current: Mutex<Date>

    init(start: Date) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock {
            $0.addTimeInterval(1)
            return $0
        }
    }
}

final class InMemoryTokenStore: TokenStore {
    private let token: Mutex<VRoidOAuthToken?>

    init(token: VRoidOAuthToken? = nil) {
        self.token = Mutex(token)
    }

    func load() throws -> VRoidOAuthToken? {
        token.withLock { $0 }
    }

    func save(_ newToken: VRoidOAuthToken) throws {
        token.withLock { $0 = newToken }
    }

    func clear() throws {
        token.withLock { $0 = nil }
    }
}

struct StaticCacheKeyProvider: CacheKeyProviding {
    let keyData: Data

    init(byte: UInt8 = 0xAB) {
        keyData = Data(repeating: byte, count: 32)
    }

    func key() throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

extension VRoidHubResponse {
    static func json(_ string: String, statusCode: Int = 200) -> VRoidHubResponse {
        VRoidHubResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(string.utf8)
        )
    }
}

func makeTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "VRoidSDKTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

struct TestClientFixture {
    let client: VRoidHubClient
    let transport: MockHTTPTransport
    let directory: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeClientFixture(
    callback: OAuthCallback = .customScheme(redirectURI: URL(string: "myapp://oauth/vroid")!),
    token: VRoidOAuthToken? = VRoidOAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: .distantFuture),
    userAgent: (any AuthorizationUserAgent)? = nil,
    now: Date = Date(timeIntervalSince1970: 1_000_000)
) -> TestClientFixture {
    let transport = MockHTTPTransport()
    let directory = makeTestDirectory()
    let client = makeTestClient(
        transport: transport,
        cacheDirectory: directory,
        callback: callback,
        token: token,
        userAgent: userAgent,
        now: now
    )
    return TestClientFixture(client: client, transport: transport, directory: directory)
}

func makeTestClient(
    transport: MockHTTPTransport,
    cacheDirectory: URL,
    callback: OAuthCallback = .customScheme(redirectURI: URL(string: "myapp://oauth/vroid")!),
    token: VRoidOAuthToken? = nil,
    userAgent: (any AuthorizationUserAgent)? = nil,
    now: Date = Date(timeIntervalSince1970: 1_000_000)
) -> VRoidHubClient {
    VRoidHubClient(
        configuration: VRoidHubConfiguration(
            credential: VRoidCredential(clientID: "cid", clientSecret: "secret"),
            callback: callback
        ),
        transport: transport,
        tokenStore: InMemoryTokenStore(token: token),
        cacheDirectory: cacheDirectory,
        cacheKeyProvider: StaticCacheKeyProvider(),
        dateProvider: FixedDateProvider(now: now),
        userAgent: userAgent
    )
}
