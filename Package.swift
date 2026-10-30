// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrbitCore",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [.library(name: "OrbitCore", targets: ["OrbitCore"]),
               .executable(name: "orbit-mcp", targets: ["OrbitMCP"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "OrbitCore", dependencies: ["CSQLite"], resources: [.copy("Resources")]),
        .executableTarget(name: "OrbitMCP", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"])
    ]
)
