import Foundation

struct OAuthToken: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// A small leeway avoids sending requests with a token that expires in flight.
    func isExpired(now: Date, leeway: TimeInterval = 30) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}
