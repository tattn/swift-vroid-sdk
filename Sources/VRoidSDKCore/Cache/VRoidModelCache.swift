#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Persistent cache of downloaded model files, keyed by model version and
/// kept while their download licenses allow.
///
/// The caller seals (encrypts) the files: the cache stores and returns the
/// sealed bytes as given, so that each platform can keep the key in its own
/// secure storage. Plaintext model data must never be persisted. When sealed
/// bytes fail to open, ``remove(modelID:versionID:)`` them and download again.
///
/// Not thread-safe; serialize access to one instance.
///
/// Layout:
/// ```
/// <directory>/
/// ├── metadata.json
/// ├── Models/<modelID>_<versionID>.bin   (sealed by the caller)
/// └── tmp/                               (plaintext scratch, purged on first use)
/// ```
public final class VRoidModelCache {
    private struct Entry: Codable {
        let characterModelID: String
        let characterModelVersionID: String
        var downloadLicenseID: String
        var downloadLicenseExpiresAt: Date
        var lastAccessedAt: Date
        /// Size of the sealed file, for byte-based eviction.
        var sizeBytes: Int
    }

    private struct Metadata: Codable {
        var formatVersion: Int
        var entries: [String: Entry]
    }

    private static let currentFormatVersion = 2

    private let directory: URL
    private let configuration: VRoidCacheConfiguration
    private let dateProvider: any DateProviding

    private var metadata: Metadata?
    private var didPurgeLeftovers = false

    public convenience init(directory: URL, configuration: VRoidCacheConfiguration = VRoidCacheConfiguration()) {
        self.init(directory: directory, configuration: configuration, dateProvider: SystemDateProvider())
    }

    package init(directory: URL, configuration: VRoidCacheConfiguration, dateProvider: any DateProviding) {
        self.directory = directory
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    // MARK: Lookup

    /// The download license of the given model version if it is cached and the
    /// license has not expired. Use the cached file instead of downloading
    /// again in that case.
    public func validLicense(modelID: String, versionID: String) -> VRoidDownloadLicense? {
        purgeLeftoversIfNeeded()
        let key = Self.key(modelID: modelID, versionID: versionID)
        guard let entry = loadMetadata().entries[key] else { return nil }
        guard entry.downloadLicenseExpiresAt > dateProvider.now else {
            // Keep the sealed file: a freshly issued license revalidates it
            // via updateLicenseIfPresent(_:) without re-downloading.
            return nil
        }
        guard FileManager.default.fileExists(atPath: modelFileURL(forKey: key).path) else {
            remove(modelID: modelID, versionID: versionID)
            return nil
        }
        return VRoidDownloadLicense(
            id: entry.downloadLicenseID,
            characterModelID: modelID,
            characterModelVersionID: versionID,
            expiresAt: entry.downloadLicenseExpiresAt
        )
    }

    /// The sealed model data, marking it as recently used.
    public func sealedData(modelID: String, versionID: String) -> Data? {
        purgeLeftoversIfNeeded()
        let key = Self.key(modelID: modelID, versionID: versionID)
        guard loadMetadata().entries[key] != nil else { return nil }
        // Map the sealed file instead of copying it into a heap buffer;
        // opening it already allocates a full-size plaintext buffer.
        guard let sealed = try? Data(contentsOf: modelFileURL(forKey: key), options: .mappedIfSafe) else {
            remove(modelID: modelID, versionID: versionID)
            return nil
        }
        // Updated in memory only and persisted opportunistically (on store
        // and removal); losing a touch merely degrades LRU ordering, which
        // is not worth a file write per cache read.
        modifyMetadata { $0.entries[key]?.lastAccessedAt = dateProvider.now }
        return sealed
    }

    // MARK: Storage

    /// Stores the sealed model file that `license` authorizes. Other versions
    /// of the same model are removed: a newly issued license always names the
    /// latest version.
    public func store(sealedData: Data, license: VRoidDownloadLicense) throws {
        purgeLeftoversIfNeeded()
        // Load metadata first: the initial load may wipe the models directory
        // when the metadata file is missing or incompatible.
        _ = loadMetadata()

        let key = Self.key(modelID: license.characterModelID, versionID: license.characterModelVersionID)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try sealedData.write(to: modelFileURL(forKey: key), options: .atomic)
        } catch {
            throw VRoidHubError.cacheFailed
        }

        let outdatedKeys = modifyMetadata { metadata in
            let outdated = metadata.entries
                .filter { $0.key != key && $0.value.characterModelID == license.characterModelID }
                .map(\.key)
            for outdatedKey in outdated {
                metadata.entries.removeValue(forKey: outdatedKey)
            }
            metadata.entries[key] = Entry(
                characterModelID: license.characterModelID,
                characterModelVersionID: license.characterModelVersionID,
                downloadLicenseID: license.id,
                downloadLicenseExpiresAt: license.expiresAt,
                lastAccessedAt: dateProvider.now,
                sizeBytes: sealedData.count
            )
            return outdated
        }
        for removedKey in outdatedKeys + evictIfNeeded() {
            try? FileManager.default.removeItem(at: modelFileURL(forKey: removedKey))
        }
        saveMetadata()
    }

    /// Replaces the license metadata when the exact model version is already
    /// cached. The newly issued license authorizes reusing the sealed bytes.
    public func updateLicenseIfPresent(_ license: VRoidDownloadLicense) -> Bool {
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

    /// Removes a cached model version, e.g. one whose sealed bytes no longer open.
    public func remove(modelID: String, versionID: String) {
        let key = Self.key(modelID: modelID, versionID: versionID)
        modifyMetadata { $0.entries.removeValue(forKey: key) }
        try? FileManager.default.removeItem(at: modelFileURL(forKey: key))
        saveMetadata()
    }

    // MARK: Temporary plaintext files

    /// Writes plaintext model data for a reader that needs a file. Remove it
    /// with ``removeTemporaryFile(at:)`` as soon as it has been read; files
    /// left behind (e.g. after a crash) are purged on the cache's first use.
    public func makeTemporaryPlaintextFile(data: Data) throws -> URL {
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

    public func removeTemporaryFile(at url: URL) {
        // Only delete files the cache itself created.
        guard url.deletingLastPathComponent() == temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Internals

    private static func key(modelID: String, versionID: String) -> String {
        "\(modelID)_\(versionID)"
    }

    /// One-time cleanup of leftover plaintext files from previous runs,
    /// deferred to the first cache operation so that creating the cache does
    /// not pay disk I/O.
    private func purgeLeftoversIfNeeded() {
        guard !didPurgeLeftovers else { return }
        didPurgeLeftovers = true
        try? FileManager.default.removeItem(at: temporaryDirectory)
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

    /// Drops least recently used entries beyond the limits and returns their keys.
    private func evictIfNeeded() -> [String] {
        modifyMetadata { metadata -> [String] in
            var totalBytes = metadata.entries.values.reduce(0) { $0 + $1.sizeBytes }
            func overLimit() -> Bool {
                if metadata.entries.count > configuration.maximumModelCount { return true }
                if let maximumTotalBytes = configuration.maximumTotalBytes {
                    return totalBytes > maximumTotalBytes
                }
                return false
            }
            guard overLimit() else { return [] }

            var removed: [String] = []
            let leastRecentlyUsedFirst = metadata.entries
                .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            // Never evict down to zero: the most recently stored model must
            // survive so that it stays readable right after downloading.
            for (key, entry) in leastRecentlyUsedFirst where overLimit() && metadata.entries.count > 1 {
                metadata.entries.removeValue(forKey: key)
                totalBytes -= entry.sizeBytes
                removed.append(key)
            }
            return removed
        }
    }
}
