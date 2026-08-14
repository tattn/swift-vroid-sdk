public import Foundation

/// Configuration for ``VRoidHubClient``.
public struct VRoidHubConfiguration: Sendable {
    public var credential: VRoidCredential
    public var callback: OAuthCallback
    public var cache: VRoidCacheConfiguration

    public init(
        credential: VRoidCredential,
        callback: OAuthCallback,
        cache: VRoidCacheConfiguration = VRoidCacheConfiguration()
    ) {
        self.credential = credential
        self.callback = callback
        self.cache = cache
    }
}

/// How the OAuth authorization callback is received.
///
/// The redirect URI must be registered on the VRoid Hub application settings page.
public enum OAuthCallback: Sendable {
    /// Intercepts a custom URL scheme redirect (e.g. `myapp://oauth/vroid`) inside
    /// `ASWebAuthenticationSession`. Recommended on iOS.
    case customScheme(redirectURI: URL)
    /// Starts a one-time HTTP server on the loopback interface (e.g. `http://127.0.0.1`)
    /// and opens the authorization page in the user's default browser.
    /// Recommended on macOS; the default browser keeps the user's existing login session.
    case loopbackServer(redirectURI: URL)

    public var redirectURI: URL {
        switch self {
        case .customScheme(let redirectURI), .loopbackServer(let redirectURI):
            redirectURI
        }
    }
}

/// Settings for the encrypted persistent model cache.
public struct VRoidCacheConfiguration: Sendable {
    /// Maximum number of models kept in the cache. Least recently used models
    /// are evicted first.
    ///
    /// Must be at least 1: the cache is the backing store that
    /// ``VRoidHubClient/modelData(for:)`` reads from, so it cannot be
    /// disabled — a freshly downloaded model would evict itself.
    public var maximumModelCount: Int

    public init(maximumModelCount: Int = 10) {
        precondition(maximumModelCount >= 1, "maximumModelCount must be at least 1")
        self.maximumModelCount = maximumModelCount
    }
}
