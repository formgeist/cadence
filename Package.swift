// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CadenceCore", targets: ["CadenceCore"]),
        .library(name: "CadenceLibrary", targets: ["CadenceLibrary"]),
        .executable(name: "Cadence", targets: ["Cadence"]),
    ],
    dependencies: [
        // Not a product dependency: swift-testing normally ships inside Xcode's
        // toolchain, but this machine has Command Line Tools only, where
        // neither Testing nor XCTest is present. It is scoped to the test
        // target, so CadenceCore stays free of third-party code as PLAN.md §1
        // requires. Delete this once a full Xcode is installed.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.3.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        // No third-party dependencies. Safe to import anywhere, including
        // previews and design prototypes.
        .target(name: "CadenceCore"),

        // SQLite store, FTS5 search, import scanner, artwork cache, and a
        // pure-Swift FLAC tag reader.
        .target(
            name: "CadenceLibrary",
            dependencies: [
                "CadenceCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        .executableTarget(
            name: "Cadence",
            dependencies: ["CadenceCore", "CadenceLibrary"],
            resources: [.process("Resources")]
        ),

        .testTarget(
            name: "CadenceCoreTests",
            dependencies: [
                "CadenceCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        .testTarget(
            name: "CadenceLibraryTests",
            dependencies: [
                "CadenceCore",
                "CadenceLibrary",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
