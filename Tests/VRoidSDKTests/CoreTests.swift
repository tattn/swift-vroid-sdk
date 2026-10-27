import Foundation
import Testing
@testable import VRoidSDKCore

struct APICallTests {
    private let api = VRoidHubAPI(credential: VRoidCredential(clientID: "cid", clientSecret: "secret"))

    @Test
    func apiCallsNeedAnAccessTokenButTokenCallsDoNot() {
        let account = api.account().request
        #expect(account.requiresAuthorization)
        #expect(account.headers["Authorization"] == nil)
        #expect(account.authorized(by: "a1").headers["Authorization"] == "Bearer a1")

        let refresh = api.tokenRefresh(VRoidOAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: .distantFuture))
        #expect(!refresh.request.requiresAuthorization)
        #expect(refresh.request.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    @Test
    func modelFileIsFetchedFromTheRedirectWithoutAPIHeaders() throws {
        let location = api.modelFile(downloadLicenseID: "lic1")
        #expect(!location.request.followsRedirects)
        #expect(location.request.url.absoluteString == "https://hub.vroid.com/api/download_licenses/lic1/download")

        let redirect = VRoidHubResponse(statusCode: 302, headers: ["location": "https://s3.example.com/file.vrm?sig=1"])
        let file = try location.result(from: redirect)
        #expect(file.request.url.absoluteString == "https://s3.example.com/file.vrm?sig=1")
        #expect(file.request.headers.isEmpty)
        #expect(!file.request.requiresAuthorization)
        #expect(try file.result(from: VRoidHubResponse(statusCode: 200, body: Data("vrm".utf8))) == Data("vrm".utf8))
    }

    @Test
    func pageOutsideTheAPIOriginIsRefused() {
        #expect(throws: VRoidHubError.self) {
            try api.characterModels(pageAt: URL(string: "https://example.com/api/account/character_models")!)
        }
    }

    @Test
    func staffPicksPagesUnwrapTheModels() throws {
        let json = """
        { "data": [{ "id": "sp1", "character_model": { "id": "m1" } }], "_links": {} }
        """
        let page = try api.staffPicks().result(from: .json(json))
        #expect(page.items.map(\.id) == ["m1"])
        #expect(page.next == nil)
    }

    @Test
    func forbiddenWithAReasonReportsTheReason() {
        let json = """
        { "data": null, "error": { "code": "NOT_AVAILABLE", "message": "not for this app" } }
        """
        let error = #expect(throws: VRoidHubError.self) {
            try api.issueDownloadLicense(characterModelID: "m1").result(from: .json(json, statusCode: 403))
        }
        guard case .api(let code, let message) = error else {
            Issue.record("Expected api error, got \(String(describing: error))")
            return
        }
        #expect(code == "NOT_AVAILABLE")
        #expect(message == "not for this app")
    }

    @Test
    func parsesRetryAfterHTTPDate() {
        #expect(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT") == Date(timeIntervalSince1970: 784_111_777))
        #expect(HTTPDate.parse("Thu, 29 Feb 2024 00:00:00 GMT") == Date(timeIntervalSince1970: 1_709_164_800))
        #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT") == nil)
    }
}

struct GuidelineRowsTests {
    @Test
    func vrm0ShowsNonprofitAndLeavesOutVRM1Conditions() throws {
        let license = try JSONDecoder().decode(VRoidCharacterModelLicense.self, from: Data("""
        {
          "characterization_allowed_user": "author",
          "personal_commercial_use": "nonprofit",
          "credit": "necessary"
        }
        """.utf8))
        let rows = VRoidUsageConditions(license: license).guidelineRows
        #expect(rows.map(\.condition) == [
            .useAsAvatar, .violentExpressions, .sexualExpressions, .corporateCommercialUse,
            .personalCommercialUse, .redistribution, .modification, .credit,
        ])
        #expect(rows.first?.value == .disallowed)
        #expect(rows.first { $0.condition == .personalCommercialUse }?.value == .nonprofitOnly)
        #expect(rows.first { $0.condition == .credit }?.value == .required)
        #expect(rows.first { $0.condition == .violentExpressions }?.value == .unspecified)
    }

    @Test
    func vrm1ListsEveryConditionInGuidelineOrder() throws {
        let meta = JSONValue.object([
            "avatarPermission": .string("everyone"),
            "commercialUsage": .string("personalProfit"),
            "modification": .string("allowModification"),
        ])
        let rows = try #require(VRoidUsageConditions(vrm10Meta: meta)).guidelineRows
        #expect(rows.map(\.condition) == VRoidUsageConditions.GuidelineCondition.allCases)
        #expect(rows.first?.value == .allowed)
        #expect(rows.first { $0.condition == .personalCommercialUse }?.value == .allowed)
        #expect(rows.first { $0.condition == .modifiedRedistribution }?.value == .disallowed)
    }
}

struct VRoidModelCacheTests {
    @Test
    func storingANewVersionRemovesTheOlderOne() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = VRoidModelCache(directory: directory)
        func license(_ version: String) -> VRoidDownloadLicense {
            VRoidDownloadLicense(id: "lic-\(version)", characterModelID: "m1", characterModelVersionID: version, expiresAt: .distantFuture)
        }

        try cache.store(sealedData: Data("one".utf8), license: license("v1"))
        try cache.store(sealedData: Data("two".utf8), license: license("v2"))

        #expect(cache.sealedData(modelID: "m1", versionID: "v1") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Models/m1_v1.bin").path))
        #expect(cache.sealedData(modelID: "m1", versionID: "v2") == Data("two".utf8))
        #expect(cache.validLicense(modelID: "m1", versionID: "v2")?.id == "lic-v2")
    }
}
