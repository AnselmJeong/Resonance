// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Resonance", platforms: [.macOS(.v14)],
    products: [.executable(name: "Resonance", targets: ["Resonance"]), .library(name: "ResonanceCore", targets: ["ResonanceCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "ResonanceCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "Resonance", dependencies: ["ResonanceCore"]),
        .testTarget(name: "ResonanceCoreTests", dependencies: ["ResonanceCore"])
    ], swiftLanguageModes: [.v5]
)
