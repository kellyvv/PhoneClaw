import Foundation
import CoreImage
import PhoneClawEngine

// MARK: - LiteRT Backend
//
// InferenceService conformer，内部持有 LiteRTLMEngine。
// CPU-only，无 GPU 分支。
//
// 推理路径:
//   - Chat 纯文本: persistent session + 增量 delta → KV cache 复用
//   - 单次多模态 (图/音): Conversation API → multimodal()
//   - Live: persistent multimodal conversation（文本/图像共用一份 KV cache）
//
// KV cache 复用: 模型加载后 openSession()，后续 generate() 只传增量 delta，
// KV cache 保留之前轮次的 context，TTFT 从 ~15-20s 降至 ~1-2s。
//
// 模型管理 (load/unload/select) 在这里实现。
// 资产管理 (download/install/path) 在 LiteRTModelStore 里。

@Observable
final class LiteRTBackend: InferenceService {

    // MARK: - State

    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var statusMessage = tr("等待加载模型...", "Waiting to load model...")
    private(set) var stats = InferenceStats()

    // MARK: - Sampling Config

    var samplingTopK: Int = 40
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 1.0
    var maxOutputTokens: Int = 8192

    // MARK: - Engine Mode (Lazy Multimodal Loading)

    /// 控制底层 LiteRTLMEngine 加载哪些 encoder.
    ///
    /// - `textOnly`: `visionBackend: nil, audioBackend: nil`.
    ///   SigLIP 视觉 encoder + USM 音频 encoder + 各自的 XNNPack cache
    ///   **都不进内存**. 省 ~800 MB pinned memory, 纯 chat 场景的默认.
    ///
    /// - `multimodal`: `visionBackend: "gpu", audioBackend: "cpu"`.
    ///   vision / audio encoder 常驻内存, 能直接跑 `generateMultimodal` / Live.
    ///
    /// 切换模式需要完整 unload + reload 引擎, 成本 ~6-7s (跟首次 load 一样).
    /// 当前策略是 **sticky**: 首次多模态请求自动升级到 `multimodal`, 之后保持,
    /// 直到外部显式调用 `revertToTextOnly()` 或切模型.
    enum EngineMode: Equatable {
        case textOnly
        case multimodal
    }

    /// 当前 engine 的加载模式. 默认 textOnly.
    private(set) var currentEngineMode: EngineMode = .textOnly

    /// 用户选择的推理 backend (`"gpu"` / `"cpu"`), 默认 cpu.
    /// 通过 `setPreferredBackend(_:)` 更新 (ConfigurationsView 挂 UI).
    /// load() 时读取这个值构造 LiteRTLMEngine.
    /// 默认 CPU: Sideloadly 免费签名 App 内存上限较低, GPU + E4B 会 OOM.
    private(set) var preferredBackend: String = "cpu"

    /// Gemma 4 MTP speculative decoding 开关. 默认 false.
    /// 通过 `setEnableSpeculativeDecoding(_:)` 更新, load() 时透传给
    /// LiteRTLMEngine。开启后 drafter 占 ~300-400 MB pinned RAM。
    /// 当前 V1 sampler 仅 sequence_size=1 路径正确, sequence_size>1 时会
    /// 跑诊断 dump (一次性) 帮助定位 layout, 然后回退到单 position argmax
    /// (verifier 输出会乱)。等 V2 sampler 修。
    private(set) var enableSpeculativeDecoding: Bool = false

    // MARK: - Internal

    private var engine: LiteRTLMEngine?
    private var loadedModelID: String?
    private var cancelled = false

    // MARK: - KV Cache Session State
    /// persistent session 是否已打开
    private(set) var kvSessionActive = false
    /// session 是否已有 context (已发过至少一次 input)
    /// 用于判断 delta vs 全量: session 有 context → 发 delta, 否则全量.
    private(set) var sessionHasContext = false
    /// 上一轮 model 输出 (用于拼 delta)。空 = 首轮。
    private(set) var lastModelOutput: String = ""
    /// Live 模式是否正在使用 persistent multimodal conversation。
    private(set) var liveModeActive = false
    /// 最近一轮 Session benchmark 里的 prefill token 数。
    private(set) var lastKVPrefillTokens: Int = 0
    /// text -> multimodal 后是否等待下次 text 生成时 lazy reopen text session。
    private var pendingTextSessionRestore = false
    /// 当前 multimodal turn 是否由 AgentEngine 的 session-group 编排接管。
    private var sessionGroupManagedMultimodal = false

    /// 模型文件路径解析 — 由外部 (ModelInstaller) 提供
    private let modelPathResolver: (String) -> URL?

    /// 加载成功后回调 (modelID) — 让 catalog 同步 loadedModel
    private let onModelLoaded: ((String) -> Void)?
    /// 卸载后回调 — 让 catalog 清 loadedModel
    private let onModelUnloaded: (() -> Void)?

    // MARK: - Init

    /// - Parameter modelPathResolver: 给定 modelID 返回 .litertlm 文件的 URL (nil = 未安装)
    init(
        modelPathResolver: @escaping (String) -> URL?,
        onModelLoaded: ((String) -> Void)? = nil,
        onModelUnloaded: (() -> Void)? = nil
    ) {
        self.modelPathResolver = modelPathResolver
        self.onModelLoaded = onModelLoaded
        self.onModelUnloaded = onModelUnloaded
        self.stats.backend = "litert-\(preferredBackend)"
    }

    /// 更新用户的推理 backend 偏好 ("gpu" / "cpu").
    /// **不会**立即 reload engine — 调用方在切换后需要显式 unload + load 来生效
    /// (通常通过 `AgentEngine.reloadModel()`).
    func setPreferredBackend(_ backend: String) {
        guard backend == "gpu" || backend == "cpu" else {
            print("[LiteRT] Ignoring invalid backend preference: \(backend)")
            return
        }
        guard self.preferredBackend != backend else { return }
        self.preferredBackend = backend
        self.stats.backend = "litert-\(backend)"
        print("[LiteRT] Preferred backend set to \(backend) (takes effect on next load)")
    }

    func setEnableSpeculativeDecoding(_ enabled: Bool) {
        guard self.enableSpeculativeDecoding != enabled else { return }
        self.enableSpeculativeDecoding = enabled
        print("[LiteRT] MTP speculative decoding \(enabled ? "enabled" : "disabled") (takes effect on next load)")
    }

    /// 便捷 init: 使用默认路径 (Documents/models/<fileName>)
    convenience init() {
        self.init { modelID in
            guard let descriptor = ModelDescriptor.allModels.first(where: { $0.id == modelID }) else {
                return nil
            }
            let modelsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("models", isDirectory: true)
            let path = modelsDir.appendingPathComponent(descriptor.fileName)
            return FileManager.default.fileExists(atPath: path.path) ? path : nil
        }
    }

    private static func promptRequiresFreshKVSession(_ prompt: String) -> Bool {
        prompt.hasPrefix("<|turn>system\n")
    }

    // MARK: - InferenceService: Lifecycle

    func load(modelID: String) async throws {
        try await load(modelID: modelID, mode: .textOnly)
    }

    /// 加载指定模型, 可选择 engine mode (textOnly / multimodal).
    /// - 如果同一模型 + 同一 mode 已加载: no-op.
    /// - 如果同一模型但 mode 不同: unload + reload (~6-7s).
    /// - 如果不同模型: unload + reload.
    func load(modelID: String, mode: EngineMode) async throws {
        guard !isLoading else { return }

        // 已加载同一模型 **且** 同一 mode — no-op
        if isLoaded, loadedModelID == modelID, currentEngineMode == mode { return }

        // 如果已加载 (不同模型 或 不同 mode), 先 unload
        if isLoaded { unload() }

        guard let modelPath = modelPathResolver(modelID) else {
            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            let name = descriptor?.displayName ?? modelID
            statusMessage = tr(
                "请先在配置中下载 \(name) 模型",
                "Please download the \(name) model in Configuration first."
            )
            throw ModelBackendError.modelFileMissing(name)
        }

        isLoading = true
        statusMessage = mode == .multimodal
            ? tr("正在加载多模态模型...", "Loading multimodal model...")
            : tr("正在加载模型...", "Loading model...")
        cancelled = false

        let loadStart = CFAbsoluteTimeGetCurrent()

        do {
            // Backend 配置按 mode 决定:
            //   textOnly:    vision=nil  / audio=nil   → 不加载 encoder, 省 ~800 MB
            //   multimodal:  vision="gpu"/ audio="cpu" → 加载 SigLIP + USM encoder
            //                (匹配 Gallery Android 的 EngineConfig,
            //                 Gemma 3n / Gemma 4 audio 都只能 CPU, vision 走 GPU)
            //
            // maxTokens KV cache 按模型分:
            //   E2B: 4096 (权重 2.4 GB, 有内存余量装更大 KV)
            //   E4B: 4096 (权重 3.4 GB, 加 4096 KV ~1 GB → 总 4.4 GB)
            //
            // 2026-04-25: E4B 从 2048 提到 4096. 之前 2048 是为了卡 Sideloadly
            // 免费签名 jetsam 阈值 (~3-4 GB), 但代价是英文 SKILL 触发首轮
            // hard-reject. Sideloadly 用户 E4B 本来内存就紧 (推荐用 E2B).
            //
            // GPU 也用 4096: Gemma 4 E2B .litertlm 的 compiled shape 按
            // magic_number=32003 → target=4096 配置, GPU compiled model 路径
            // 下 KV 维度必须匹配此值, 否则 CompiledModel::Create 直接失败。
            let maxKVTokens: Int = 4096
            let (visionBackend, audioBackend): (String?, String?) = {
                switch mode {
                case .textOnly:
                    return (nil, nil)
                case .multimodal:
                    return ("gpu", "cpu")
                }
            }()

            // enableBenchmark=false: 关掉 runtime benchmark 模式 (省少量 MB +
            // 安静 log). 副作用: `engine.lastSessionBenchmarkSnapshot` 会是 nil,
            // 所以下面 `lastKVPrefillTokens` 从 benchmark 取不到时会退到 0,
            // 不影响 KV cache 本身的复用逻辑 (只是 [Engine] prefill=... log
            // 在控制台里不再出现).
            //
            // MTP speculative decoding: 仅在 textOnly engine + 用户在
            // ConfigurationsView 显式开启时启用。multimodal engine 路径继续保持
            // false。当前 V1 sampler dylib 含一次性诊断 dump (sequence_size>1
            // 时打印 verifier logits 候选 layout 测试结果到 stderr), 帮助
            // 定位 V2 shader 该用什么 stride / 索引公式。
            let useSpeculativeDecoding = enableSpeculativeDecoding && mode == .textOnly
            let backendLabel = "litert-\(preferredBackend)\(useSpeculativeDecoding ? "+mtp" : "")"
            print("[LiteRT] Loading model=\(modelID) backend=\(preferredBackend) mode=\(mode) mtp=\(useSpeculativeDecoding ? "on" : "off")")
            let newEngine = LiteRTLMEngine(
                modelPath: modelPath,
                backend: preferredBackend,    // "gpu" 或 "cpu", 从 ConfigurationsView 选择驱动
                visionBackend: visionBackend,
                audioBackend: audioBackend,
                maxTokens: maxKVTokens,
                enableBenchmark: false,
                enableSpeculativeDecoding: useSpeculativeDecoding
            )
            try await newEngine.load()

            self.engine = newEngine
            self.loadedModelID = modelID
            self.currentEngineMode = mode
            self.isLoaded = true
            self.isLoading = false

            // Open persistent session for KV cache reuse
            try await newEngine.openSession(
                temperature: self.samplingTemperature,
                maxTokens: Int(self.maxOutputTokens)
            )
            self.kvSessionActive = true
        self.lastModelOutput = ""
        self.lastKVPrefillTokens = 0
        self.pendingTextSessionRestore = false
        self.sessionGroupManagedMultimodal = false
        print("[LiteRT] Persistent session opened for KV cache reuse (mode=\(mode))")

            let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            self.stats.loadTimeMs = elapsed
            self.stats.backend = backendLabel

            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            statusMessage = tr(
                "已加载 \(descriptor?.displayName ?? modelID)",
                "Loaded \(descriptor?.displayName ?? modelID)"
            )
            PCLog.modelLoaded(modelID: modelID, backend: backendLabel, loadMs: elapsed)
            onModelLoaded?(modelID)
        } catch {
            isLoading = false
            isLoaded = false

            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            let displayName = descriptor?.displayName ?? modelID
            print("[LiteRT] ❌ 加载 \(displayName) 失败: \(error.localizedDescription)")

            // 判断是否真的是文件问题 — 只有文件大小明显不对 (< 90% expectedFileSize)
            // 时才删除。GPU 引擎创建失败 (内存不足、Metal 初始化错误等) 不应该删除
            // 完好的模型文件, 否则用户切换 CPU↔GPU 失败后会被迫重新下载几 GB 模型。
            var shouldDeleteFile = false
            if let expected = descriptor?.expectedFileSize, expected > 0 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath.path)
                let actualSize = (attrs?[.size] as? Int64) ?? 0
                if actualSize < expected * 9 / 10 {
                    shouldDeleteFile = true
                    print("[LiteRT] 文件大小异常 (\(actualSize)/\(expected)), 判定为损坏, 自动清理")
                }
            }

            if shouldDeleteFile {
                try? FileManager.default.removeItem(at: modelPath)
                print("[LiteRT] 已删除: \(modelPath.lastPathComponent)")
                NotificationCenter.default.post(
                    name: Notification.Name("LiteRTModelCorrupt"),
                    object: nil,
                    userInfo: ["modelID": modelID]
                )
                statusMessage = tr(
                    "❌ \(displayName) 文件损坏，请重新下载",
                    "❌ \(displayName) file is corrupt. Please download it again."
                )
            } else {
                // 文件完好但引擎加载失败 — 可能是 GPU 不支持、内存不足等运行时问题,
                // 保留文件, 用户可以换回 CPU 或释放内存后重试。
                print("[LiteRT] 文件完好 (\(modelPath.lastPathComponent)), 保留不删除")
                let reason = error.localizedDescription
                if preferredBackend == "gpu" {
                    // GPU-specific guidance: the most common failure is Metal
                    // engine init failing due to memory or shader issues.
                    statusMessage = tr(
                        "❌ \(displayName) GPU 加载失败\nMetal 引擎初始化未成功，可能是设备内存不足。\n请切换到 CPU 模式重试。",
                        "❌ \(displayName) GPU load failed\nMetal engine init failed — likely insufficient memory.\nPlease switch to CPU mode."
                    )
                } else {
                    statusMessage = tr(
                        "❌ \(displayName) 加载失败: \(reason)\n模型文件已保留，可尝试切换到 CPU 重试。",
                        "❌ \(displayName) failed to load: \(reason)\nModel file kept. Try switching to CPU."
                    )
                }
            }

            PCLog.modelLoadFailed(modelID: modelID, reason: error.localizedDescription)
            throw error
        }
    }

    /// Async unload — explicit completion semantics for Coordinator.switchBackend().
    /// 实际实现走同步路径 (`destroySynchronously()` 同步阻塞直到 C 层资源全释放),
    /// 但暴露 async 签名让 Coordinator 拿到明确的 "await unload 完成" 信号。
    /// 见 docs/RUNTIME_ARCHITECTURE_PLAN.md §3.2 InferenceService 协议演进。
    func unloadAsync() async {
        unload()
    }

    func unload() {
        // Synchronously destroy the C engine and all its Metal/GPU resources.
        // This MUST complete before we return, because the caller (reloadModel)
        // immediately creates a new engine afterwards. If the old engine's
        // resources are still alive, litert_lm_engine_create will fail —
        // this was the root cause of CPU→GPU switch failures ("engine_create
        // returned NULL" on hot switch, but works on cold start).
        //
        // Previously this used `Task { @MainActor in engine?.unload() }` +
        // `engine = nil` — but the Task was fire-and-forget, and engine was
        // niled before the Task ran, making the unload a no-op. The actual
        // cleanup only happened in deinit (async, on a DIFFERENT serial queue
        // than the new engine), creating a race condition.
        engine?.destroySynchronously()
        engine = nil

        kvSessionActive = false
        liveModeActive = false
        lastModelOutput = ""
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false
        currentEngineMode = .textOnly  // reset 到默认, 下次 load 会重新设置
        loadedModelID = nil
        isLoaded = false
        isGenerating = false
        statusMessage = tr("等待加载模型...", "Waiting to load model...")
        onModelUnloaded?()
        PCLog.modelUnloaded()
    }

    // MARK: - Engine Mode Switching (Lazy Multimodal Reload)

    /// 确保 engine 当前是 `target` mode. 如果当前 mode 不同, **unload + reload** (~6-7s).
    ///
    /// 副作用:
    /// - KV cache 丢失 (engine 重建). 调用方需要知道下一轮 text chat 会全量 prefill.
    /// - live / multimodal session 状态被清空.
    /// - `isGenerating` 会在 reload 期间短暂为 true.
    ///
    /// 典型调用点:
    /// - `generateMultimodal(...)` 开头 → `.multimodal`
    /// - `enterLiveMode(...)` 开头    → `.multimodal`
    /// - 外部 UI 主动调 `revertToTextOnly()` → `.textOnly` (省 800 MB)
    @MainActor
    func ensureEngineMode(_ target: EngineMode) async throws {
        guard isLoaded, let modelID = loadedModelID else {
            // 没加载模型, 无需切换 (下次 load 会按请求的 mode 走)
            return
        }
        guard currentEngineMode != target else { return }

        print("[LiteRT] Engine mode switch: \(currentEngineMode) → \(target) (reloading engine…)")
        let reloadStart = CFAbsoluteTimeGetCurrent()
        try await load(modelID: modelID, mode: target)
        let elapsed = (CFAbsoluteTimeGetCurrent() - reloadStart) * 1000
        print("[LiteRT] Engine mode switched to \(target) in \(Int(elapsed))ms")
    }

    /// 显式降级回 text-only. 省 ~800 MB pinned memory (SigLIP + USM encoder).
    /// 外部可以在"多模态对话结束 / 用户切回 chat"时调用.
    /// 如果当前已经是 textOnly, no-op.
    @MainActor
    func revertToTextOnly() async {
        do {
            try await ensureEngineMode(.textOnly)
        } catch {
            print("[LiteRT] revertToTextOnly failed: \(error.localizedDescription)")
        }
    }

    /// 重置 KV cache session (新对话 / 切换会话时调用)
    func resetKVSession() async {
        guard let engine, isLoaded else { return }
        guard !liveModeActive else { return }
        engine.closeSession()
        kvSessionActive = false
        sessionHasContext = false
        lastModelOutput = ""
        lastKVPrefillTokens = 0
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false
        do {
            try await engine.openSession(
                temperature: samplingTemperature,
                maxTokens: Int(maxOutputTokens)
            )
            kvSessionActive = true
            print("[LiteRT] KV session reset")
        } catch {
            print("[LiteRT] KV session reset failed: \(error)")
        }
    }

    func enterLiveMode(systemPrompt: String?) async throws {
        // Lazy-reload to multimodal engine if still in text-only mode (~6-7s).
        // 首次进 Live 会触发. 后续 Live session 都用已加载的 multimodal engine.
        try await ensureEngineMode(.multimodal)

        // 原有逻辑完全不变: 重新 guard 一次, 拿到的是 (可能) reload 过的 engine.
        guard let engine, isLoaded else {
            throw ModelBackendError.modelNotLoaded
        }

        if liveModeActive {
            await exitLiveMode()
        }

        engine.closeConversation()
        if kvSessionActive {
            engine.closeSession()
        }

        kvSessionActive = false
        sessionHasContext = false
        lastModelOutput = ""
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false

        print("[LiteRT] 📋 Live system prompt (\(systemPrompt?.count ?? 0) chars): \"\(systemPrompt?.prefix(200) ?? "nil")\"")
        try await engine.openConversation(
            systemMessage: systemPrompt,
            temperature: samplingTemperature,
            maxTokens: Int(maxOutputTokens)
        )
        liveModeActive = true
        print("[LiteRT] Persistent Live conversation opened")
    }

    func exitLiveMode() async {
        guard let engine, isLoaded else {
            liveModeActive = false
            kvSessionActive = false
            sessionHasContext = false
            lastModelOutput = ""
            pendingTextSessionRestore = false
            sessionGroupManagedMultimodal = false
            return
        }

        if liveModeActive {
            engine.closeConversation()
        }
        liveModeActive = false
        kvSessionActive = false
        sessionHasContext = false
        lastModelOutput = ""
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false

        do {
            try await engine.openSession(
                temperature: samplingTemperature,
                maxTokens: Int(maxOutputTokens)
            )
            kvSessionActive = true
            print("[LiteRT] Persistent text session restored after Live")
        } catch {
            print("[LiteRT] Failed to restore text session after Live: \(error)")
        }
    }

    /// 标记 session 失效 (不操作引擎, 不阻塞 inferenceQueue).
    /// Live 退出时调用 — 此时 C API 可能仍在跑, 直接 closeSession 会死锁.
    /// 下次 generate() 检测到 !kvSessionActive 时自动重建.
    func invalidateKVSession() {
        kvSessionActive = false
        sessionHasContext = false
        lastModelOutput = ""
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false
    }

    func prepareForSessionGroupTransition(
        from previousGroup: SessionGroup?,
        to nextGroup: SessionGroup
    ) async {
        // live group 的进出由 enterLiveMode / exitLiveMode 独立处理。
        // hotfix 范围内的 session-group 编排只覆盖 text <-> multimodal。
        guard isLoaded, !liveModeActive else { return }

        switch (previousGroup, nextGroup) {
        case (_, .multimodal):
            sessionGroupManagedMultimodal = true
            if previousGroup == .text {
                pendingTextSessionRestore = true
            }
            if previousGroup == .text, kvSessionActive {
                engine?.closeSession()
                kvSessionActive = false
                sessionHasContext = false
                lastModelOutput = ""
                lastKVPrefillTokens = 0
                print("[LiteRT] Closed text session for multimodal group transition")
            }
        case (.multimodal, .text):
            if pendingTextSessionRestore {
                print("[LiteRT] Text session lazy reopen pending after multimodal")
            }
        default:
            break
        }
    }

    func cancel() {
        cancelled = true
        if liveModeActive, isGenerating {
            engine?.cancelConversation()
        }
        // Text session 仍没有显式 cancel — 通过 cancelled 标志在 stream 消费侧中断。
    }

    /// 恢复 persistent text session (multimodal 结束后调用).
    /// multimodalStreaming 内部会 close 自己创建的 conversation,
    /// 所以只需重新 openSession.
    private func restoreTextSession() async {
        guard let engine, isLoaded, !liveModeActive else { return }
        do {
            try await engine.openSession(
                temperature: samplingTemperature,
                maxTokens: Int(maxOutputTokens)
            )
            kvSessionActive = true
            pendingTextSessionRestore = false
            print("[LiteRT] Text session restored after multimodal")
        } catch {
            print("[LiteRT] Failed to restore text session: \(error)")
            // 下次 generate() 检测到 !kvSessionActive 会自动重建
        }
    }

    // MARK: - InferenceService: Text Generation

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }
        guard !liveModeActive else {
            return AsyncThrowingStream {
                $0.finish(throwing: LiteRTLMError.inferenceFailure("Live mode is active; use generateLive(...)"))
            }
        }

        isGenerating = true
        cancelled = false
        let startTime = CFAbsoluteTimeGetCurrent()

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var tokenCount = 0
                var firstTokenTime: Double?
                var modelOutput = ""
                var streamError: Error?

                do {
                    if self.pendingTextSessionRestore {
                        print("[LiteRT] Lazy reopening text session after multimodal group transition")
                    }

                    if self.pendingTextSessionRestore || !self.kvSessionActive {
                        await self.resetKVSession()
                    } else if self.sessionHasContext,
                              Self.promptRequiresFreshKVSession(prompt) {
                        print("[LiteRT] Full prompt with active KV session detected — resetting session before generation")
                        await self.resetKVSession()
                    }

                    let stream: AsyncThrowingStream<String, Error>
                    if self.kvSessionActive {
                        // Persistent session: prompt 是增量 delta，KV cache 复用
                        // 如果 prompt 是完整 system/history prompt，上面已经先重置 session，
                        // 避免把 full prompt 继续堆进旧 KV cache 造成 token 上限立刻耗尽。
                        stream = engine.sessionGenerateStreaming(input: prompt)
                        await MainActor.run { self.sessionHasContext = true }
                    } else {
                        // Fallback: one-shot (无 session)
                        stream = engine.generateStreaming(
                            prompt: prompt,
                            temperature: self.samplingTemperature,
                            maxTokens: self.maxOutputTokens
                        )
                    }

                    for try await token in stream {
                        if self.cancelled { break }
                        tokenCount += 1
                        if firstTokenTime == nil {
                            firstTokenTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        }
                        modelOutput += token
                        continuation.yield(token)
                    }
                    streamError = nil
                } catch {
                    streamError = error
                }

                // 先翻转 isGenerating=false, 再 finish() 通知消费方.
                // AgentEngine 的 onComplete 在 finish 后同步 set isProcessing=false,
                // 如果 isGenerating 还是 true, 会出现 (!isProcessing, isGenerating) 的
                // 不一致中间态, UI 上的 "发送/停止" 按钮就会多滞留 ~百毫秒的 red state.
                let finalOutput = modelOutput
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastModelOutput = finalOutput
                    self.lastKVPrefillTokens = engine.lastSessionBenchmarkSnapshot?.prefillTokenCounts.last ?? 0
                    self.isGenerating = false
                    if let ttft = firstTokenTime {
                        self.stats.ttftMs = ttft
                    }
                    self.stats.totalChunks = tokenCount
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    if elapsed > 0, tokenCount > 0 {
                        self.stats.chunksPerSec = Double(tokenCount) / elapsed
                    }
                    PCLog.perf(
                        ttftMs: Int(self.stats.ttftMs),
                        chunks: tokenCount,
                        chunksPerSec: self.stats.chunksPerSec,
                        headroomMB: MemoryStats.headroomMB
                    )
                }

                if let streamError {
                    continuation.finish(throwing: streamError)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - InferenceService: Multimodal Generation

    /// 外部入口: 先 lazy-reload 到 multimodal engine (如需), 再委托给原有实现.
    ///
    /// 首次调用触发 engine unload + reload (~6-7s) 以加载 vision/audio encoder;
    /// 之后保持 multimodal mode (sticky), 直到外部显式 `revertToTextOnly()`.
    /// 原有多模态逻辑在 `_generateMultimodalUnchecked(...)` 里**完全不动**.
    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                // 1. 确保 engine 在 multimodal mode (首次可能 reload 6-7s)
                do {
                    try await self.ensureEngineMode(.multimodal)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                // 2. 委托给原有实现 (zero-modify)
                let upstream = self._generateMultimodalUnchecked(
                    images: images,
                    audios: audios,
                    prompt: prompt,
                    systemPrompt: systemPrompt
                )
                do {
                    for try await chunk in upstream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 原有多模态实现, 保持不变. 只改了方法名 (加 `_` 前缀 + Unchecked 后缀).
    /// 调用方必须先确保 engine 已在 multimodal mode, 否则 `engine.multimodalStreaming`
    /// 会因为 vision/audio encoder 没加载而失败.
    private func _generateMultimodalUnchecked(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        let managedBySessionGroup = sessionGroupManagedMultimodal

        // LiteRT C API 同时只支持一个 session.
        // 当 AgentEngine 未启用 session-group 编排时，保持旧行为：
        // multimodalStreaming 内部会创建临时 conversation, 必须先关闭 persistent text session.
        if kvSessionActive {
            engine.closeSession()
            kvSessionActive = false
            sessionHasContext = false
            lastModelOutput = ""
            lastKVPrefillTokens = 0
            print("[LiteRT] Closed text session for multimodal inference")
        }

        isGenerating = true
        cancelled = false

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var mmError: Error?

                do {
                    // CIImage → JPEG Data
                    var imagesData: [Data] = []
                    for ciImage in images {
                        if let data = self.ciImageToJPEG(ciImage) {
                            imagesData.append(data)
                        }
                    }

                    // AudioInput → WAV Data (优先用原始文件字节，否则手动编码)
                    let audiosData = audios.map { audio -> Data in
                        if let raw = audio.rawFileData {
                            return raw
                        }
                        return audio.wavData
                    }

                    let fullPrompt = systemPrompt.isEmpty
                        ? prompt
                        : systemPrompt + "\n" + prompt

                    #if DEBUG
                    for (i, audio) in audios.enumerated() {
                        let isRaw = audio.rawFileData != nil
                        let durationSec = audio.rawFileData != nil
                            ? Double(audiosData[i].count) / (16000 * 2 + 44) * (Double(audiosData[i].count - 44) / (16000 * 2))
                            : Double(audio.samples.count) / max(audio.sampleRate, 1)
                        print("[LiteRT] audio[\(i)] source=\(isRaw ? "rawFile" : "pcmEncode") wavBytes=\(audiosData[i].count) dur=\(String(format: "%.2f", audio.sampleRate > 0 ? Double(max(audio.samples.count, audiosData[i].count / 2)) / audio.sampleRate : 0))s")
                    }
                    print("[LiteRT] images=\(imagesData.count) audios=\(audios.count) promptChars=\(fullPrompt.count) prompt=\"\(fullPrompt.prefix(120))\"")
                    #endif

                    // audio-only → engine.audio(format:.wav) 专用 API
                    // image / mixed → engine.multimodalStreaming

                    if imagesData.isEmpty, !audiosData.isEmpty {
                        let text = try await engine.audio(
                            audioData: audiosData[0],
                            prompt: fullPrompt,
                            format: .wav,
                            temperature: self.samplingTemperature,
                            maxTokens: Int(self.maxOutputTokens)
                        )
                        if !self.cancelled, !text.isEmpty {
                            continuation.yield(text)
                        }
                    } else {
                        let stream = engine.multimodalStreaming(
                            audioData: audiosData,
                            imagesData: imagesData,
                            prompt: fullPrompt,
                            temperature: self.samplingTemperature,
                            maxTokens: self.maxOutputTokens
                        )
                        for try await chunk in stream {
                            if self.cancelled { break }
                            continuation.yield(chunk)
                        }
                    }
                    mmError = nil
                } catch {
                    mmError = error
                }

                // 翻转 isGenerating BEFORE finish() — 跟 text 路径对齐, 避免 onComplete 误判为仍在生成.
                await MainActor.run { [weak self] in
                    self?.isGenerating = false
                    self?.sessionGroupManagedMultimodal = false
                }

                if let mmError {
                    continuation.finish(throwing: mmError)
                } else {
                    continuation.finish()
                }

                // session-group 编排启用时，multimodal -> text 采用 lazy reopen：
                // 下一次 text generate 前再重开 persistent session。
                if !managedBySessionGroup {
                    await self.restoreTextSession()
                }
            }
        }
    }

    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }
        guard liveModeActive else {
            return AsyncThrowingStream {
                $0.finish(throwing: LiteRTLMError.inferenceFailure("Live conversation is not active"))
            }
        }

        isGenerating = true
        cancelled = false
        let startTime = CFAbsoluteTimeGetCurrent()

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var tokenCount = 0
                var firstTokenTime: Double?
                var liveError: Error?

                do {
                    var imagesData: [Data] = []
                    for ciImage in images {
                        if let data = self.ciImageToJPEG(ciImage) {
                            imagesData.append(data)
                        }
                    }
                    let audiosData = audios.map(\.wavData)

                    print("[LiteRT] 📩 Live turn: prompt=\"\(prompt.prefix(300))\" images=\(imagesData.count) audios=\(audiosData.count)")
                    let stream = engine.conversationSendStreaming(
                        audioData: audiosData,
                        imagesData: imagesData,
                        prompt: prompt
                    )

                    for try await token in stream {
                        if self.cancelled { break }
                        tokenCount += 1
                        if firstTokenTime == nil {
                            firstTokenTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        }
                        continuation.yield(token)
                    }
                } catch {
                    liveError = error
                }

                // 翻转 isGenerating BEFORE finish() — 跟 text 路径对齐, 避免 red button lag.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isGenerating = false
                    if let ttft = firstTokenTime {
                        self.stats.ttftMs = ttft
                    }
                    self.stats.totalChunks = tokenCount
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    if elapsed > 0, tokenCount > 0 {
                        self.stats.chunksPerSec = Double(tokenCount) / elapsed
                    }
                    PCLog.perf(
                        ttftMs: Int(self.stats.ttftMs),
                        chunks: tokenCount,
                        chunksPerSec: self.stats.chunksPerSec,
                        headroomMB: MemoryStats.headroomMB
                    )
                }

                if let liveError {
                    continuation.finish(throwing: liveError)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - InferenceService: Raw Text

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        if images.isEmpty {
            // Live / warmup 每次传完整 prompt (非增量 delta), 走 one-shot。
            // 只有 Chat 路径 (generate(prompt:)) 走 persistent session。
            return generateOneShot(prompt: text)
        } else {
            // 有图: 走 Conversation API
            return generateMultimodal(
                images: images,
                audios: [],
                prompt: text,
                systemPrompt: ""
            )
        }
    }

    /// One-shot: 创建临时 session, 不复用 KV cache。
    /// Live 模式 + warmup 专用 (传完整 prompt, 非增量 delta)。
    /// LiteRTLM 同时只支持一个 session, 先关闭 persistent session。
    /// - Parameter maxTokens: 覆盖默认 maxOutputTokens. warmup 设 2 避免
    ///   C API 在 inferenceQueue 上跑完全部 token (break 只停消费端).
    func generateOneShot(prompt: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }
        if kvSessionActive {
            engine.closeSession()
            kvSessionActive = false
            lastModelOutput = ""
        }
        return engine.generateStreaming(
            prompt: prompt,
            temperature: samplingTemperature,
            maxTokens: maxTokens ?? maxOutputTokens
        )
    }

    // MARK: - Private Helpers

    private func ciImageToJPEG(_ ciImage: CIImage, maxDimension: Int = 1024) -> Data? {
        let context = CIContext()
        let extent = ciImage.extent

        // 缩放到 maxDimension
        let scale: CGFloat
        let longestSide = max(extent.width, extent.height)
        if longestSide > CGFloat(maxDimension) {
            scale = CGFloat(maxDimension) / longestSide
        } else {
            scale = 1.0
        }

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        return context.jpegRepresentation(
            of: scaledImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        )
    }
}

// `ModelBackendError` 已迁移到 LLM/Core/InferenceService.swift,
// 作为 backend-neutral 错误类型给 AgentEngine 分类。
// 任何 InferenceService 实现都可以抛它, CLI / MLX 后端同样可用。
