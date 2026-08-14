public import Foundation

/// Errors thrown by ``VRoidHubClient``.
public enum VRoidHubError: Error, Sendable {
    /// The user cancelled the sign-in flow.
    case authenticationCancelled
    /// The `state` parameter returned by the authorization server did not match.
    case invalidOAuthState
    /// The sign-in flow failed before an access token could be obtained.
    case authenticationFailed
    /// The configuration is not usable for the requested operation.
    case invalidConfiguration(String)
    /// No valid session, or the API rejected the access token.
    case unauthorized
    case forbidden
    case notFound
    /// Too many requests. `retryAfter` is derived from the `Retry-After` header when present.
    case rateLimited(retryAfter: Date?)
    /// The response could not be interpreted.
    case invalidResponse
    /// An error returned by the VRoid Hub API.
    case api(code: String, message: String)
    case downloadFailed
    case cacheFailed
}
