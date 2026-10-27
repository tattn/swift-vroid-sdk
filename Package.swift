// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-vroid-sdk",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "VRoidSDK",
            targets: ["VRoidSDK"]
        ),
        // The platform-independent part: API requests and response decoding,
        // usage conditions, and the model cache, without network, keychain or
        // cryptography. Builds wherever FoundationEssentials does (e.g. Android).
        .library(
            name: "VRoidSDKCore",
            targets: ["VRoidSDKCore"]
        ),
    ],
    targets: [
        .target(
            name: "VRoidSDKCore"
        ),
        .target(
            name: "VRoidSDK",
            dependencies: ["VRoidSDKCore"]
        ),
        .testTarget(
            name: "VRoidSDKTests",
            dependencies: ["VRoidSDK", "VRoidSDKCore"]
        ),
    ]
)

for target in package.targets {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .strictMemorySafety(),
        ]
}
