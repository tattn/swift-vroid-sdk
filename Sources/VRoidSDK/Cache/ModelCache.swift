import Foundation

/// Encrypted persistent cache for downloaded model files.
///
/// Layout:
/// ```
/// <directory>/
/// ├── metadata.json
/// ├── Models/<modelID>_<versionID>.bin   (AES-GCM sealed)
/// └── tmp/                               (plaintext scratch, purged on init)
/// ```
actor ModelCache {
    struct Entry: Codable, Sendable {
        let characterModelID: String
        let characterModelVersionID: String
        var downloadLicenseID: String
        var downloadLicenseExpiresAt: Date
        var lastAccessedAt: Date
    }

    private struct Metadata: Codable {
        var formatVersion: Int
        var entries: [String: Entry]
    }

    private static let currentFormatVersion = 1

    static var defaultDirectory: URL {
        // Scoped by app: on an unsandboxed system the caches directory is
        // shared, and apps cannot decrypt each other's cache (each has its
        // own key), so a shared directory would make them evict each other.
        // The <bundle id>/... layout follows the macOS convention, so the
        // cache is cleaned up together with the host app's other caches.
        URL.cachesDirectory
            .appending(path: AppIdentity.identifier, directoryHint: .isDirectory)
            .appending(path: "VRoidSDK", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let configuration: VRoidCacheConfiguration
    private let cryptor: ModelCacheCryptor
    private let dateProvider: any DateProviding

    private var metadata: Metadata?
    private var didPurgeLeftovers = false

    init(
        directory: URL,
        configuration: VRoidCacheConfiguration,
        cryptor: ModelCacheCryptor,
        dateProvider: any DateProviding
    ) {
        self.directory = directory
        self.configuration = configuration
        self.cryptor = cryptor
        self.dateProvider = dateProvider
    }

    // MARK: Lookup

    /// Returns the entry for the given model version if its download license
    /// has not expired. Expired or missing entries are treated as cache misses.
    func validEntry(modelID: String, versionID: String) -> Entry? {
        purgeLeftoversIfNeeded()
        let key = Self.key(modelID: modelID, versionID: versionID)
        guard let entry = loadMetadata().entries[key] else { return nil }
        guard entry.downloadLicenseExpiresAt > dateProvider.now else {
            // Keep the encrypted file: a freshly issued license revalidates
            // it via updateLicenseIfPresent(_:) without re-downloading.
            return nil
        }
        guard FileManager.default.fileExists(atPath: modelFileURL(forKey: key).path) else {
            removeEntry(forKey: key)
            return nil
        }
        return entry
    }

    /// Decrypts and returns the cached model data, updating its LRU timestamp.
    /// Corrupted entries are removed and reported as a miss.
    func modelData(modelID: String, versionID: String) -> Data? {
        purgeLeftoversIfNeeded()
        let key = Self.key(modelID: modelID, versionID: versionID)
        guard loadMetadata().entries[key] != nil else { return nil }
        let fileURL = modelFileURL(forKey: key)
        // Map the sealed file instead of copying it into a heap buffer;
        // decryption already allocates a full-size plaintext buffer.
        guard let sealed = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let plaintext = try? cryptor.open(sealed)
        else {
            removeEntry(forKey: key)
            return nil
        }
        touch(key: key)
        return plaintext
    }

    // MARK: Storage

    func store(modelData: Data, license: VRoidDownloadLicense) throws {
        purgeLeftoversIfNeeded()
        // Load metadata first: the initial load may wipe the models directory
        // when the metadata file is missing or incompatible.
        _ = loadMetadata()

        let key = Self.key(modelID: license.characterModelID, versionID: license.characterModelVersionID)
        let sealed = try cryptor.seal(modelData)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try sealed.write(to: modelFileURL(forKey: key), options: .atomic)
        } catch {
            throw VRoidHubError.cacheFailed
        }

        modifyMetadata { metadata in
            metadata.entries[key] = Entry(
                characterModelID: license.characterModelID,
                characterModelVersionID: license.characterModelVersionID,
                downloadLicenseID: license.id,
                downloadLicenseExpiresAt: license.expiresAt,
                lastAccessedAt: dateProvider.now
            )
        }
        evictIfNeeded()
        saveMetadata()
    }

    /// Replaces the license metadata when the exact model version is already
    /// cached. The newly issued license authorizes reusing the encrypted bytes.
    func updateLicenseIfPresent(_ license: VRoidDownloadLicense) -> Bool {
        purgeLeftoversIfNeeded()
        let key = Self.key(
            modelID: license.characterModelID,
            versionID: license.characterModelVersionID
        )
        guard loadMetadata().entries[key] != nil,
              FileManager.default.fileExists(atPath: modelFileURL(forKey: key).path)
        else {
            return false
        }
        modifyMetadata { metadata in
            metadata.entries[key]?.downloadLicenseID = license.id
            metadata.entries[key]?.downloadLicenseExpiresAt = license.expiresAt
            metadata.entries[key]?.lastAccessedAt = dateProvider.now
        }
        saveMetadata()
        return true
    }

    // MARK: Temporary plaintext files

    /// Removes leftover plaintext files from previous runs (e.g. after a crash).
    func purgeTemporaryDirectory() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func makeTemporaryPlaintextFile(data: Data) throws -> URL {
        purgeLeftoversIfNeeded()
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let url = temporaryDirectory.appending(path: "\(UUID().uuidString).vrm")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw VRoidHubError.cacheFailed
        }
    }

    func removeTemporaryFile(at url: URL) {
        // Only delete files the cache itself created.
        guard url.deletingLastPathComponent() == temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Internals

    private static func key(modelID: String, versionID: String) -> String {
        "\(modelID)_\(versionID)"
    }

    /// One-time cleanup of leftover plaintext files from previous runs,
    /// deferred to the first cache operation so that client construction
    /// does not pay disk I/O.
    private func purgeLeftoversIfNeeded() {
        guard !didPurgeLeftovers else { return }
        didPurgeLeftovers = true
        purgeTemporaryDirectory()
    }

    private var modelsDirectory: URL {
        directory.appending(path: "Models", directoryHint: .isDirectory)
    }

    private var temporaryDirectory: URL {
        directory.appending(path: "tmp", directoryHint: .isDirectory)
    }

    private var metadataURL: URL {
        directory.appending(path: "metadata.json")
    }

    private func modelFileURL(forKey key: String) -> URL {
        modelsDirectory.appending(path: "\(key).bin")
    }

    private func loadMetadata() -> Metadata {
        if let metadata { return metadata }
        let loaded: Metadata
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
           decoded.formatVersion == Self.currentFormatVersion {
            loaded = decoded
        } else {
            // Missing, corrupted, or incompatible metadata: start fresh.
            loaded = Metadata(formatVersion: Self.currentFormatVersion, entries: [:])
            try? FileManager.default.removeItem(at: modelsDirectory)
        }
        metadata = loaded
        return loaded
    }

    private func saveMetadata() {
        guard let metadata else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            // A failed metadata write degrades to a cache miss on next launch.
        }
    }

    /// Single mutation path for the metadata; guarantees it is loaded first.
    @discardableResult
    private func modifyMetadata<T>(_ mutate: (inout Metadata) -> T) -> T {
        var loaded = loadMetadata()
        let result = mutate(&loaded)
        metadata = loaded
        return result
    }

    private func touch(key: String) {
        // Updated in memory only and persisted opportunistically (on store
        // and removal); losing a touch merely degrades LRU ordering, which
        // is not worth a file write per cache read.
        modifyMetadata { $0.entries[key]?.lastAccessedAt = dateProvider.now }
    }

    private func removeEntry(forKey key: String) {
        modifyMetadata { $0.entries.removeValue(forKey: key) }
        try? FileManager.default.removeItem(at: modelFileURL(forKey: key))
        saveMetadata()
    }

    private func evictIfNeeded() {
        let excessKeys = modifyMetadata { metadata -> [String] in
            guard metadata.entries.count > configuration.maximumModelCount else { return [] }
            let keys = metadata.entries
                .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
                .prefix(metadata.entries.count - configuration.maximumModelCount)
                .map(\.key)
            keys.forEach { metadata.entries.removeValue(forKey: $0) }
            return keys
        }
        for key in excessKeys {
            try? FileManager.default.removeItem(at: modelFileURL(forKey: key))
        }
    }
}
