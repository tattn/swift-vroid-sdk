import Foundation
import Synchronization
import Testing
@testable import VRoidSDK

struct ClientDownloadTests {
    private struct StubModel: VRoidCharacterModelDownloadable {
        let characterModelID: String
        let latestVersionID: String?
    }

    private func stubDownloadEndpoints(
        _ transport: MockHTTPTransport,
        modelID: String = "m1",
        versionID: String = "v1",
        licenseID: String = "lic1",
        licenseExpiresAt: String = "2026-08-15T00:00:00.000+09:00",
        fileBytes: Data = Data("vrm-file".utf8)
    ) {
        transport.route(method: "POST", path: "/api/download_licenses") { _ in
            .json("""
            {
              "data": {
                "id": "\(licenseID)",
                "character_model_id": "\(modelID)",
                "character_model_version_id": "\(versionID)",
                "expires_at": "\(licenseExpiresAt)"
              },
              "error": null, "_links": null
            }
            """)
        }
        transport.route(method: "GET", path: "/api/download_licenses/\(licenseID)/download") { _ in
            HTTPResponse(statusCode: 302, headers: ["Location": "https://s3.example.com/file.vrm?sig=abc"])
        }
        transport.route(method: "GET", path: "/file.vrm") { request in
            // The presigned URL must be fetched without API headers.
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Api-Version") == nil)
            return HTTPResponse(statusCode: 200, body: fileBytes)
        }
    }

    @Test
    func downloadsViaLicenseAndCaches() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        let fileBytes = Data("vrm-file".utf8)
        stubDownloadEndpoints(fixture.transport, fileBytes: fileBytes)

        let downloaded = try await fixture.client.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: nil)
        )
        #expect(downloaded.characterModelID == "m1")
        #expect(downloaded.characterModelVersionID == "v1")

        let data = try await fixture.client.modelData(for: downloaded)
        #expect(data == fileBytes)
    }

    @Test
    func reusesCacheForKnownVersionWithoutNetwork() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        stubDownloadEndpoints(fixture.transport)

        _ = try await fixture.client.downloadModel(StubModel(characterModelID: "m1", latestVersionID: nil))
        let licenseRequests = fixture.transport.requests(method: "POST", path: "/api/download_licenses").count
        #expect(licenseRequests == 1)

        // Second download with the version known: served entirely from cache.
        let downloaded = try await fixture.client.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: "v1")
        )
        #expect(downloaded.characterModelVersionID == "v1")
        #expect(fixture.transport.requests(method: "POST", path: "/api/download_licenses").count == 1)
        #expect(fixture.transport.requests(method: "GET", path: "/file.vrm").count == 1)
    }

    @Test
    func skipsFileDownloadWhenLicenseVersionMatchesCache() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        let licenseCounter = Counter()
        fixture.transport.route(method: "POST", path: "/api/download_licenses") { _ in
            let index = licenseCounter.increment()
            return .json("""
            {
              "data": {
                "id": "lic\(index)",
                "character_model_id": "m1",
                "character_model_version_id": "v1",
                "expires_at": "2026-08-15T00:00:00.000+09:00"
              },
              "error": null, "_links": null
            }
            """)
        }
        fixture.transport.route(method: "GET", path: "/api/download_licenses/lic1/download") { _ in
            HTTPResponse(statusCode: 302, headers: ["Location": "https://s3.example.com/file.vrm"])
        }
        fixture.transport.route(method: "GET", path: "/file.vrm") { _ in
            HTTPResponse(statusCode: 200, body: Data("vrm-file".utf8))
        }

        _ = try await fixture.client.downloadModel(StubModel(characterModelID: "m1", latestVersionID: nil))
        // Unknown version forces a license request, but the file itself is cached.
        let downloaded = try await fixture.client.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: nil)
        )

        #expect(fixture.transport.requests(method: "POST", path: "/api/download_licenses").count == 2)
        #expect(fixture.transport.requests(method: "GET", path: "/file.vrm").count == 1)
        #expect(downloaded.downloadLicense.id == "lic2")

        let cached = try await fixture.client.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: "v1")
        )
        #expect(cached.downloadLicense.id == "lic2")
        #expect(fixture.transport.requests(method: "POST", path: "/api/download_licenses").count == 2)
    }

    @Test
    func withModelFileCleansUpTemporaryFile() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        let fileBytes = Data("vrm-file".utf8)
        stubDownloadEndpoints(fixture.transport, fileBytes: fileBytes)

        let downloaded = try await fixture.client.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: nil)
        )
        let temporaryURL = try await fixture.client.withModelFile(downloaded) { url -> URL in
            #expect(FileManager.default.fileExists(atPath: url.path))
            let contents = try Data(contentsOf: url)
            #expect(contents == fileBytes)
            return url
        }
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test
    func retriesOnceAfterUnauthorized() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }

        let counter = Counter()
        fixture.transport.route(method: "GET", path: "/api/account") { request in
            if counter.increment() == 1 {
                return HTTPResponse(statusCode: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a2")
            return .json("""
            { "data": { "user_detail": { "user": { "id": "u1", "name": "User" } } }, "error": null, "_links": null }
            """)
        }
        fixture.transport.route(method: "POST", path: "/oauth/token") { _ in
            .json("""
            { "access_token": "a2", "refresh_token": "r2", "expires_in": 3600, "token_type": "Bearer" }
            """)
        }

        let account = try await fixture.client.account()
        #expect(account.user.id == "u1")
        #expect(counter.value == 2)
    }

    @Test
    func expiredLicenseReissuesLicenseButReusesCachedFile() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileBytes = Data("vrm-file".utf8)
        // The stubbed license expires 2026-08-15 (epoch ~1.79e9).
        let beforeExpiry = Date(timeIntervalSince1970: 1_000_000_000)
        let afterExpiry = Date(timeIntervalSince1970: 2_000_000_000)
        let token = OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: .distantFuture)

        let firstTransport = MockHTTPTransport()
        stubDownloadEndpoints(firstTransport, fileBytes: fileBytes)
        let firstClient = makeTestClient(
            transport: firstTransport,
            cacheDirectory: directory,
            token: token,
            now: beforeExpiry
        )
        _ = try await firstClient.downloadModel(StubModel(characterModelID: "m1", latestVersionID: "v1"))
        #expect(firstTransport.requests(method: "GET", path: "/file.vrm").count == 1)

        // Later run, after the license expired: a new license is issued, but
        // the encrypted file must be reused instead of re-downloaded.
        let secondTransport = MockHTTPTransport()
        stubDownloadEndpoints(
            secondTransport,
            licenseID: "lic2",
            licenseExpiresAt: "2034-08-15T00:00:00.000+09:00",
            fileBytes: fileBytes
        )
        let secondClient = makeTestClient(
            transport: secondTransport,
            cacheDirectory: directory,
            token: token,
            now: afterExpiry
        )
        let downloaded = try await secondClient.downloadModel(
            StubModel(characterModelID: "m1", latestVersionID: "v1")
        )

        #expect(downloaded.downloadLicense.id == "lic2")
        #expect(secondTransport.requests(method: "POST", path: "/api/download_licenses").count == 1)
        #expect(secondTransport.requests(method: "GET", path: "/file.vrm").isEmpty)
        let data = try await secondClient.modelData(for: downloaded)
        #expect(data == fileBytes)
    }

    @Test
    func rejectsPaginationURLsOutsideTheAPIOrigin() async {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        let urls = [
            URL(string: "http://hub.vroid.com/api/account/character_models")!,
            URL(string: "https://hub.vroid.com:444/api/account/character_models")!,
        ]

        for url in urls {
            let error = await #expect(throws: VRoidHubError.self) {
                _ = try await fixture.client.characterModels(pageAt: url)
            }
            guard case .invalidConfiguration = error else {
                Issue.record("Expected invalidConfiguration for \(url)")
                continue
            }
        }
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test
    func doesNotCoalesceDownloadsForDifferentKnownVersions() async throws {
        let fixture = makeClientFixture()
        defer { fixture.cleanUp() }
        let counter = Counter()
        let firstLicenseRequested = AsyncStream.makeStream(of: Void.self)
        let releaseFirstLicense = AsyncStream.makeStream(of: Void.self)
        fixture.transport.route(method: "POST", path: "/api/download_licenses") { _ in
            let index = counter.increment()
            if index == 1 {
                firstLicenseRequested.continuation.finish()
                // Hold the first response until the second request proves the
                // downloads were not coalesced. The deadline turns a
                // coalescing regression into assertion failures, not a hang.
                await Self.waitForFinish(of: releaseFirstLicense.stream, timeout: .seconds(1))
            } else {
                releaseFirstLicense.continuation.finish()
            }
            return .json("""
            {
              "data": {
                "id": "lic\(index)",
                "character_model_id": "m1",
                "character_model_version_id": "v\(index)",
                "expires_at": "2026-08-15T00:00:00.000+09:00"
              },
              "error": null, "_links": null
            }
            """)
        }
        for index in 1...2 {
            fixture.transport.route(
                method: "GET",
                path: "/api/download_licenses/lic\(index)/download"
            ) { _ in
                HTTPResponse(
                    statusCode: 302,
                    headers: ["Location": "https://s3.example.com/file-v\(index).vrm"]
                )
            }
            fixture.transport.route(method: "GET", path: "/file-v\(index).vrm") { _ in
                HTTPResponse(statusCode: 200, body: Data("v\(index)".utf8))
            }
        }

        let first = Task {
            try await fixture.client.downloadModel(
                StubModel(characterModelID: "m1", latestVersionID: "v1")
            )
        }
        await Self.waitForFinish(of: firstLicenseRequested.stream, timeout: .seconds(1))
        let second = Task {
            try await fixture.client.downloadModel(
                StubModel(characterModelID: "m1", latestVersionID: "v2")
            )
        }

        let firstDownload = try await first.value
        let secondDownload = try await second.value
        #expect(firstDownload.characterModelVersionID == "v1")
        #expect(secondDownload.characterModelVersionID == "v2")
        #expect(counter.value == 2)
    }

    private static func waitForFinish(of stream: AsyncStream<Void>, timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream {}
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }
}
