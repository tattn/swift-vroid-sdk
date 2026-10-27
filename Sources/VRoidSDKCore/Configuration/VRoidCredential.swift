#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Application credential issued on the VRoid Hub application settings page.
///
/// A client secret embedded in a distributed app cannot be kept truly secret.
/// This mirrors how the official Unity SDK distributes credentials with the app.
public struct VRoidCredential: Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}
