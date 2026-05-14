import Foundation
import PhoneClawEngine

// MARK: - LiteRTBootstrap
//
// 进程启动期硬约束：在 @main init() 里同步执行，早于一切 LiteRT API 调用。
//
// 背景:
//   LiteRT 的 internal Environment / accelerator registry 是进程级单例，
//   在第一次 litert_lm_engine_create() 调用时被 sealed。GPU Metal accelerator
//   必须在此之前通过 dlopen 注册完毕，否则该进程生命周期内无法创建 GPU engine。
//
//   这是 CPU→GPU 热切换失败的根因：如果首次 engine_create 是 CPU，而 GPU
//   accelerator 还没注册，registry 就被 sealed 了，之后切 GPU 永远返回 NULL。
//
// 约束:
//   - 必须在 @main init() 第一行调用（早于 ContentView body 求值）
//   - 不能放在 ContentView.onAppear / Task {} — 时机不够早、不够确定
//   - 同步执行，阻塞主线程 ~2-5 ms（一次 dlopen）
//   - 幂等 — 内部 dispatch_once，多次调用安全
//
// 调用方:
//   PhoneClawApp.init()  →  LiteRTBootstrap.bootstrap()  (第一行)
//
// 不做的事:
//   - 不创建任何 engine（那是 LiteRTBackend.load() 的职责）
//   - 不加载 TopK Metal Sampler（等 GPU engine 创建成功后再 preload，
//     避免 ObjC class 重复注册 warning）
//   - 不做任何 async 操作

enum LiteRTBootstrap {

    /// Whether bootstrap has completed.
    private(set) static var isBootstrapped = false

    /// CFAbsoluteTime when bootstrap completed, or 0 if not yet called.
    private(set) static var bootstrapTimestamp: CFAbsoluteTime = 0

    /// Process-level one-shot initialization. Synchronous, blocks caller.
    ///
    /// Call this as the FIRST line in `@main App.init()`.
    ///
    /// What it does:
    /// 1. Suppresses TensorFlow runtime log noise (TF_CPP_MIN_LOG_LEVEL=2)
    /// 2. dlopen LiteRtMetalAccelerator.framework to register GPU backend
    /// 3. Records bootstrap timestamp for diagnostics
    ///
    /// Idempotent — subsequent calls are no-ops.
    static func bootstrap() {
        guard !isBootstrapped else { return }

        // 1. Suppress TF/LiteRT runtime noise early — must be before any
        //    LiteRT C API call that might trigger TF logging.
        PCLog.suppressRuntimeNoise()

        // 2. GPU accelerator preload — the critical path.
        //    This dlopen registers the Metal backend into LiteRT's singleton
        //    Environment before any engine_create can seal it.
        LiteRTRuntime.preloadGpuAccelerator()

        // 3. Mark complete.
        bootstrapTimestamp = CFAbsoluteTimeGetCurrent()
        isBootstrapped = true

        PCLog.event("litert_bootstrap",
                    detail: "gpu_preloaded=\(LiteRTRuntime.isGpuAcceleratorPreloaded) elapsed_ms=\(String(format: "%.1f", (bootstrapTimestamp - LiteRTRuntime.preloadTimestamp) * 1000))")
    }
}
