// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PaperCompanion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PaperCompanionCore", targets: ["PaperCompanionCore"]),
        .executable(name: "PaperCompanion", targets: ["PaperCompanion"])
    ],
    targets: [
        .target(
            name: "PaperCompanionCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "PaperCompanion",
            dependencies: ["PaperCompanionCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PaperCompanionCoreTests",
            dependencies: ["PaperCompanionCore"]
        ),
        .testTarget(
            name: "PaperCompanionAppTests",
            dependencies: ["PaperCompanion", "PaperCompanionCore"]
        )
    ]
)
