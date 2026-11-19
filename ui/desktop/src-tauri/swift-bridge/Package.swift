// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FoundationModelsBridge",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "FoundationModelsBridge",
            path: "Sources/FoundationModelsBridge"
        )
    ]
)
