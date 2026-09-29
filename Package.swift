// swift-tools-version: 6.0
// PhotoForge AI — modular Swift package + the PhotoForgeApp executable.
// See docs/ARCHITECTURE.md §4.

import PackageDescription
import Foundation

// VLC's playback engine (VLCKit, LGPL-2.1) is downloaded by CI into Vendor/ and linked when
// present; without it the app still builds and plays everything AVFoundation supports.
let vlcKitPath = Context.packageDirectory + "/Vendor/VLCKit.xcframework"
let hasVLCKit = FileManager.default.fileExists(atPath: vlcKitPath)

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
            "PFSimilarity", "PFPeople", "PFJobs", "PFEditing", "PFSafety", "PFClassify",
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
        .target(name: "PFClassify", dependencies: ["PFCore"], swiftSettings: settings),

        .executableTarget(
            name: "PhotoForgeApp",
            dependencies: ["PFCore", "PFDatabase", "PFPhotosBridge", "PFVision", "PFSimilarity",
                           "PFPeople", "PFJobs", "PFEditing", "PFSafety", "PFClassify",
                           .product(name: "GRDB", package: "GRDB.swift")] + (hasVLCKit ? ["VLCKit"] : []),
            swiftSettings: settings,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),

        .testTarget(name: "PFSimilarityTests", dependencies: ["PFSimilarity"], swiftSettings: settings),
        .testTarget(name: "PFPeopleTests", dependencies: ["PFPeople"], swiftSettings: settings),
        .testTarget(name: "PFDatabaseTests",
                    dependencies: ["PFDatabase", .product(name: "GRDB", package: "GRDB.swift")],
                    swiftSettings: settings),
        .testTarget(name: "PFEditingTests", dependencies: ["PFEditing", "PFSafety"], swiftSettings: settings),
        .testTarget(name: "PFClassifyTests", dependencies: ["PFClassify"], swiftSettings: settings),
        .testTarget(name: "PFCoreTests", dependencies: ["PFCore"], swiftSettings: settings),
    ] + (hasVLCKit ? [.binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework")] : [])
)
