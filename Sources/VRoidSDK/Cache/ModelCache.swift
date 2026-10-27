import Foundation
import VRoidSDKCore

/// The model cache of ``VRoidHubClient``: ``VRoidModelCache`` with the files
/// sealed by AES-GCM under a Keychain key.
actor ModelCache {
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

    private let files: VRoidModelCache
    private let cryptor: ModelCacheCryptor

    init(
        directory: URL,
        configuration: VRoidCacheConfiguration,
        cryptor: ModelCacheCryptor,
        dateProvider: any DateProviding
    ) {
        self.files = VRoidModelCache(directory: directory, configuration: configuration, dateProvider: dateProvider)
        self.cryptor = cryptor
    }

    func validEntry(modelID: String, versionID: String) -> VRoidDownloadLicense? {
        files.validLicense(modelID: modelID, versionID: versionID)
    }

    /// Decrypts and returns the cached model data. Corrupted entries are
    /// removed and reported as a miss.
    func modelData(modelID: String, versionID: String) -> Data? {
        guard let sealed = files.sealedData(modelID: modelID, versionID: versionID) else { return nil }
        guard let plaintext = try? cryptor.open(sealed) else {
            files.remove(modelID: modelID, versionID: versionID)
            return nil
        }
        return plaintext
    }

    func store(modelData: Data, license: VRoidDownloadLicense) throws {
        try files.store(sealedData: cryptor.seal(modelData), license: license)
    }

    func updateLicenseIfPresent(_ license: VRoidDownloadLicense) -> Bool {
        files.updateLicenseIfPresent(license)
    }

    func makeTemporaryPlaintextFile(data: Data) throws -> URL {
        try files.makeTemporaryPlaintextFile(data: data)
    }

    func removeTemporaryFile(at url: URL) {
        files.removeTemporaryFile(at: url)
    }
}
