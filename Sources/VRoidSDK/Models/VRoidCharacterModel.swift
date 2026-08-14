public import Foundation

/// A character model as returned by list endpoints.
///
/// Fields other than `id` are deliberately optional: a missing non-optional
/// field would fail decoding for the entire page, while an optional degrades
/// to a local `nil`. The API omits or nulls fields depending on model state
/// (converting, restricted, another user's model). Map to your own
/// non-optional type at the app boundary if you need guarantees.
public struct VRoidCharacterModel: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let isPrivate: Bool?
    public let isDownloadable: Bool?
    public let isHearted: Bool?
    public let portraitImage: VRoidImageSet?
    public let fullBodyImage: VRoidImageSet?
    /// Raw VRM 0.x style conditions of use. `nil` for models that only carry VRM 1.0 metadata.
    public let license: VRoidCharacterModelLicense?
    public let createdAt: Date?
    public let publishedAt: Date?
    public let heartCount: Int?
    public let downloadCount: Int?
    public let character: VRoidCharacter?
    public let latestCharacterModelVersion: VRoidCharacterModelVersion?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isPrivate = "is_private"
        case isDownloadable = "is_downloadable"
        case isHearted = "is_hearted"
        case portraitImage = "portrait_image"
        case fullBodyImage = "full_body_image"
        case license
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case heartCount = "heart_count"
        case downloadCount = "download_count"
        case character
        case latestCharacterModelVersion = "latest_character_model_version"
    }
}

public struct VRoidCharacter: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let user: VRoidUser?
}

public struct VRoidCharacterModelVersion: Decodable, Sendable, Identifiable {
    public let id: String
    /// VRM specification version of the uploaded file (e.g. "0.0", "1.0").
    public let specVersion: String?
    /// Raw VRM 1.0 metadata. The API documents this field as untyped.
    public let vrmMeta: JSONValue?
    public let createdAt: Date?

    public var isVRM1: Bool {
        specVersion?.hasPrefix("1") == true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case specVersion = "spec_version"
        case vrmMeta = "vrm_meta"
        case createdAt = "created_at"
    }
}

/// Raw VRM 0.x style conditions of use, as returned by the API.
///
/// Values are kept as raw strings; use ``VRoidUsageConditions`` for a
/// normalized representation.
public struct VRoidCharacterModelLicense: Decodable, Sendable {
    public let modification: String?
    public let redistribution: String?
    public let credit: String?
    public let characterizationAllowedUser: String?
    public let sexualExpression: String?
    public let violentExpression: String?
    public let corporateCommercialUse: String?
    public let personalCommercialUse: String?

    enum CodingKeys: String, CodingKey {
        case modification
        case redistribution
        case credit
        case characterizationAllowedUser = "characterization_allowed_user"
        case sexualExpression = "sexual_expression"
        case violentExpression = "violent_expression"
        case corporateCommercialUse = "corporate_commercial_use"
        case personalCommercialUse = "personal_commercial_use"
    }
}

/// A character model detail (`GET /api/character_models/{id}`).
public struct VRoidCharacterModelDetail: Decodable, Sendable {
    public let characterModel: VRoidCharacterModel
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case characterModel = "character_model"
        case description
    }
}

/// Options for `GET /api/account/character_models`.
public struct VRoidCharacterModelsOptions: Sendable {
    public enum Publication: String, Sendable {
        case published
        case `private`
        case all
    }

    /// Number of models per page (API default is 20, maximum 100).
    public var count: Int?
    /// Cursor: return models older than this model ID.
    public var maxID: String?
    /// Which publication states to include. Defaults to `.all`; note that the
    /// API's own default is `published`, which hides the user's private models.
    public var publication: Publication

    public init(count: Int? = nil, maxID: String? = nil, publication: Publication = .all) {
        self.count = count
        self.maxID = maxID
        self.publication = publication
    }

    var queryItems: [URLQueryItem] {
        paginationQueryItems(count: count, maxID: maxID)
            + [URLQueryItem(name: "publication", value: publication.rawValue)]
    }
}
