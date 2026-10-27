import Foundation
public import VRoidSDKCore

/// A logical handle to a model file that the SDK has downloaded and cached.
///
/// The persistent cache is encrypted, so this type intentionally carries no
/// plaintext file URL. Use ``VRoidHubClient/modelData(for:)`` or
/// ``VRoidHubClient/withModelFile(_:_:)`` to access the model data.
public struct DownloadedVRoidModel: Sendable {
    public let downloadLicense: VRoidDownloadLicense

    public var characterModelID: String { downloadLicense.characterModelID }
    public var characterModelVersionID: String { downloadLicense.characterModelVersionID }
}
