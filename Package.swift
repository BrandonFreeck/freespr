// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "freespr",
    platforms: [.macOS(.v14)],
    targets: [
        // Single executable: CLI + headless agent in one binary. Zero third-party deps;
        // every framework is auto-linked by `import`.
        .executableTarget(
            name: "freespr",
            path: "Sources/freespr"
        )
    ],
    // Swift 5 language mode. This is a low-level system tool (CGEvent tap C
    // callbacks, Unmanaged pointers, manual main/audio/network threading) where Swift 6
    // strict-concurrency annotations add friction without real safety — we control the
    // threading by hand. Upgrade path: tighten to .v6 if the daemon ever grows real
    // shared mutable state across actors.
    swiftLanguageModes: [.v5]
)
