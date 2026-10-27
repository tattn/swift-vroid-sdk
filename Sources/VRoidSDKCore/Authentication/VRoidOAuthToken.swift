#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The OAuth token of a signed-in session. Persist it securely (it is
/// `Codable`) and send API requests ``VRoidHubRequest/authorized(by:)`` its
/// ``accessToken``.
public struct VRoidOAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether to refresh the token (``VRoidHubAPI/tokenRefresh(_:)``) before
    /// using it. A small leeway avoids sending requests with a token that
    /// expires in flight.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}
