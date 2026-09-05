// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenAir",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "OpenAir", targets: ["OpenAir"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "OpenAirCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "OpenAir", dependencies: ["OpenAirCore"]),
        .executableTarget(name: "OpenAirChecks", dependencies: ["OpenAirCore", "CSQLite"], path: "Checks")
    ]
)
