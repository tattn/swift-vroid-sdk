public import Foundation

/// A license required to download a character model file.
public struct VRoidDownloadLicense: Decodable, Sendable, Identifiable {
    public let id: String
    public let characterModelID: String
    public let characterModelVersionID: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case characterModelID = "character_model_id"
        case characterModelVersionID = "character_model_version_id"
        case expiresAt = "expires_at"
    }
}

/// A model that can be passed to ``VRoidHubClient/downloadModel(_:)``.
public protocol VRoidCharacterModelDownloadable: Sendable {
    var characterModelID: String { get }
    /// The latest version ID when known. Used to serve cache hits without a
    /// network round trip; when `nil`, a download license request determines
    /// the current version.
    var latestVersionID: String? { get }
}

extension VRoidCharacterModel: VRoidCharacterModelDownloadable {
    public var characterModelID: String { id }
    public var latestVersionID: String? { latestCharacterModelVersion?.id }
}

extension VRoidCharacterModelDetail: VRoidCharacterModelDownloadable {
    public var characterModelID: String { characterModel.id }
    public var latestVersionID: String? { characterModel.latestVersionID }
}
