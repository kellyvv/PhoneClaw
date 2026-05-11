// swift-tools-version: 6.0
import PackageDescription

// PhoneClawEngine
//
// Swift Package for running on-device LLMs on iOS GPU (Metal) or CPU.
//
// 现在 vendored 两个 inference engine xcframework:
//
//   Frameworks/LiteRTLM.xcframework  — Google LiteRT-LM 引擎 + Metal sampler,
//                                     给 Gemma 4 (.litertlm) 用。详见 PhoneClaw
//                                     的 LiteRT backend 子目录。
//
//   Frameworks/llama.xcframework     — llama.cpp + OpenBMB mtmd-ios 扩展,
//                                     给 MiniCPM-V (.gguf) 用。详见
//                                     LocalPackages/PhoneClawEngine/Sources/
//                                     PhoneClawEngine/MTMD/。
//
// Build pipeline source of truth:
//   LiteRTLM:    /Users/<dev>/AITOOL/LiteRTLM-iOSNative (私有, bazel build)
//                + LocalPackages/PhoneClawEngine/patches/ 里归档的上游补丁。
//   llama:       https://github.com/OpenBMB/MiniCPM-V-Apps 的预编译版本,
//                包含他们自定义的 mtmd-ios C API (ANE 加速 vision tower)。
//
// 这两个 framework 都通过本地 binaryTarget 入库, 不走 SPM 远端引用 —
// 每次 C API wrapper 改动不需要发 release 和 bump 版本号。
//
// 重要: MTMD/ 下的 Swift 代码使用 Swift/C++ 互操作 (`std.string` 等),
// 需要 PhoneClawEngine target 开启 .interoperabilityMode(.Cxx)。
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
        // LiteRT-LM 引擎 — Gemma 4 (.litertlm)
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM.xcframework"
        ),
        // llama.cpp + mtmd-ios — MiniCPM-V (.gguf)
        // module name 在 framework Info.plist 里就叫 "llama", 不是 "CLlama"
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        ),
        .target(
            name: "PhoneClawEngine",
            dependencies: ["CLiteRTLM", "llama"],
            path: "Sources/PhoneClawEngine",
            swiftSettings: [
                // MTMDWrapper / MTMDParams 用了 `std.string(...)` 这种
                // Swift/C++ 互操作语法, 必须 .Cxx 模式才能编译。
                .interoperabilityMode(.Cxx),
            ]
        ),
    ]
)
