#if os(macOS)
import Foundation
import Testing
@testable import VRoidSDK
@testable import VRoidSDKCore

@Suite(.serialized)
struct KeychainStorageTests {
    @Test
    func roundTripsUsingTheAvailableKeychainBackend() throws {
        let storage = KeychainStorage(service: "swift-vroid-sdk.tests.\(UUID().uuidString)")
        let account = "fallback"
        defer { try? storage.remove(account) }
        let value = Data("token".utf8)

        try storage.set(value, for: account)
        #expect(try storage.data(for: account) == value)

        try storage.remove(account)
        #expect(try storage.data(for: account) == nil)
    }
}
#endif
