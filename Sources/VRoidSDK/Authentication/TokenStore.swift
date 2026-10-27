import Foundation
import VRoidSDKCore
import Security
import Synchronization

/// Persistence boundary for the OAuth token, injected so tests can run
/// without Keychain entitlements.
protocol TokenStore: Sendable {
    func load() throws -> VRoidOAuthToken?
    func save(_ token: VRoidOAuthToken) throws
    func clear() throws
}

struct KeychainTokenStore: TokenStore {
    private let storage: KeychainStorage
    private let account: String

    init(clientID: String) {
        self.storage = KeychainStorage(service: "swift-vroid-sdk.oauth-token")
        // The legacy keychain fallback shares items across apps by
        // (service, account), so two apps using the same client ID must
        // still map to distinct items.
        self.account = "\(AppIdentity.identifier).\(clientID)"
    }

    func load() throws -> VRoidOAuthToken? {
        guard let data = try storage.data(for: account) else { return nil }
        return try? JSONDecoder().decode(VRoidOAuthToken.self, from: data)
    }

    func save(_ token: VRoidOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        try storage.set(data, for: account)
    }

    func clear() throws {
        try storage.remove(account)
    }
}

/// Keychain failure carrying the underlying status code for diagnostics.
/// Kept separate from ``VRoidHubError`` so that token persistence failures
/// are not misreported as cache failures.
struct KeychainStorageError: Error {
    let status: OSStatus
}

/// Minimal generic-password Keychain wrapper.
final class KeychainStorage: Sendable {
    private enum Backend: Sendable {
        case dataProtection
        case legacy
    }

    let service: String
    private let backend = Mutex<Backend?>(nil)

    init(service: String) {
        self.service = service
    }

    func data(for account: String) throws -> Data? {
        // Once a backend is known to work, stop probing the others;
        // every probe is an IPC round trip to securityd.
        let candidates = backend.withLock { $0 }.map { [$0] } ?? allBackends
        for candidate in candidates {
            var query = baseQuery(account: account, backend: candidate)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                backend.withLock { $0 = candidate }
                return result as? Data
            case errSecItemNotFound:
                continue
            case errSecMissingEntitlement where candidate == .dataProtection:
                continue
            default:
                throw KeychainStorageError(status: status)
            }
        }
        backend.withLock { selected in
            if selected == nil {
                selected = .dataProtection
            }
        }
        return nil
    }

    func set(_ data: Data, for account: String) throws {
        if backend.withLock({ $0 }) == nil {
            // Probe once to resolve the usable backend.
            _ = try self.data(for: account)
        }
        let selectedBackend = backend.withLock { $0 ?? .dataProtection }
        do {
            try set(data, for: account, backend: selectedBackend)
        } catch let error as KeychainStorageError
            where error.status == errSecMissingEntitlement && selectedBackend == .dataProtection {
            backend.withLock { $0 = .legacy }
            try set(data, for: account, backend: .legacy)
        }
    }

    func remove(_ account: String) throws {
        var firstFailure: OSStatus?
        for candidate in allBackends {
            let status = SecItemDelete(baseQuery(account: account, backend: candidate) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                break
            case errSecMissingEntitlement where candidate == .dataProtection:
                break
            default:
                firstFailure = firstFailure ?? status
            }
        }
        if let firstFailure {
            throw KeychainStorageError(status: firstFailure)
        }
    }

    private func set(_ data: Data, for account: String, backend: Backend) throws {
        let deleteStatus = SecItemDelete(baseQuery(account: account, backend: backend) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainStorageError(status: deleteStatus)
        }

        var attributes = baseQuery(account: account, backend: backend)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStorageError(status: status)
        }
    }

    private var allBackends: [Backend] {
        #if os(macOS)
        [.dataProtection, .legacy]
        #else
        [.dataProtection]
        #endif
    }

    private func baseQuery(account: String, backend: Backend) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: backend == .dataProtection,
        ]
    }
}
