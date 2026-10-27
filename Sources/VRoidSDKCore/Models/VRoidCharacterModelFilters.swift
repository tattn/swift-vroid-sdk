#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Usage-condition filters accepted by the hearts and search listings.
///
/// Each field maps to a query parameter; `nil` omits the parameter so the API
/// applies its default, which is derived from the application's settings on
/// the VRoid Hub developer page.
public struct VRoidCharacterModelFilters: Sendable {
    public enum ConditionFilter: String, Sendable {
        case `default`
        case disallow
        case allow
    }

    public enum CharacterizationFilter: String, Sendable {
        case `default`
        case author
        case everyone
    }

    public enum PersonalCommercialUseFilter: String, Sendable {
        case `default`
        case disallow
        case profit
        case nonprofit
    }

    public enum ModificationFilter: String, Sendable {
        case `default`
        case disallow
        case allowModification = "allow_modification"
    }

    public enum CreditFilter: String, Sendable {
        case `default`
        case necessary
        case unnecessary
    }

    public enum BoothPartCategory: String, Sendable {
        case body
        case hair
        case face
        case cloth
        case accessory
    }

    public var isDownloadable: Bool?
    public var characterizationAllowedUser: CharacterizationFilter?
    public var violentExpression: ConditionFilter?
    public var sexualExpression: ConditionFilter?
    public var corporateCommercialUse: ConditionFilter?
    public var personalCommercialUse: PersonalCommercialUseFilter?
    public var politicalOrReligiousUsage: ConditionFilter?
    public var antisocialOrHateUsage: ConditionFilter?
    public var modification: ModificationFilter?
    public var redistribution: ConditionFilter?
    public var credit: CreditFilter?
    public var hasBoothItems: Bool?
    public var boothPartCategories: [BoothPartCategory]

    public init(
        isDownloadable: Bool? = nil,
        characterizationAllowedUser: CharacterizationFilter? = nil,
        violentExpression: ConditionFilter? = nil,
        sexualExpression: ConditionFilter? = nil,
        corporateCommercialUse: ConditionFilter? = nil,
        personalCommercialUse: PersonalCommercialUseFilter? = nil,
        politicalOrReligiousUsage: ConditionFilter? = nil,
        antisocialOrHateUsage: ConditionFilter? = nil,
        modification: ModificationFilter? = nil,
        redistribution: ConditionFilter? = nil,
        credit: CreditFilter? = nil,
        hasBoothItems: Bool? = nil,
        boothPartCategories: [BoothPartCategory] = []
    ) {
        self.isDownloadable = isDownloadable
        self.characterizationAllowedUser = characterizationAllowedUser
        self.violentExpression = violentExpression
        self.sexualExpression = sexualExpression
        self.corporateCommercialUse = corporateCommercialUse
        self.personalCommercialUse = personalCommercialUse
        self.politicalOrReligiousUsage = politicalOrReligiousUsage
        self.antisocialOrHateUsage = antisocialOrHateUsage
        self.modification = modification
        self.redistribution = redistribution
        self.credit = credit
        self.hasBoothItems = hasBoothItems
        self.boothPartCategories = boothPartCategories
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        func append(_ name: String, _ value: String?) {
            if let value {
                items.append(URLQueryItem(name: name, value: value))
            }
        }
        append("is_downloadable", isDownloadable.map(String.init))
        append("characterization_allowed_user", characterizationAllowedUser?.rawValue)
        append("violent_expression", violentExpression?.rawValue)
        append("sexual_expression", sexualExpression?.rawValue)
        append("corporate_commercial_use", corporateCommercialUse?.rawValue)
        append("personal_commercial_use", personalCommercialUse?.rawValue)
        append("political_or_religious_usage", politicalOrReligiousUsage?.rawValue)
        append("antisocial_or_hate_usage", antisocialOrHateUsage?.rawValue)
        append("modification", modification?.rawValue)
        append("redistribution", redistribution?.rawValue)
        append("credit", credit?.rawValue)
        append("has_booth_items", hasBoothItems.map(String.init))
        for category in boothPartCategories {
            items.append(URLQueryItem(name: "booth_part_categories[]", value: category.rawValue))
        }
        return items
    }
}

func paginationQueryItems(count: Int?, maxID: String?) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let count {
        items.append(URLQueryItem(name: "count", value: "\(count)"))
    }
    if let maxID {
        items.append(URLQueryItem(name: "max_id", value: maxID))
    }
    return items
}

/// Options for `GET /api/hearts`.
public struct VRoidHeartsOptions: Sendable {
    /// Number of models per page (API default is 20, maximum 100).
    public var count: Int?
    /// Cursor: return models older than this model ID.
    public var maxID: String?
    public var filters: VRoidCharacterModelFilters

    public init(
        count: Int? = nil,
        maxID: String? = nil,
        filters: VRoidCharacterModelFilters = VRoidCharacterModelFilters()
    ) {
        self.count = count
        self.maxID = maxID
        self.filters = filters
    }

    var queryItems: [URLQueryItem] {
        paginationQueryItems(count: count, maxID: maxID) + filters.queryItems
    }
}

/// Options for `GET /api/staff_picks`.
public struct VRoidStaffPicksOptions: Sendable {
    /// Number of models per page (API default is 20, maximum 100).
    public var count: Int?
    /// Cursor: return models older than this model ID.
    public var maxID: String?

    public init(count: Int? = nil, maxID: String? = nil) {
        self.count = count
        self.maxID = maxID
    }

    var queryItems: [URLQueryItem] {
        paginationQueryItems(count: count, maxID: maxID)
    }
}

/// Options for `GET /api/search/character_models`.
public struct VRoidCharacterModelSearchOptions: Sendable {
    public enum Sort: String, Sendable {
        case relevance = "_score"
        case newestFirst = "first_published_at"
    }

    public var keyword: String
    /// Number of models per page (API default is 20, maximum 100).
    public var count: Int?
    /// Defaults to relevance on the API side when omitted.
    public var sort: Sort?
    public var filters: VRoidCharacterModelFilters

    public init(
        keyword: String,
        count: Int? = nil,
        sort: Sort? = nil,
        filters: VRoidCharacterModelFilters = VRoidCharacterModelFilters()
    ) {
        self.keyword = keyword
        self.count = count
        self.sort = sort
        self.filters = filters
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "keyword", value: keyword)]
        items += paginationQueryItems(count: count, maxID: nil)
        if let sort {
            items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        }
        return items + filters.queryItems
    }
}
