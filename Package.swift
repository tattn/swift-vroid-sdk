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
    ],
    targets: [
        .target(
            name: "VRoidSDK"
        ),
        .testTarget(
            name: "VRoidSDKTests",
            dependencies: ["VRoidSDK"]
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
