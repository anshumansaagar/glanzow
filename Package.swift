// swift-tools-version:5.9
import PackageDescription

// SPEC: §9 M1 asks for an "Xcode project". A SwiftPM package opens directly in Xcode, builds and
// tests from the command line, and keeps a small diffable manifest instead of a generated
// .pbxproj. `make app` wraps the executable in a signed .app bundle (the camera prompt and TCC
// permissions need a real bundle).
let package = Package(
    name: "Glanzow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlanzowKit", path: "Glanzow", exclude: ["App"]),
        .executableTarget(name: "Glanzow", dependencies: ["GlanzowKit"], path: "Glanzow/App"),
        .executableTarget(name: "ReplayCLI", dependencies: ["GlanzowKit"], path: "ReplayCLI"),
        .testTarget(name: "GlanzowTests", dependencies: ["GlanzowKit"], path: "GlanzowTests"),
    ]
)
