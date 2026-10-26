// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyPointOSC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KeyPointOSC", targets: ["KeyPointApp"]),
        .executable(name: "oscsend", targets: ["oscsend"]),
    ],
    targets: [
        // Backend-agnostic: OSC codec, UDP I/O, routing, feedback publishing, settings.
        .target(name: "KeyPointCore"),
        // App-specific backends that drive PowerPoint / Keynote via AppleScript.
        .target(name: "KeyPointBackends", dependencies: ["KeyPointCore"]),
        // Menu-bar app.
        .executableTarget(name: "KeyPointApp", dependencies: ["KeyPointCore", "KeyPointBackends"]),
        // Small CLI for sending OSC and watching feedback during development.
        .executableTarget(name: "oscsend", dependencies: ["KeyPointCore"]),
        .testTarget(name: "KeyPointCoreTests", dependencies: ["KeyPointCore"]),
        .testTarget(name: "KeyPointBackendsTests", dependencies: ["KeyPointBackends"]),
    ]
)
