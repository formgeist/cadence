// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CadenceCore", targets: ["CadenceCore"]),
        .executable(name: "Cadence", targets: ["Cadence"]),
    ],
    dependencies: [
        // Not a product dependency: swift-testing normally ships inside Xcode's
        // toolchain, but this machine has Command Line Tools only, where
        // neither Testing nor XCTest is present. It is scoped to the test
        // target, so CadenceCore stays free of third-party code as PLAN.md §1
        // requires. Delete this once a full Xcode is installed.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "6.3.2"),
    ],
    targets: [
        // No third-party dependencies. Safe to import anywhere, including
        // previews and design prototypes.
        .target(name: "CadenceCore"),

        // The app. Depends only on CadenceCore, so it builds and runs with
        // no audio or database code compiled at all.
        .executableTarget(
            name: "Cadence",
            dependencies: ["CadenceCore"],
            resources: [.process("Resources")]
        ),

        .testTarget(
            name: "CadenceCoreTests",
            dependencies: [
                "CadenceCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
