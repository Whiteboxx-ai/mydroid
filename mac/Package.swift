// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mydroid",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MydroidCore", targets: ["MydroidCore"]),
        .executable(name: "Mydroid", targets: ["Mydroid"]),
        .executable(name: "mydroid-test-server", targets: ["mydroid-test-server"]),
        .executable(name: "mydroid-nmhost", targets: ["mydroid-nmhost"]),
    ],
    targets: [
        .target(name: "MydroidCore"),
        // Browser native messaging (Foundation only): Chrome's stdio framing, the Unix-socket line protocol, manifest install.
        .target(name: "MydroidNM"),
        .executableTarget(name: "Mydroid", dependencies: ["MydroidCore", "MydroidNM"]),
        // The helper Chrome starts for the authenticator extension (PROTOCOL.md 14.3). Built into Mydroid.app/Contents/MacOS.
        .executableTarget(name: "mydroid-nmhost", dependencies: ["MydroidNM"]),
        .executableTarget(name: "mydroid-test-server", dependencies: ["MydroidCore"]),
        .testTarget(name: "MydroidCoreTests", dependencies: ["MydroidCore", "MydroidNM"]),
        // Off-screen renders of the notification UI (set MYDROID_RENDER_DIR to write PNGs).
        .testTarget(name: "MydroidRenderTests", dependencies: ["Mydroid", "MydroidCore", "MydroidNM"]),
    ]
)
