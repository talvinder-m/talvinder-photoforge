// swift-tools-version: 6.0
// PhotoForge AI — modular Swift package + the PhotoForgeApp executable.
// See docs/ARCHITECTURE.md §4.

import PackageDescription

// Swift 5 language mode: strict-concurrency diagnostics are warnings, not errors,
// while Apple's frameworks (Photos, Vision, Core Image) finish their Sendable audits.
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "PhotoForge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoForgeApp", targets: ["PhotoForgeApp"]),
        .library(name: "PhotoForgeKit", targets: [
            "PFCore", "PFDatabase", "PFPhotosBridge", "PFVision",
            "PFSimilarity", "PFPeople", "PFJobs", "PFEditing", "PFSafety",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "PFCore", swiftSettings: settings),
        .target(name: "PFDatabase",
                dependencies: ["PFCore", .product(name: "GRDB", package: "GRDB.swift")],
                swiftSettings: settings),
        .target(name: "PFPhotosBridge", dependencies: ["PFCore"], swiftSettings: settings),
        .target(name: "PFVision", dependencies: ["PFCore"], swiftSettings: settings),
        .target(name: "PFSimilarity", dependencies: ["PFCore"], swiftSettings: settings),
        .target(name: "PFPeople", dependencies: ["PFCore"], swiftSettings: settings),
        .target(name: "PFJobs", dependencies: ["PFCore"], swiftSettings: settings),
        .target(name: "PFEditing", dependencies: ["PFCore", "PFSafety"], swiftSettings: settings),
        .target(name: "PFSafety", dependencies: ["PFCore"], swiftSettings: settings),

        .executableTarget(
            name: "PhotoForgeApp",
            dependencies: ["PFCore", "PFDatabase", "PFPhotosBridge", "PFVision", "PFSimilarity",
                           "PFPeople", "PFJobs", "PFEditing", "PFSafety",
                           .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: settings
        ),

        .testTarget(name: "PFSimilarityTests", dependencies: ["PFSimilarity"], swiftSettings: settings),
        .testTarget(name: "PFPeopleTests", dependencies: ["PFPeople"], swiftSettings: settings),
        .testTarget(name: "PFDatabaseTests",
                    dependencies: ["PFDatabase", .product(name: "GRDB", package: "GRDB.swift")],
                    swiftSettings: settings),
        .testTarget(name: "PFEditingTests", dependencies: ["PFEditing", "PFSafety"], swiftSettings: settings),
    ]
)
