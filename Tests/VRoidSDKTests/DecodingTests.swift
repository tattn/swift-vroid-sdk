import Foundation
import Testing
@testable import VRoidSDK

struct DecodingTests {
    @Test
    func decodesCharacterModelListEnvelope() throws {
        let json = """
        {
          "data": [
            {
              "id": "123",
              "name": "Test Model",
              "is_private": true,
              "is_downloadable": true,
              "is_hearted": false,
              "created_at": "2026-01-02T03:04:05.000+09:00",
              "heart_count": 5,
              "download_count": 2,
              "license": {
                "modification": "disallow",
                "redistribution": "disallow",
                "credit": "necessary",
                "characterization_allowed_user": "author",
                "sexual_expression": "disallow",
                "violent_expression": "mysterious_new_value",
                "corporate_commercial_use": "allow",
                "personal_commercial_use": "profit"
              },
              "character": { "id": "c1", "name": "Chara", "user": { "id": "u1", "name": "User" } },
              "latest_character_model_version": {
                "id": "v1",
                "spec_version": "1.0",
                "vrm_meta": { "avatarPermission": "everyone", "commercialUsage": "personalProfit" }
              }
            }
          ],
          "error": null,
          "_links": { "next": { "href": "/api/account/character_models?max_id=123&count=1" } },
          "rand": "abc"
        }
        """
        let response = HTTPResponse.json(json)
        let client = APIClient(transport: MockHTTPTransport())
        let (models, links) = try client.decodePayload([VRoidCharacterModel].self, from: response)

        #expect(models.count == 1)
        let model = models[0]
        #expect(model.id == "123")
        #expect(model.latestCharacterModelVersion?.isVRM1 == true)
        #expect(model.latestVersionID == "v1")

        let next = client.resolve(link: links?.next)
        #expect(next?.absoluteString == "https://hub.vroid.com/api/account/character_models?max_id=123&count=1")
    }

    @Test
    func decodesDownloadLicense() throws {
        let json = """
        {
          "data": {
            "id": "lic1",
            "character_model_id": "123",
            "character_model_version_id": "v1",
            "expires_at": "2026-08-14T12:00:00.000+09:00"
          },
          "error": null,
          "_links": null,
          "rand": "abc"
        }
        """
        let client = APIClient(transport: MockHTTPTransport())
        let (license, _) = try client.decodePayload(VRoidDownloadLicense.self, from: .json(json))
        #expect(license.id == "lic1")
        #expect(license.characterModelVersionID == "v1")
    }

    @Test
    func mapsAPIErrorEnvelope() {
        let json = """
        { "data": null, "error": { "code": "INVALID_PARAMETER", "message": "bad" }, "_links": null }
        """
        let client = APIClient(transport: MockHTTPTransport())
        let error = #expect(throws: VRoidHubError.self) {
            _ = try client.decodePayload(EmptyPayload.self, from: .json(json, statusCode: 422))
        }
        guard case .api(let code, let message) = error else {
            Issue.record("Expected api error, got \(String(describing: error))")
            return
        }
        #expect(code == "INVALID_PARAMETER")
        #expect(message == "bad")
    }

    @Test
    func mapsRateLimitWithRetryAfterSeconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = APIClient(transport: MockHTTPTransport(), dateProvider: FixedDateProvider(now: now))
        let response = HTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: Data())
        let error = #expect(throws: VRoidHubError.self) {
            try client.validate(response)
        }
        guard case .rateLimited(let retryAfter) = error else {
            Issue.record("Expected rateLimited, got \(String(describing: error))")
            return
        }
        #expect(retryAfter == now.addingTimeInterval(120))
    }

    @Test
    func mapsCommonHTTPStatuses() {
        let client = APIClient(transport: MockHTTPTransport())
        func thrown(_ statusCode: Int) -> VRoidHubError? {
            do {
                try client.validate(HTTPResponse(statusCode: statusCode))
                return nil
            } catch {
                return error as? VRoidHubError
            }
        }
        guard case .unauthorized = thrown(401) else { Issue.record("401"); return }
        guard case .forbidden = thrown(403) else { Issue.record("403"); return }
        guard case .notFound = thrown(404) else { Issue.record("404"); return }
        #expect(thrown(200) == nil)
    }
}

struct UsageConditionsTests {
    @Test
    func normalizesVRM0License() throws {
        let json = """
        {
          "modification": "disallow",
          "redistribution": "default",
          "credit": "necessary",
          "characterization_allowed_user": "everyone",
          "sexual_expression": "allow",
          "violent_expression": "disallow",
          "corporate_commercial_use": "allow",
          "personal_commercial_use": "nonprofit"
        }
        """
        let license = try JSONDecoder().decode(VRoidCharacterModelLicense.self, from: Data(json.utf8))
        let conditions = VRoidUsageConditions(license: license)
        #expect(conditions.modification == .disallowed)
        #expect(conditions.redistribution == .unspecified)
        #expect(conditions.credit == .required)
        #expect(conditions.characterization == .everyone)
        #expect(conditions.sexualExpression == .allowed)
        #expect(conditions.violentExpression == .disallowed)
        #expect(conditions.corporateCommercialUse == .allowed)
        #expect(conditions.personalCommercialUse == .nonprofitAllowed)
    }

    @Test
    func unknownValuesAreNeverTreatedAsAllowed() throws {
        let json = """
        { "modification": "brand_new_value" }
        """
        let license = try JSONDecoder().decode(VRoidCharacterModelLicense.self, from: Data(json.utf8))
        let conditions = VRoidUsageConditions(license: license)
        #expect(conditions.modification == .unknown("brand_new_value"))
        #expect(conditions.modification != .allowed)
    }

    @Test
    func normalizesVRM1Meta() throws {
        let json = """
        {
          "avatarPermission": "onlyAuthor",
          "allowExcessivelyViolentUsage": false,
          "allowExcessivelySexualUsage": true,
          "allowPoliticalOrReligiousUsage": false,
          "allowAntisocialOrHateUsage": true,
          "commercialUsage": "personalNonProfit",
          "creditNotation": "required",
          "allowRedistribution": false,
          "modification": "allowModificationRedistribution"
        }
        """
        let meta = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let conditions = try #require(VRoidUsageConditions(vrm10Meta: meta))
        #expect(conditions.characterization == .authorOnly)
        #expect(conditions.violentExpression == .disallowed)
        #expect(conditions.sexualExpression == .allowed)
        #expect(conditions.politicalOrReligiousUsage == .disallowed)
        #expect(conditions.antisocialOrHateUsage == .allowed)
        // VRM 1.0's personalNonProfit permits personal non-commercial use
        // only; it is not the VRM 0.x "nonprofit commercial use" tier.
        #expect(conditions.personalCommercialUse == .disallowed)
        #expect(conditions.corporateCommercialUse == .disallowed)
        #expect(conditions.credit == .required)
        #expect(conditions.redistribution == .disallowed)
        #expect(conditions.modification == .allowed)
        #expect(conditions.modifiedRedistribution == .allowed)
    }

    @Test
    func missingVRM1FieldsAreUnspecified() throws {
        let meta = try JSONDecoder().decode(JSONValue.self, from: Data("{}".utf8))
        let conditions = try #require(VRoidUsageConditions(vrm10Meta: meta))
        #expect(conditions.modification == .unspecified)
        #expect(conditions.personalCommercialUse == .unspecified)
        #expect(conditions.politicalOrReligiousUsage == .unspecified)
        #expect(conditions.antisocialOrHateUsage == .unspecified)
        #expect(conditions.modifiedRedistribution == .unspecified)
        #expect(conditions.credit == .unspecified)
        #expect(conditions.characterization == .unspecified)
    }

    @Test
    func unrecognizedVRM1ValuesAreUnknownNotUnspecified() throws {
        let json = """
        { "commercialUsage": "someFutureValue", "modification": "someFutureValue" }
        """
        let meta = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let conditions = try #require(VRoidUsageConditions(vrm10Meta: meta))
        #expect(conditions.personalCommercialUse == .unknown("someFutureValue"))
        #expect(conditions.modification == .unknown("someFutureValue"))
    }

    @Test
    func preservesSeparatelyLicensedAvatarPermission() throws {
        let meta = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"avatarPermission":"onlySeparatelyLicensedPerson"}"#.utf8)
        )
        let conditions = try #require(VRoidUsageConditions(vrm10Meta: meta))
        #expect(conditions.characterization == .separatelyLicensedPersonOnly)
    }
}
