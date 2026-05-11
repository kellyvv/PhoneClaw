// swift-tools-version: 6.0
import PackageDescription

// PhoneClawEngine
//
// Swift Package for running on-device LLMs on iOS GPU (Metal) or CPU.
//
// 两个独立的 inference engine, 完全隔离的 target, 用同一个 library product
// 暴露给上层。这样新增 MTMD/MiniCPM-V 路径**不会**影响现有 LiteRT 路径的
// 编译参数、依赖图或 ABI:
//
//   target: PhoneClawEngine
//     ├─ deps: CLiteRTLM
//     ├─ swiftSettings: (无 — 跟引入 MiniCPM-V 前完全一致)
//     └─ sources: Sources/PhoneClawEngine/ (Gemma 4 wrapper, LiteRT-LM)
//
//   target: MTMDEngine (新增)
//     ├─ deps: llama
//     ├─ swiftSettings: .interoperabilityMode(.Cxx)
//     │   (MTMDParams 用 std.string 桥接到 mtmd_ios_params 这个 C++ 结构体)
//     └─ sources: Sources/MTMDEngine/ (MiniCPM-V wrapper, llama.cpp + mtmd-ios)
//
//   product: PhoneClawEngine (library)
//     └─ targets: [PhoneClawEngine, MTMDEngine]
//
// 上层 app 端:
//   import PhoneClawEngine  — 拿 LiteRT API (跟集成前一样, 无任何变化)
//   import MTMDEngine       — 拿 MiniCPM-V API (新)
//
// Build pipeline source of truth:
//   LiteRTLM:    /Users/<dev>/AITOOL/LiteRTLM-iOSNative (私有, bazel build)
//                + LocalPackages/PhoneClawEngine/patches/ 上游补丁归档。
//   llama:       https://github.com/OpenBMB/MiniCPM-V-Apps 的预编译版本,
//                含他们自定义的 mtmd-ios C API (ANE 加速 vision tower)。
//
let package = Package(
    name: "PhoneClawEngine",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // 一个 library product 同时暴露两个 target —— 上层 app 无需改
        // Package dependency 声明, 只在需要 MiniCPM-V 的源文件里加
        // `import MTMDEngine` 即可。
        .library(name: "PhoneClawEngine", targets: ["PhoneClawEngine", "MTMDEngine"]),
    ],
    targets: [
        // ───────────────────────────────────────────────────────────
        // LiteRT-LM (Gemma 4) — 现有路径, 不动
        // ───────────────────────────────────────────────────────────
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM.xcframework"
        ),
        .target(
            name: "PhoneClawEngine",
            dependencies: ["CLiteRTLM"],
            path: "Sources/PhoneClawEngine"
            // 注意: 这里**没有** .interoperabilityMode(.Cxx),
            // 保持跟 v1.3.2 时一字不差。MTMD 的 C++ interop 隔离在
            // MTMDEngine target 里, 不影响 LiteRT 路径。
        ),

        // ───────────────────────────────────────────────────────────
        // MiniCPM-V (llama.cpp + OpenBMB mtmd-ios) — 新增, 独立 target
        // ───────────────────────────────────────────────────────────
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        ),
        .target(
            name: "MTMDEngine",
            dependencies: ["llama"],
            path: "Sources/MTMDEngine",
            swiftSettings: [
                // MTMDParams.swift 用 `std.string(modelPath)` 这种
                // Swift/C++ 互操作语法直接构造 mtmd_ios_params 里的
                // std::string 字段, 必须 .Cxx 模式才能编译。
                // 这条设置只影响本 target, 不影响 PhoneClawEngine target。
                .interoperabilityMode(.Cxx),
            ]
        ),
    ]
)
