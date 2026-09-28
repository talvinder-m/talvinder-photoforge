// swift-tools-version: 6.0
// PhotoForge AI — modular Swift package. The Xcode app target (PhotoForgeApp)
// depends on these libraries; see docs/ARCHITECTURE.md §4.

import PackageDescription

let package = Package(
    name: "PhotoForge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotoForgeKit", targets: [
            "PFCore", "PFDatabase", "PFPhotosBridge", "PFVision",
            "PFSimilarity", "PFPeople", "PFJobs", "PFEditing", "PFSafety",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Pure value types, IDs, errors, settings. No Apple-framework imports beyond Foundation.
        .target(name: "PFCore"),

        // App database: GRDB, migrations, encrypted vector store, repositories.
        .target(
            name: "PFDatabase",
            dependencies: ["PFCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Migrations")]
        ),

        // PhotoKit access, change tracking, resource hashing, read-only package inspection.
        .target(name: "PFPhotosBridge", dependencies: ["PFCore"]),

        // Vision face detection + alignment, Core ML embedding runners, model registry.
        .target(name: "PFVision", dependencies: ["PFCore"]),

        // Hashing, quality metrics, duplicate grouping and best-shot scoring.
        // Platform-neutral except for Accelerate; unit-testable without Photos access.
        .target(name: "PFSimilarity", dependencies: ["PFCore"]),

        // Constrained face clustering, person confidence, review queue.
        .target(name: "PFPeople", dependencies: ["PFCore"]),

        // Background job scheduler: priorities, pause/resume, cancellation, system pressure.
        .target(name: "PFJobs", dependencies: ["PFCore"]),

        // Non-destructive edit stack, provenance, generative-edit plumbing.
        .target(name: "PFEditing", dependencies: ["PFCore", "PFSafety"]),

        // Content-safety policy gates for generative and adult-content workflows.
        .target(name: "PFSafety", dependencies: ["PFCore"]),

        .testTarget(name: "PFSimilarityTests", dependencies: ["PFSimilarity"]),
        .testTarget(name: "PFPeopleTests", dependencies: ["PFPeople"]),
        .testTarget(name: "PFDatabaseTests", dependencies: ["PFDatabase", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "PFEditingTests", dependencies: ["PFEditing", "PFSafety"]),
    ],
    swiftLanguageModes: [.v6]
)
