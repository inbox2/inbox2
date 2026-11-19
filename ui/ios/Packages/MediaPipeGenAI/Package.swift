// swift-tools-version:5.9
//
// Google's MediaPipe GenAI inference engine (the Bridge's free Gemma/LiteRT NLU
// lane) as an SPM package, because Google ships it through CocoaPods only.
//
// This is a local copy of the manifest from the community wrapper
// github.com/paescebu/SwiftTasksGenAI 0.10.24 — same three binary targets, same
// release URLs, same checksums. Vendored for one reason: that package declares
// `.unsafeFlags(["-ObjC"])`, and SwiftPM refuses unsafe flags in a *versioned
// remote* dependency (Xcode 27 enforces it; 26 let it through, so the iOS app
// stopped building the day Xcode updated). A local path dependency is allowed
// to carry them — and this one doesn't need to anyway: the app target already
// passes -ObjC in OTHER_LDFLAGS (project.yml), which is what that flag was for.
//
// The wrapper's own two source files are empty; all it ever did was re-export
// the binaries, which is what the shim target below does. Bumping the upstream
// version means copying the new URLs + checksums from its Package.swift.
import PackageDescription

let package = Package(
    name: "MediaPipeGenAI",
    platforms: [.iOS(.v13), .macOS(.v13)],
    products: [
        .library(name: "MediaPipeGenAI", targets: ["MediaPipeGenAIShim"])
    ],
    targets: [
        .target(
            name: "MediaPipeGenAIShim",
            dependencies: ["MediaPipeGenAICLibraries", "MediaPipeTasksGenAIC", "MediaPipeTasksGenAI"],
            path: "Sources/MediaPipeGenAI"
        ),
        .binaryTarget(
            name: "MediaPipeTasksGenAI",
            url: "https://github.com/paescebu/SwiftTasksGenAI/releases/download/0.10.24/MediaPipeTasksGenAI.xcframework.zip",
            checksum: "4a79aacb7864baf142448353a5131f48767bf861670cb25c70f682f97171e066"
        ),
        .binaryTarget(
            name: "MediaPipeGenAICLibraries",
            url: "https://github.com/paescebu/SwiftTasksGenAI/releases/download/0.10.24/MediaPipeGenAICLibraries.xcframework.zip",
            checksum: "681771c1c7234a910d03dabeb33fc7cdc3314731af2ef81f828bfc47b2a6cf46"
        ),
        .binaryTarget(
            name: "MediaPipeTasksGenAIC",
            url: "https://github.com/paescebu/SwiftTasksGenAI/releases/download/0.10.24/MediaPipeTasksGenAIC.xcframework.zip",
            checksum: "298c27c204c14cd3a8b737493f11515b9229590aac676f844fba26063b2f3b38"
        )
    ]
)
