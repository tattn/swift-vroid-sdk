import CryptoKit
import Foundation
import Security
import Synchronization
import VRoidSDKCore

/// Provides the symmetric key used to encrypt cached model files.
protocol CacheKeyProviding: Sendable {
    func key() throws -> SymmetricKey
}

/// Persists a random 256-bit key in the Keychain, generated on first use.
/// No fixed password or key is embedded in the SDK.
///
/// The key is resolved once per process so that cache operations do not pay
/// a Keychain round trip each.
final class KeychainCacheKeyProvider: CacheKeyProviding {
    /// Shared by default so that multiple clients in one process resolve the
    /// same key and never race the first-time key creation against each other.
    static let shared = KeychainCacheKeyProvider()

    private let storage = KeychainStorage(service: "swift-vroid-sdk.cache-key")
    // The legacy keychain fallback shares items across apps by
    // (service, account), so the account must be app-scoped.
    private let account = "model-cache.\(AppIdentity.identifier)"
    private let cachedKey = Mutex<SymmetricKey?>(nil)

    func key() throws -> SymmetricKey {
        // Load-or-create runs entirely inside the lock so that concurrent
        // first calls cannot generate two different keys.
        try cachedKey.withLock { cached in
            if let cached { return cached }
            let key = try loadOrCreateKey()
            cached = key
            return key
        }
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try storage.data(for: account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = unsafe key.withUnsafeBytes { unsafe Data($0) }
        try storage.set(data, for: account)
        return key
    }
}

/// AES-GCM encryption for cached model files.
struct ModelCacheCryptor: Sendable {
    let keyProvider: any CacheKeyProviding

    func seal(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: keyProvider.key())
        guard let combined = sealed.combined else {
            throw VRoidHubError.cacheFailed
        }
        return combined
    }

    func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: keyProvider.key())
    }
}
