// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "FaceUnlock",
            path: "Sources/FaceUnlock",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
