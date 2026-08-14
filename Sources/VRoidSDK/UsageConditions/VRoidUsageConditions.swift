import Foundation

/// Normalized conditions of use for a character model.
///
/// VRM 0.x models expose conditions through the `license` field and VRM 1.0
/// models through `vrm_meta`; this type unifies both for display purposes.
/// Conditions the uploader did not set are `.unspecified`, and values the SDK
/// does not recognize are preserved as `.unknown` — never interpret either as
/// permission. The wording shown to users is the application's responsibility
/// (official approval requires labels that match VRoid Hub's own).
public struct VRoidUsageConditions: Sendable, Equatable {
    public enum Permission: Sendable, Equatable {
        case allowed
        case disallowed
        /// The uploader has not set this condition (VRM 0.x `default`, or a
        /// VRM 1.0 field that is absent). Present it as unset.
        case unspecified
        case unknown(String)
    }

    public enum CreditRequirement: Sendable, Equatable {
        case required
        case unnecessary
        case unspecified
        case unknown(String)
    }

    public enum CharacterizationPermission: Sendable, Equatable {
        case authorOnly
        case separatelyLicensedPersonOnly
        case everyone
        case unspecified
        case unknown(String)
    }

    public enum PersonalCommercialUse: Sendable, Equatable {
        case allowed
        case profitAllowed
        case nonprofitAllowed
        case disallowed
        case unspecified
        case unknown(String)
    }

    public let modification: Permission
    public let redistribution: Permission
    public let credit: CreditRequirement
    public let characterization: CharacterizationPermission
    public let sexualExpression: Permission
    public let violentExpression: Permission
    /// `nil` for VRM 0.x, where this condition does not exist.
    public let politicalOrReligiousUsage: Permission?
    /// `nil` for VRM 0.x, where this condition does not exist.
    public let antisocialOrHateUsage: Permission?
    public let corporateCommercialUse: Permission
    public let personalCommercialUse: PersonalCommercialUse
    /// `nil` for VRM 0.x, where this condition does not exist.
    public let modifiedRedistribution: Permission?

    // MARK: VRM 0.x

    public init(license: VRoidCharacterModelLicense) {
        modification = Self.permission(license.modification)
        redistribution = Self.permission(license.redistribution)
        credit = switch license.credit {
        case nil, "default": .unspecified
        case "necessary": .required
        case "unnecessary": .unnecessary
        case .some(let raw): .unknown(raw)
        }
        characterization = switch license.characterizationAllowedUser {
        case nil, "default": .unspecified
        case "author": .authorOnly
        case "everyone": .everyone
        case .some(let raw): .unknown(raw)
        }
        sexualExpression = Self.permission(license.sexualExpression)
        violentExpression = Self.permission(license.violentExpression)
        politicalOrReligiousUsage = nil
        antisocialOrHateUsage = nil
        corporateCommercialUse = Self.permission(license.corporateCommercialUse)
        personalCommercialUse = switch license.personalCommercialUse {
        case nil, "default": .unspecified
        case "allow": .allowed
        case "profit": .profitAllowed
        case "nonprofit": .nonprofitAllowed
        case "disallow": .disallowed
        case .some(let raw): .unknown(raw)
        }
        modifiedRedistribution = nil
    }

    private static func permission(_ raw: String?) -> Permission {
        switch raw {
        case nil, "default": .unspecified
        case "allow": .allowed
        case "disallow": .disallowed
        case .some(let raw): .unknown(raw)
        }
    }

    // MARK: VRM 1.0

    /// Best-effort normalization of VRM 1.0 metadata. The live API returns
    /// the VRM specification's camelCase keys and values as-is. Absent fields
    /// become `.unspecified`; unrecognized values keep their raw form in
    /// `.unknown`.
    public init?(vrm10Meta meta: JSONValue) {
        guard case .object(let object) = meta else { return nil }
        func string(_ key: String) -> String? {
            object[key]?.stringValue
        }
        func boolPermission(_ key: String) -> Permission {
            switch object[key]?.boolValue {
            case true: .allowed
            case false: .disallowed
            case nil: .unspecified
            }
        }

        let modification = string("modification")
        self.modification = switch modification {
        case "prohibited": .disallowed
        case "allowModification", "allowModificationRedistribution": .allowed
        case .some(let raw): .unknown(raw)
        case nil: .unspecified
        }
        modifiedRedistribution = switch modification {
        case "allowModificationRedistribution": .allowed
        case "prohibited", "allowModification": .disallowed
        case .some(let raw): .unknown(raw)
        case nil: .unspecified
        }

        redistribution = boolPermission("allowRedistribution")

        credit = switch string("creditNotation") {
        case "required": .required
        case "unnecessary": .unnecessary
        case .some(let raw): .unknown(raw)
        case nil: .unspecified
        }

        characterization = switch string("avatarPermission") {
        case "onlyAuthor": .authorOnly
        case "onlySeparatelyLicensedPerson": .separatelyLicensedPersonOnly
        case "everyone": .everyone
        case .some(let raw): .unknown(raw)
        case nil: .unspecified
        }

        sexualExpression = boolPermission("allowExcessivelySexualUsage")
        violentExpression = boolPermission("allowExcessivelyViolentUsage")
        politicalOrReligiousUsage = boolPermission("allowPoliticalOrReligiousUsage")
        antisocialOrHateUsage = boolPermission("allowAntisocialOrHateUsage")

        switch string("commercialUsage") {
        case "personalNonProfit":
            // VRM 1.0's personalNonProfit permits personal NON-commercial use
            // only — it is not the VRM 0.x "nonprofit commercial use" tier.
            personalCommercialUse = .disallowed
            corporateCommercialUse = .disallowed
        case "personalProfit":
            personalCommercialUse = .profitAllowed
            corporateCommercialUse = .disallowed
        case "corporation":
            personalCommercialUse = .allowed
            corporateCommercialUse = .allowed
        case .some(let raw):
            personalCommercialUse = .unknown(raw)
            corporateCommercialUse = .unknown(raw)
        case nil:
            personalCommercialUse = .unspecified
            corporateCommercialUse = .unspecified
        }
    }
}

extension VRoidCharacterModel {
    /// Normalized conditions of use, preferring VRM 1.0 metadata when the
    /// latest version is a VRM 1.0 model.
    ///
    /// Normalization runs on every access; store the result when reading it
    /// repeatedly (e.g. in a view body).
    public var usageConditions: VRoidUsageConditions? {
        if let version = latestCharacterModelVersion,
           version.isVRM1,
           let meta = version.vrmMeta,
           let conditions = VRoidUsageConditions(vrm10Meta: meta) {
            return conditions
        }
        if let license {
            return VRoidUsageConditions(license: license)
        }
        return nil
    }
}
