import Foundation
import VRoidSDKCore

/// Owns the OAuth token lifecycle: persistence, expiration checks, and
/// refresh coalescing (concurrent callers share a single refresh request).
actor TokenManager {
    private let store: any TokenStore
    private let oauth: OAuthService
    private let dateProvider: any DateProviding

    private var cachedToken: VRoidOAuthToken?
    private var didLoadFromStore = false
    private var refreshTask: Task<VRoidOAuthToken, any Error>?

    init(store: any TokenStore, oauth: OAuthService, dateProvider: any DateProviding) {
        self.store = store
        self.oauth = oauth
        self.dateProvider = dateProvider
    }

    func currentToken() throws -> VRoidOAuthToken? {
        if !didLoadFromStore {
            cachedToken = try store.load()
            didLoadFromStore = true
        }
        return cachedToken
    }

    /// Returns an access token, refreshing first if the stored one is expired.
    func validAccessToken() async throws -> String {
        guard let token = try currentToken() else {
            throw VRoidHubError.unauthorized
        }
        if token.isExpired(now: dateProvider.now) {
            return try await refreshCoalesced(staleAccessToken: token.accessToken).accessToken
        }
        return token.accessToken
    }

    /// Called after a 401 response. If another task already refreshed the
    /// token, returns the newer one without issuing a second refresh.
    func tokenAfterAuthorizationFailure(staleAccessToken: String) async throws -> String {
        try await refreshCoalesced(staleAccessToken: staleAccessToken).accessToken
    }

    func replace(_ token: VRoidOAuthToken) throws {
        try store.save(token)
        cachedToken = token
        didLoadFromStore = true
    }

    func clear() throws {
        cachedToken = nil
        didLoadFromStore = true
        refreshTask?.cancel()
        refreshTask = nil
        try store.clear()
    }

    private func refreshCoalesced(staleAccessToken: String) async throws -> VRoidOAuthToken {
        guard let current = try currentToken() else {
            throw VRoidHubError.unauthorized
        }
        if current.accessToken != staleAccessToken {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { [oauth] in
            let refreshed = try await oauth.refresh(current)
            // The transport may complete even after clear() cancelled this
            // task; never resurrect a signed-out session.
            try Task.checkCancellation()
            // The session may also have been cleared or replaced (a new
            // sign-in) while the request was in flight; never overwrite a
            // newer token with this stale refresh.
            guard let latest = try currentToken() else {
                throw VRoidHubError.unauthorized
            }
            guard latest.accessToken == current.accessToken else {
                return latest
            }
            try replace(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
