// swift-tools-version:5.9
import PackageDescription

// SPEC: §9 M1 asks for an "Xcode project". A SwiftPM package opens directly in Xcode, builds and
// tests from the command line, and keeps a small diffable manifest instead of a generated
// .pbxproj. `make app` wraps the executable in a signed .app bundle (the camera prompt and TCC
// permissions need a real bundle).
let package = Package(
    name: "GlanceFocus",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlanceFocusKit", path: "GlanceFocus", exclude: ["App"]),
        .executableTarget(name: "GlanceFocus", dependencies: ["GlanceFocusKit"], path: "GlanceFocus/App"),
        .testTarget(name: "GlanceFocusTests", dependencies: ["GlanceFocusKit"], path: "GlanceFocusTests"),
    ]
)
