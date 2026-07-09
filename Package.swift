// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dbosk",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DBCore", targets: ["DBCore"]),
        .library(name: "DBDriverPostgres", targets: ["DBDriverPostgres"]),
        .library(name: "Connections", targets: ["Connections"]),
        .executable(name: "Dbosk", targets: ["Dbosk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DBCore"),
        .target(
            name: "DBDriverPostgres",
            dependencies: [
                "DBCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "Connections", dependencies: ["DBCore"]),
        .executableTarget(
            name: "Dbosk",
            dependencies: ["DBCore", "DBDriverPostgres", "Connections"]
        ),
        .testTarget(name: "DBCoreTests", dependencies: ["DBCore"]),
        .testTarget(name: "DBDriverPostgresTests", dependencies: ["DBDriverPostgres"]),
        .testTarget(name: "ConnectionsTests", dependencies: ["Connections"]),
    ]
)
