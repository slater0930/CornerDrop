// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CornerDrop",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates. Keep in sync with SPARKLE_VERSION in scripts/setup-sparkle-tools.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "CornerDrop",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CornerDrop",
            linkerSettings: [
                // Sparkle.framework is embedded in CornerDrop.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
