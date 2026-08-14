import Foundation
import Testing
@testable import VRoidSDK

struct ModelCacheTests {
    private func makeCache(
        directory: URL,
        maximumModelCount: Int = 10,
        maximumTotalBytes: Int? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ModelCache {
        ModelCache(
            directory: directory,
            configuration: VRoidCacheConfiguration(
                maximumModelCount: maximumModelCount,
                maximumTotalBytes: maximumTotalBytes
            ),
            cryptor: ModelCacheCryptor(keyProvider: StaticCacheKeyProvider()),
            dateProvider: IncrementingDateProvider(start: now)
        )
    }

    private func makeLicense(
        modelID: String = "m1",
        versionID: String = "v1",
        expiresAt: Date = Date(timeIntervalSince1970: 2_000_000)
    ) -> VRoidDownloadLicense {
        VRoidDownloadLicense(
            id: "lic-\(modelID)-\(versionID)",
            characterModelID: modelID,
            characterModelVersionID: versionID,
            expiresAt: expiresAt
        )
    }

    @Test
    func storesAndDecryptsModelData() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory)
        let payload = Data("vrm-bytes".utf8)

        try await cache.store(modelData: payload, license: makeLicense())

        let restored = await cache.modelData(modelID: "m1", versionID: "v1")
        #expect(restored == payload)

        // The file on disk must not contain the plaintext.
        let modelsDirectory = directory.appending(path: "Models")
        let files = try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
        let stored = try Data(contentsOf: try #require(files.first))
        #expect(stored != payload)
        #expect(!stored.isEmpty)
    }

    @Test
    func corruptedFileIsAMissAndIsCleanedUp() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory)
        try await cache.store(modelData: Data("vrm-bytes".utf8), license: makeLicense())

        let fileURL = directory.appending(path: "Models/m1_v1.bin")
        try Data("garbage".utf8).write(to: fileURL)

        let restored = await cache.modelData(modelID: "m1", versionID: "v1")
        #expect(restored == nil)
        let entry = await cache.validEntry(modelID: "m1", versionID: "v1")
        #expect(entry == nil)
    }

    @Test
    func expiredLicenseIsAMiss() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cache = makeCache(directory: directory, now: now)
        try await cache.store(
            modelData: Data("vrm-bytes".utf8),
            license: makeLicense(expiresAt: now.addingTimeInterval(-1))
        )
        let entry = await cache.validEntry(modelID: "m1", versionID: "v1")
        #expect(entry == nil)
    }

    @Test
    func differentVersionIsAMiss() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory)
        try await cache.store(modelData: Data("vrm-bytes".utf8), license: makeLicense(versionID: "v1"))
        let entry = await cache.validEntry(modelID: "m1", versionID: "v2")
        #expect(entry == nil)
    }

    @Test
    func evictsLeastRecentlyUsedBeyondLimit() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory, maximumModelCount: 2)

        try await cache.store(modelData: Data("a".utf8), license: makeLicense(modelID: "m1"))
        try await cache.store(modelData: Data("b".utf8), license: makeLicense(modelID: "m2"))
        // Touch m1 so that m2 becomes the least recently used entry.
        _ = await cache.modelData(modelID: "m1", versionID: "v1")
        try await cache.store(modelData: Data("c".utf8), license: makeLicense(modelID: "m3"))

        #expect(await cache.modelData(modelID: "m1", versionID: "v1") != nil)
        #expect(await cache.modelData(modelID: "m2", versionID: "v1") == nil)
        #expect(await cache.modelData(modelID: "m3", versionID: "v1") != nil)
    }

    @Test
    func temporaryFileLifecycle() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory)

        let url = try await cache.makeTemporaryPlaintextFile(data: Data("plain".utf8))
        #expect(FileManager.default.fileExists(atPath: url.path))
        await cache.removeTemporaryFile(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let leftover = try await cache.makeTemporaryPlaintextFile(data: Data("leftover".utf8))
        await cache.purgeTemporaryDirectory()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test
    func evictsLeastRecentlyUsedBeyondByteLimit() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // AES-GCM adds a fixed overhead (~28 bytes) per file; 1KB payloads
        // with a 2.5KB cap keep two models under it and three above it.
        let cache = makeCache(directory: directory, maximumTotalBytes: 2_560)
        let payload = Data(repeating: 0xEF, count: 1_024)

        try await cache.store(modelData: payload, license: makeLicense(modelID: "m1"))
        try await cache.store(modelData: payload, license: makeLicense(modelID: "m2"))
        try await cache.store(modelData: payload, license: makeLicense(modelID: "m3"))

        #expect(await cache.modelData(modelID: "m1", versionID: "v1") == nil)
        #expect(await cache.modelData(modelID: "m2", versionID: "v1") != nil)
        #expect(await cache.modelData(modelID: "m3", versionID: "v1") != nil)
    }

    @Test
    func singleModelLargerThanByteLimitIsKept() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = makeCache(directory: directory, maximumTotalBytes: 100)
        let payload = Data(repeating: 0xEF, count: 1_024)

        try await cache.store(modelData: payload, license: makeLicense(modelID: "m1"))

        // The most recently stored model must survive even over the cap.
        #expect(await cache.modelData(modelID: "m1", versionID: "v1") == payload)
    }

    @Test
    func firstOperationPurgesLeftoverPlaintext() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryDirectory = directory.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let leftover = temporaryDirectory.appending(path: "leftover.vrm")
        try Data("plain".utf8).write(to: leftover)

        // The purge is deferred off the initializer to keep client
        // construction free of disk I/O; any first cache operation runs it.
        let cache = makeCache(directory: directory)
        _ = await cache.modelData(modelID: "m1", versionID: "v1")

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}
