import Foundation
import Testing
@testable import VRoidSDK

struct ListEndpointsTests {
    private static func modelListJSON(ids: [String], nextHref: String? = nil) -> String {
        let items = ids.map { #"{ "id": "\#($0)" }"# }.joined(separator: ",")
        let links = nextHref.map { #"{ "next": { "href": "\#($0)" } }"# } ?? "null"
        return #"{ "data": [\#(items)], "error": null, "_links": \#(links) }"#
    }

    /// Staff picks wrap each model in a staff pick object whose own id is not the model id.
    private static func staffPickListJSON(modelIDs: [String], nextHref: String? = nil) -> String {
        let items = modelIDs.enumerated()
            .map { #"{ "id": "pick-\#($0.offset)", "character_model": { "id": "\#($0.element)" } }"# }
            .joined(separator: ",")
        let links = nextHref.map { #"{ "next": { "href": "\#($0)" } }"# } ?? "null"
        return #"{ "data": [\#(items)], "error": null, "_links": \#(links) }"#
    }

    private static func queryValues(_ request: URLRequest) -> [String: [String]] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(grouping: items, by: \.name).mapValues { $0.map { $0.value ?? "" } }
    }

    @Test
    func heartsSendsApplicationIDAndFilters() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/hearts") { request in
            let query = Self.queryValues(request)
            #expect(query["application_id"] == ["cid"])
            #expect(query["count"] == ["50"])
            #expect(query["is_downloadable"] == ["true"])
            #expect(query["characterization_allowed_user"] == ["everyone"])
            #expect(query["modification"] == ["allow_modification"])
            #expect(query["booth_part_categories[]"]?.sorted() == ["cloth", "hair"])
            return .json(Self.modelListJSON(ids: ["1", "2"]))
        }

        let page = try await fixture.client.hearts(options: VRoidHeartsOptions(
            count: 50,
            filters: VRoidCharacterModelFilters(
                isDownloadable: true,
                characterizationAllowedUser: .everyone,
                modification: .allowModification,
                boothPartCategories: [.hair, .cloth]
            )
        ))

        #expect(page.items.map(\.id) == ["1", "2"])
        #expect(page.next == nil)
    }

    @Test
    func searchSendsKeywordSortAndFilters() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/search/character_models") { request in
            let query = Self.queryValues(request)
            #expect(query["keyword"] == ["cat girl"])
            #expect(query["sort"] == ["first_published_at"])
            #expect(query["personal_commercial_use"] == ["nonprofit"])
            return .json(Self.modelListJSON(
                ids: ["1"],
                nextHref: "/api/search/character_models?keyword=cat+girl&search_after[]=x"
            ))
        }

        let page = try await fixture.client.searchCharacterModels(options: VRoidCharacterModelSearchOptions(
            keyword: "cat girl",
            sort: .newestFirst,
            filters: VRoidCharacterModelFilters(personalCommercialUse: .nonprofit)
        ))

        #expect(page.items.map(\.id) == ["1"])
        #expect(page.next?.host() == "hub.vroid.com")
    }

    @Test
    func staffPicksUnwrapsTheStaffPickObjects() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/staff_picks") { request in
            #expect(Self.queryValues(request)["max_id"] == ["99"])
            return .json(Self.staffPickListJSON(modelIDs: ["3"]))
        }

        let page = try await fixture.client.staffPicks(options: VRoidStaffPicksOptions(maxID: "99"))
        #expect(page.items.map(\.id) == ["3"])
    }

    @Test
    func staffPicksFollowsNextPagesWithTheWrappedShape() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/staff_picks") { request in
            let query = Self.queryValues(request)
            if query["max_id"] == nil {
                return .json(Self.staffPickListJSON(modelIDs: ["1", "2"], nextHref: "/api/staff_picks?max_id=pick-1"))
            }
            #expect(query["max_id"] == ["pick-1"])
            return .json(Self.staffPickListJSON(modelIDs: ["3"]))
        }

        var ids: [String] = []
        for try await model in fixture.client.allStaffPicks() {
            ids.append(model.id)
        }

        #expect(ids == ["1", "2", "3"])
    }

    @Test
    func pageSequenceWalksAllPagesLazily() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/account/character_models") { request in
            let query = Self.queryValues(request)
            if query["max_id"] == nil {
                return .json(Self.modelListJSON(
                    ids: ["1", "2"],
                    nextHref: "/api/account/character_models?max_id=2&publication=all"
                ))
            }
            #expect(query["max_id"] == ["2"])
            return .json(Self.modelListJSON(ids: ["3"]))
        }

        var ids: [String] = []
        for try await model in fixture.client.allCharacterModels() {
            ids.append(model.id)
        }

        #expect(ids == ["1", "2", "3"])
        #expect(fixture.transport.requests(method: "GET", path: "/api/account/character_models").count == 2)
    }

    @Test
    func pageSequenceStopsAtFirstPageWithoutNext() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        fixture.transport.route(method: "GET", path: "/api/hearts") { _ in
            .json(Self.modelListJSON(ids: []))
        }

        var count = 0
        for try await _ in fixture.client.allHearts() {
            count += 1
        }

        #expect(count == 0)
        #expect(fixture.transport.requests(method: "GET", path: "/api/hearts").count == 1)
    }
}
