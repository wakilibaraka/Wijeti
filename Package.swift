// swift-tools-version: 6.0
import PackageDescription

// WijetiCore is deliberately free of AppKit so that a Linux or Windows host can
// implement HostPlatform and reuse every model, the server supervisor and the settings
// store unchanged. Only WijetiMacOS imports platform frameworks.
// Language mode is pinned to v5: the WebKit and AppKit delegate callbacks hop between
// the main queue and Foundation's process pipes, and strict Swift 6 concurrency checking
// turns those into errors without changing any behaviour.
let package = Package(
    name: "Wijeti",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WijetiApp", targets: ["WijetiApp"])
    ],
    dependencies: [
        // Automatic updates. Sparkle verifies every download against an EdDSA signature.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(name: "WijetiCore"),
        .target(
            name: "WijetiMacOS",
            dependencies: [
                "WijetiCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "WijetiApp",
            dependencies: ["WijetiCore", "WijetiMacOS"]
        ),
        .testTarget(name: "WijetiCoreTests", dependencies: ["WijetiCore"]),
        .executableTarget(
            name: "SnapGen",
            dependencies: ["WijetiCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
