// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    // iOS is here for the library products cadence-ios depends on:
    // CadenceCore and CadenceDesign. The app, CadenceLibrary and CadenceAudio
    // are macOS-only and are never built for iOS, because no iOS product
    // reaches them. The string form is because `.v26` needs tools 6.2.
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "CadenceCore", targets: ["CadenceCore"]),
        .library(name: "CadenceLibrary", targets: ["CadenceLibrary"]),
        .library(name: "CadenceAudio", targets: ["CadenceAudio"]),
        .library(name: "CadenceDesign", targets: ["CadenceDesign"]),
        .library(name: "CadenceServer", targets: ["CadenceServer"]),
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
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", from: "0.13.0"),
    ],
    targets: [
        // No third-party dependencies. Safe to import anywhere, including
        // previews and design prototypes.
        .target(name: "CadenceCore"),

        // Design tokens and the bundled faces: palette, spacing, radii, type
        // and motion. SwiftUI only, no third-party code, and no AppKit beyond
        // a conditional font lookup, so the iOS app imports the same values
        // the Mac draws with.
        .target(
            name: "CadenceDesign",
            resources: [.process("Resources")]
        ),

        // Decode, gapless, and metadata for every format SFB handles.
        .target(
            name: "CadenceAudio",
            dependencies: [
                "CadenceCore",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ]
        ),

        // SQLite store, FTS5 search, import scanner, artwork cache, and a
        // pure-Swift FLAC tag reader.
        .target(
            name: "CadenceLibrary",
            dependencies: [
                "CadenceCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // The read-only library server: an HTTP request parser, the
        // OpenSubsonic envelope, and the endpoints. Apple frameworks only,
        // beyond the store it reads.
        .target(
            name: "CadenceServer",
            dependencies: ["CadenceCore", "CadenceLibrary"]
        ),

        .executableTarget(
            name: "Cadence",
            dependencies: ["CadenceCore", "CadenceLibrary", "CadenceAudio", "CadenceDesign",
                           "CadenceServer"]
        ),

        .testTarget(
            name: "CadenceCoreTests",
            dependencies: [
                "CadenceCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        .testTarget(
            name: "CadenceDesignTests",
            dependencies: [
                "CadenceDesign",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        .testTarget(
            name: "CadenceServerTests",
            dependencies: [
                "CadenceServer",
                "CadenceCore",
                "CadenceLibrary",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        .testTarget(
            name: "CadenceAudioTests",
            dependencies: [
                "CadenceCore",
                "CadenceAudio",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        .testTarget(
            name: "CadenceLibraryTests",
            dependencies: [
                "CadenceCore",
                "CadenceLibrary",
                // Migration tests build a database at an older schema version
                // by hand, which needs the migrator's own API.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),

        // The app layer. `Cadence` is an executable, not a library, so this
        // target depends on it directly and reaches in with `@testable` — see
        // #44. Scoped to logic over injected state (`AppModel` takes `any
        // LibraryStore`); the rendered layer stays covered by `make shots` and
        // `make a11y`.
        .testTarget(
            name: "CadenceTests",
            dependencies: [
                "Cadence",
                "CadenceCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
