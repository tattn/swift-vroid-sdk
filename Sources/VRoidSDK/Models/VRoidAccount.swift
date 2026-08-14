import Foundation

/// The authenticated user's account (`GET /api/account`).
public struct VRoidAccount: Decodable, Sendable {
    public let userDetail: VRoidAccountUserDetail
    public let isDeveloper: Bool?

    public var user: VRoidUser { userDetail.user }

    enum CodingKeys: String, CodingKey {
        case userDetail = "user_detail"
        case isDeveloper = "is_developer"
    }
}

public struct VRoidAccountUserDetail: Decodable, Sendable {
    public let user: VRoidUser
}
