#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

public struct VRoidUser: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let icon: VRoidImageSet?
}

public struct VRoidImageSet: Decodable, Sendable {
    public let isDefaultImage: Bool?
    public let original: VRoidImage?
    public let w600: VRoidImage?
    public let w300: VRoidImage?
    public let sq600: VRoidImage?
    public let sq300: VRoidImage?
    public let sq150: VRoidImage?
    public let sq50: VRoidImage?
    public let sq170: VRoidImage?

    enum CodingKeys: String, CodingKey {
        case isDefaultImage = "is_default_image"
        case original, w600, w300, sq600, sq300, sq150, sq50, sq170
    }
}

public struct VRoidImage: Decodable, Sendable {
    public let url: URL?
    public let url2x: URL?
    public let width: Int?
    public let height: Int?
}

extension VRoidImageSet {
    /// The URL of a small image. Not every variant is present: user icons
    /// come only as sq170/sq50 on the live API, so this falls through the
    /// whole set.
    public var thumbnailURL: URL? {
        sq300?.url ?? w300?.url ?? sq170?.url ?? sq150?.url
            ?? sq600?.url ?? w600?.url ?? original?.url ?? sq50?.url
    }

    /// The URL of the largest image, for detail views.
    public var largeURL: URL? {
        w600?.url ?? original?.url ?? sq600?.url ?? thumbnailURL
    }
}
