// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "km-conf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "km-conf", targets: ["km-conf"]),
        .library(name: "ConfCore", targets: ["ConfCore"]),
    ],
    targets: [
        // Leitor, modelo e gravação de TOML 1.0 — sem interface, testável.
        .target(name: "ConfCore"),
        // O app (AppKit + SwiftUI). Modo de linguagem 5: NSDocument ainda
        // não tem anotações de concorrência completas.
        .executableTarget(
            name: "km-conf",
            dependencies: ["ConfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ConfCoreTests",
            dependencies: ["ConfCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
