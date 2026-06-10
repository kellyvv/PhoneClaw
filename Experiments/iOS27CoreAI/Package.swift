// swift-tools-version: 6.0
import PackageDescription

// iOS27CoreAIExperiment
//
// Isolated research package for iOS 27 Core AI / Foundation Models probes.
// It deliberately does not attach to PhoneClaw.xcodeproj yet. The normal
// package build must keep working on non-iOS-27 toolchains; beta API code is
// guarded behind PHONECLAW_IOS27_BETA_SDK.

let package = Package(
    name: "IOS27CoreAIExperiment",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "IOS27CoreAIExperiment",
            targets: ["IOS27CoreAIExperiment"]
        ),
    ],
    targets: [
        .target(
            name: "IOS27CoreAIExperiment",
            path: "Sources/IOS27CoreAIExperiment",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IOS27CoreAIExperimentTests",
            dependencies: ["IOS27CoreAIExperiment"],
            path: "Tests/IOS27CoreAIExperimentTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
