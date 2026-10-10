// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "ConfCore", targets: ["ConfCore"]),
]
var targets: [Target] = [
    // Leitores, modelo e gravação de TOML 1.0 e JSON/JSONC — sem interface, testável.
    .target(name: "ConfCore"),
    .testTarget(
        name: "ConfCoreTests",
        dependencies: ["ConfCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
// O app (AppKit + SwiftUI) só existe no Mac; no Linux, `swift test` compila só o núcleo.
products.append(.executable(name: "km-conf", targets: ["km-conf"]))
targets.append(
    // Modo de linguagem 5: NSDocument ainda não tem anotações de concorrência completas.
    .executableTarget(
        name: "km-conf",
        dependencies: ["ConfCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "km-conf",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
