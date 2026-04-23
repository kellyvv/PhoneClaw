// swift-tools-version: 6.0
import PackageDescription

// PhoneClawEngine
//
// Swift Package for running LiteRT-LM language models on iOS GPU (Metal) or CPU.
//
// Vendored local xcframework pattern: the compiled binary (LiteRT-LM engine +
// Metal accelerator + a community-written native Metal TopK sampler + Gemma
// model constraint provider) lives next to this Package.swift under
// `Frameworks/LiteRTLM.xcframework`.
//
// Build pipeline source of truth:
//   /Users/<dev>/AITOOL/LiteRTLM-iOSNative (private build infra)
//   → `scripts/build-xcframework.sh /path/to/LiteRT-LM`
//   → produces `Frameworks/LiteRTLM.xcframework`
//   → `cp -R` it over the copy beside this Package.swift
//
// This replaces the earlier URL-hosted binaryTarget pattern: every C API
// wrapper change no longer requires cutting a GitHub release and bumping a
// version in the downstream app. See PhoneClaw commit `cff3b8d` for the
// rationale behind moving this package from remote SPM to local.
//
let package = Package(
    name: "PhoneClawEngine",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "PhoneClawEngine", targets: ["PhoneClawEngine"]),
    ],
    targets: [
        // Local binary xcframework. Updated in-place via
        // `./scripts/build-xcframework.sh` on the LiteRTLM-iOSNative side.
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM.xcframework"
        ),
        .target(
            name: "PhoneClawEngine",
            dependencies: ["CLiteRTLM"],
            path: "Sources/PhoneClawEngine"
        ),
    ]
)
