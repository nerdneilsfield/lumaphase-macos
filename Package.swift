// swift-tools-version: 6.0
import PackageDescription

// T1 keeps only the pure-Foundation core. OpticDisplay and LumaphaseApp are
// added by T2; both depend on OpticCore.
//
// Swift 5 language mode is deliberate: platform delegates used by T2
// (CAMetalDisplayLinkDelegate) are not Sendable-annotated, and the single
// render context required by the design is not expressible as a Swift 6
// concurrency contract without extra machinery.
let package = Package(
    name: "Lumaphase",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpticCore", targets: ["OpticCore"]),
        .library(name: "OpticDisplay", targets: ["OpticDisplay"]),
        .executable(name: "Lumaphase", targets: ["Lumaphase"])
    ],
    targets: [
        .target(
            name: "OpticCore",
            path: "Sources/OpticCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "OpticDisplay",
            dependencies: ["OpticCore"],
            path: "Sources/OpticDisplay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Lumaphase",
            dependencies: ["OpticCore", "OpticDisplay"],
            path: "Sources/LumaphaseApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpticCoreTests",
            dependencies: ["OpticCore"],
            path: "Tests/OpticCoreTests",
            resources: [.copy("Resources/protocol_test_vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpticDisplayTests",
            dependencies: ["OpticDisplay", "OpticCore"],
            path: "Tests/OpticDisplayTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
