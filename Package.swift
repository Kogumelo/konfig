// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "ConfCore", targets: ["ConfCore"]),
]
var targets: [Target] = [
    // Readers, model and writers for TOML, JSON/JSONC/JSON5, .env, INI and YAML — no UI, testable.
    .target(name: "ConfCore"),
    .testTarget(
        name: "ConfCoreTests",
        dependencies: ["ConfCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// The app (AppKit + SwiftUI) only exists on the Mac; on Linux, `swift test` builds just the core.
products.append(.executable(name: "Konfig", targets: ["Konfig"]))
targets.append(
    // Language mode 5: NSDocument still lacks complete concurrency annotations.
    .executableTarget(
        name: "Konfig",
        dependencies: ["ConfCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "Konfig",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
