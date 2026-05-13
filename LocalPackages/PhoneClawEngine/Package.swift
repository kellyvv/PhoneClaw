// swift-tools-version: 6.0
import PackageDescription

// PhoneClawEngine
//
// Swift Package for running on-device LLMs on iOS GPU (Metal) or CPU.
//
// 三个 target, 都通过 library product `PhoneClawEngine` 暴露:
//
//   PhoneClawEngine    Swift  Gemma 4 / LiteRT-LM (.litertlm)
//                             deps: CLiteRTLM
//                             swiftSettings: 无 — 一字不变维持 v1.3.2 行为
//
//   CMTMDBridge        C++   纯 C 桥接层, 把 OpenBMB mtmd-ios 的 C++ API
//                             (含 std::string) 包成 Swift 可直接调用的 C 接口。
//                             deps: llama
//                             headers: 对外只暴露 include/CMTMDBridge.h (纯 C)
//
//   MTMDEngine         Swift  MiniCPM-V wrapper, MTMDWrapper / MTMDParams 等。
//                             deps: CMTMDBridge — 不直接依赖 llama, 也不需要
//                                  Swift/C++ interop, 因此 .swiftmodule 不带
//                                  cxx-interop 标记, 消费者 (PhoneClaw app)
//                                  可以普通 import 而不开 cxx flag。
//
// 为什么搞 CMTMDBridge 中间层:
//   Swift/C++ interop (.interoperabilityMode(.Cxx)) 在 Swift 6 是病毒性
//   传染的 — MTMDEngine 一开 cxx, PhoneClaw app target 也必须开。app 一开
//   cxx, Clang 处理所有依赖头 (CocoaPods Yams 等) 的方式变严格, 撞 `extern "C"`
//   block 里 `#include <string.h>` 这种合法 C 写法直接挂。所以把 C++ 边界
//   收敛到 CMTMDBridge.cpp 一个文件里, 外层全部走纯 C。
//
// Build pipeline source of truth:
//   LiteRTLM:    /Users/<dev>/AITOOL/LiteRTLM-iOSNative (私有, bazel build)
//                + LocalPackages/PhoneClawEngine/patches/ 上游补丁归档。
//   llama:       https://github.com/OpenBMB/MiniCPM-V-Apps 预编译版本,
//                含他们自定义 mtmd-ios C API (ANE 加速 vision tower)。
//
let package = Package(
    name: "PhoneClawEngine",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "PhoneClawEngine", targets: ["PhoneClawEngine", "MTMDEngine"]),
    ],
    targets: [
        // ───────────────────────────────────────────────────────────
        // LiteRT-LM (Gemma 4) 主体
        // ───────────────────────────────────────────────────────────
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM.xcframework"
        ),

        // ───────────────────────────────────────────────────────────
        // LiteRT-LM plugin dylibs — 单独 framework 化
        // ───────────────────────────────────────────────────────────
        // App Store / TestFlight 不允许 .framework 里塞 standalone .dylib
        // (error 90171). 把三个 plugin dylib 各自包成独立 .framework, 再
        // 各自塞进一个 xcframework, 通过 SPM binaryTarget 让 app 自动 embed。
        //
        //   GemmaModelConstraintProvider  — CLiteRTLM 主二进制 hard-link
        //                                   (LC_LOAD_DYLIB), 必须 embed。
        //   LiteRtMetalAccelerator        — dlopen at runtime (GPU 路径)。
        //   LiteRtTopKMetalSampler        — dlopen at runtime (TopK sampler,
        //                                   device-only, 没 simulator slice)。
        //
        // Do not list the runtime-dlopen plugins as target dependencies.
        // SwiftPM turns binary target dependencies into LC_LOAD_DYLIB entries
        // in the app binary. Their install names intentionally remain
        // `@rpath/lib*.dylib` so LiteRT's basename dlopen can find them after
        // preloading; a hard link would make dyld look for naked dylib files at
        // launch, which is both absent from the framework layout and invalid
        // for App Store packaging. Xcode copies those two companion frameworks
        // with the "Copy LiteRT runtime plugin frameworks" build phase instead.
        .binaryTarget(
            name: "GemmaModelConstraintProvider",
            path: "Frameworks/GemmaModelConstraintProvider.xcframework"
        ),
        .binaryTarget(
            name: "LiteRtMetalAccelerator",
            path: "Frameworks/LiteRtMetalAccelerator.xcframework"
        ),
        .binaryTarget(
            name: "LiteRtTopKMetalSampler",
            path: "Frameworks/LiteRtTopKMetalSampler.xcframework"
        ),
        .target(
            name: "PhoneClawEngine",
            dependencies: [
                "CLiteRTLM",
                "GemmaModelConstraintProvider",
            ],
            path: "Sources/PhoneClawEngine"
            // 注意: 这里**没有** .interoperabilityMode(.Cxx),
            // 保持跟 v1.3.2 时一字不差。
        ),

        // ───────────────────────────────────────────────────────────
        // llama.cpp 二进制 — 给 CMTMDBridge 提供 mtmd_ios_* 实现
        // ───────────────────────────────────────────────────────────
        .binaryTarget(
            name: "llama",
            path: "Frameworks/llama.xcframework"
        ),

        // ───────────────────────────────────────────────────────────
        // C++ → C 桥接层 — 隔离所有 cxx 复杂度
        // ───────────────────────────────────────────────────────────
        // CMTMDBridge.cpp 用 std::string 拼装 mtmd_ios_params, 调 mtmd_ios_*,
        // 对外只暴露 CMTMDBridge.h 里的纯 C 接口。
        // SPM 通过文件扩展名识别 C++ (.cpp), publicHeadersPath 暴露 include/。
        .target(
            name: "CMTMDBridge",
            dependencies: ["llama"],
            path: "Sources/CMTMDBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
            ]
        ),

        // ───────────────────────────────────────────────────────────
        // MiniCPM-V Swift wrapper — 纯 Swift, 不带 cxx interop
        // ───────────────────────────────────────────────────────────
        .target(
            name: "MTMDEngine",
            dependencies: ["CMTMDBridge"],
            path: "Sources/MTMDEngine",
            swiftSettings: [
                // OpenBMB demo 代码是 Swift 5 风格 (deinit access non-Sendable,
                // @MainActor closure 跨 DispatchQueue 等), Swift 6 strict
                // concurrency 不接, 锁 v5 模式。
                // 注意: 没有 .interoperabilityMode(.Cxx) — 全部通过
                // CMTMDBridge.h 走 C 接口, 不直接碰 mtmd-ios.h 的 std::string。
                .swiftLanguageMode(.v5),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17  // mtmd-ios C++ 实现需要 C++17
)
