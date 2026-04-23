import Foundation
import CoreImage
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MLX Local LLM Service

public struct BundledModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let directoryName: String
    public let displayName: String
    public let repositoryID: String
    public let requiredFiles: [String]

    /// Planner 及其他结构化 JSON 输出场景是否可用。
    /// false 时 Planner 入口会被跳过（具体降级策略见 architecture-decisions.md ADR-004）。
    public let supportsStructuredPlanning: Bool

    /// 运行时 budget / thinking / fallback 行为数据。所有 headroom→token 表都在这里,
    /// 框架层 RuntimeBudgets 只查表, 不判断 model.id。
    public let runtimeProfile: ModelRuntimeProfile

    // Hashable / Equatable: 仅用 id (ModelRuntimeProfile 不 Hashable)
    public static func == (lhs: BundledModelOption, rhs: BundledModelOption) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// MLX GPU inference service for Gemma 4.
/// Forces MLX Metal GPU path — no CPU fallback.
@Observable
public class MLXLocalLLMService: LLMEngine, InferenceService {
    private static var isSimulatorRuntime: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        #endif
    }

    private static let liveComponentTestLock = NSLock()
    private static var liveComponentTestStarted = false

    private static func mlxMemoryDiagnostics() -> String {
        guard !isSimulatorRuntime else {
            return "simulator-skip"
        }
        return "active: \(MLX.GPU.activeMemory / 1_048_576) MB, cache: \(MLX.GPU.cacheMemory / 1_048_576) MB"
    }

    private static func takeLiveComponentTestLaunchToken() -> Bool {
        guard ProcessInfo.processInfo.environment["PHONECLAW_RUN_LIVE_COMPONENT_TEST"] == "1" else {
            return false
        }

        return liveComponentTestLock.withLock {
            if liveComponentTestStarted {
                return false
            }
            liveComponentTestStarted = true
            return true
        }
    }

    static let availableModels: [BundledModelOption] = [
        .init(
            id: "gemma-4-e2b-it-4bit",
            directoryName: "gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            repositoryID: "mlx-community/gemma-4-e2b-it-4bit",
            requiredFiles: [
                "config.json",
                "generation_config.json",
                "model.safetensors",
                "model.safetensors.index.json",
                "processor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "chat_template.jinja"
            ],
            supportsStructuredPlanning: false,
            runtimeProfile: MLXModelProfiles.gemma4_e2b
        ),
        .init(
            id: "gemma-4-e4b-it-4bit",
            directoryName: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B",
            repositoryID: "mlx-community/gemma-4-e4b-it-4bit",
            requiredFiles: [
                "config.json",
                "generation_config.json",
                "model.safetensors",
                "model.safetensors.index.json",
                "processor_config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "chat_template.jinja"
            ],
            supportsStructuredPlanning: true,
            runtimeProfile: MLXModelProfiles.gemma4_e4b
        )
    ]
    static let defaultModel = availableModels[0]

    // MARK: - State

    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    public private(set) var isGenerating = false
    public private(set) var stats = LLMStats()
    public var statusMessage = "等待加载模型..."
    public internal(set) var selectedModel = defaultModel
    public internal(set) var loadedModel: BundledModelOption?
    public var modelDisplayName: String { loadedModel?.displayName ?? selectedModel.displayName }
    public var selectedModelID: String { selectedModel.id }
    public var loadedModelID: String? { loadedModel?.id }
    public internal(set) var modelInstallStates: [String: ModelInstallState] = [:]
    public internal(set) var modelDownloadMetrics: [String: ModelDownloadMetrics] = [:]

    // MARK: - Compatibility Settings

    public var useGPU = true
    public var samplingTopK: Int = 40
    public var samplingTopP: Float = 0.95
    public var samplingTemperature: Float = 1.0
    public var maxOutputTokens: Int = 4000

    // Internal (not private) so extensions in ModelDownloader/Installer/GPULifecycle
    // files can read/write these. Not part of the public API.
    var modelContainer: ModelContainer?
    var cancelled = false
    var currentLoadTask: Task<Void, Never>?
    var currentGenerationTask: Task<Void, Never>?
    var currentDownloadTasks: [String: Task<Void, Never>] = [:]
    let foregroundStateLock = NSLock()
    var foregroundGPUAllowed = true
    var lifecycleObserverTokens: [NSObjectProtocol] = []
    var audioCapabilityEnabled = false
    let capabilitySwitchLock = NSLock()
    var capabilitySwitchPending = false
    var admittedWorkCount = 0  // number of active load/generate tasks admitted past the gate
    var liveModeSystemPrompt: String?

    // MARK: - KV Cache Reuse state
    //
    // Cross-turn prompt prefix caching. Implementation in
    // MLXLocalLLMService+KVReuse.swift. Flag is public so harness/tests can
    // flip it off to verify cache-on vs cache-off parity on routing + tool_call.
    public var kvReuseEnabled: Bool = true
    var activeCache: [MLXLMCommon.KVCache]?
    var cachedPromptTokens: [Int] = []

    /// Local path to the model directory
    var modelPath: URL {
        ModelPaths.resolve(for: selectedModel)
    }

    // MARK: - Init

    public init(selectedModelID: String? = nil) {
        if let selectedModelID,
           let option = Self.availableModels.first(where: { $0.id == selectedModelID }) {
            self.selectedModel = option
        }
        // F3 + KV reuse 对 E4B 工作良好 (cache hit 89-96%, 真机不再闪崩),
        // 但 E2B + F3 + KV reuse 组合实测**所有 R2 follow-up 0 token 空输出**
        // (真机 2026-04-17 验证), 用户感知是助理"沉默". E4B 同 prompt 正常.
        // 推测: E2B 在 KV cache 复用 R1 prefix 时, 模型状态包含 R1 end-of-turn
        // 信号, 跟 F3 follow-up 的 prompt 交互导致提前 emit EOS. 还需深查.
        // 暂时 E2B 仍关 KV reuse, F3 prompt 结构对 E2B 仍有效 (R2 lean follow-up
        // 替代成 continuation 形式的好处保留, 只是没 cache 加速).
        self.kvReuseEnabled = !self.selectedModel.id.contains("e2b")
        self.stats.backend = "mlx-gpu"
        configureLifecycleObservers()
        cleanupStalePartialDirectories()
        refreshModelInstallStates()
    }

    deinit {
        for token in lifecycleObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Convenience init with default model location
    public convenience init() {
        self.init(selectedModelID: nil)
    }

    private static func makeMLXAudio(from audio: AudioInput) -> UserInput.Audio {
        .pcm(.init(
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount
        ))
    }

    func loadModel() {
        currentLoadTask?.cancel()
        currentLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.currentLoadTask = nil }

            // Admission gate: atomically check switch flag and register work
            let admitted: Bool = self.capabilitySwitchLock.withLock {
                if self.capabilitySwitchPending { return false }
                self.admittedWorkCount += 1
                return true
            }
            guard admitted else {
                print("[MLX] loadModel: capability switch pending, aborting")
                return
            }
            defer {
                self.capabilitySwitchLock.withLock { self.admittedWorkCount -= 1 }
            }

            do {
                if self.isLoading {
                    return
                }
                try await load()
                try await warmup()
            } catch is CancellationError {
                await MainActor.run {
                    if self.statusMessage.hasPrefix("正在加载") || self.statusMessage.hasPrefix("正在初始化") {
                        self.statusMessage = "已取消模型切换"
                    }
                }
            } catch {
                if let mlxError = error as? MLXError,
                   case .modelDirectoryMissing = mlxError {
                    statusMessage = "请在配置中下载 \(self.selectedModel.displayName) 模型"
                } else {
                    statusMessage = "❌ \(error.localizedDescription)"
                }
                self.isLoaded = false
                self.loadedModel = nil
                self.refreshModelInstallStates()
                print("[MLX] Load failed: \(error.localizedDescription)")
            }
        }
    }

    func generateStream(
        prompt: String,
        images: [CIImage] = [],
        audios: [UserInput.Audio] = [],
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(prompt: prompt, images: images, audios: audios) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    let completedResponse = fullResponse
                    onComplete(.success(completedResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    func generateStream(
        chat: [Chat.Message],
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(chat: chat) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    let completedResponse = fullResponse
                    onComplete(.success(completedResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    func generateStream(
        chat: [Chat.Message],
        additionalContext: [String: any Sendable]?,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(chat: chat, additionalContext: additionalContext) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    let completedResponse = fullResponse
                    onComplete(.success(completedResponse))
                }
            } catch {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    // MARK: - LLMEngine Protocol

    public func load() async throws {
        if isLoading {
            return
        }
        let model = selectedModel
        let path = ModelPaths.resolve(for: model)
        isLoading = true
        defer {
            isLoading = false
        }
        statusMessage = "正在初始化模型..."
        await Gemma4Registration.setAudioCapabilityEnabled(audioCapabilityEnabled)
        await Gemma4Registration.register()

        guard ModelPaths.hasRequiredFiles(model, at: path) else {
            throw MLXError.modelDirectoryMissing(model.displayName)
        }

        statusMessage = "正在加载 \(model.displayName)..."
        let loadStart = CFAbsoluteTimeGetCurrent()
        print("[MLX] load capability — audio=\(audioCapabilityEnabled ? 1 : 0)")

        // ── Memory diagnostics (read before load) ──────────────────────────────
        let physMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let (footprintBefore, limitBefore) = MemoryStats.footprintMB()
        print("[MEM] Physical RAM: \(Int(physMB)) MB")
        print("[MEM] Before load — footprint: \(Int(footprintBefore)) MB, jetsam limit: \(Int(limitBefore)) MB")
        print("[MEM] MLX before — \(Self.mlxMemoryDiagnostics())")

        let container = try await VLMModelFactory.shared.loadContainer(
            from: path,
            using: MLXTokenizersLoader()
        )

        try Task.checkCancellation()
        self.modelContainer = container
        self.isLoaded = true
        self.loadedModel = model

        // ── Memory diagnostics (read after load) ───────────────────────────────
        let (footprintAfter, _) = MemoryStats.footprintMB()
        print("[MEM] After load  — footprint: \(Int(footprintAfter)) MB")
        print("[MEM] MLX after   — \(Self.mlxMemoryDiagnostics())")

        let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        stats.loadTimeMs = elapsed
        statusMessage = "模型已就绪 ✅ (\(Int(elapsed))ms)"

        print("[MLX] Model loaded in \(Int(elapsed))ms — backend: mlx-gpu — model: \(model.displayName)")
    }

    private func ensureAudioCapability(hasAudio: Bool) async throws {
        guard hasAudio != audioCapabilityEnabled || !isLoaded || modelContainer == nil else {
            return
        }

        audioCapabilityEnabled = hasAudio
        print("[MLX] capability switch requested — audio=\(hasAudio ? 1 : 0)")

        if isLoaded || modelContainer != nil {
            await prepareForReload(cancelCurrentGeneration: false, cancelCurrentLoad: false)
        }

        try await load()
    }

    // MARK: - Live Mode Capability Preload
    //
    // Peterson's admission protocol: both sides (generation/load vs capability switch)
    // publish their intent FIRST, then check the other side.

    public func prepareForLiveMode() async throws {
        if audioCapabilityEnabled && isLoaded { return }

        let maxAttempts = 10

        for attempt in 1...maxAttempts {
            // Wait for in-flight work to finish
            while isLoading || isGenerating {
                print("[MLX] prepareForLiveMode: waiting... (attempt \(attempt))")
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if audioCapabilityEnabled && isLoaded { return }

            // Atomically: check no admitted work, then set switch flag
            let acquired: Bool = capabilitySwitchLock.withLock {
                if admittedWorkCount > 0 { return false }
                capabilitySwitchPending = true
                return true
            }

            guard acquired else {
                // Admitted work is still running, retry
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            // Flag set AND no admitted work. Perform the switch.
            do {
                try await ensureAudioCapability(hasAudio: true)
                capabilitySwitchLock.withLock { capabilitySwitchPending = false }
                return
            } catch {
                capabilitySwitchLock.withLock { capabilitySwitchPending = false }
                throw error
            }
        }

        capabilitySwitchLock.withLock { capabilitySwitchPending = false }
        print("[MLX] prepareForLiveMode: could not reach stable idle")
        throw MLXError.modelBusy
    }

    /// 当前可用内存 headroom（MB）。Agent 用来动态调整 history 深度。
    public var availableHeadroomMB: Int {
        MemoryStats.headroomMB
    }

    /// 根据当前剩余内存推荐安全的 history 深度（消息条数）。
    /// Chunked prefill (LLM/MLX/Gemma4Model.swift) 把单次 forward 的 transient
    /// 内存峰值钉死在 chunk² (windowSize=256), 不再随总序列长度线性增长。
    /// 因此 history 可以放更多: KV cache 增量是每 token ~14KB × layers, 几条
    /// 历史消息只多几十 MB, 远低于现在 ~1GB 的稳定 headroom。
    public var safeHistoryDepth: Int {
        let profile = (loadedModel ?? selectedModel).runtimeProfile
        return RuntimeBudgets.safeHistoryDepth(profile: profile, headroom: availableHeadroomMB)
    }


    public func warmup() async throws {
        // Warmup skipped for E2B.
        //
        // E2B has 26 layers (E4B has 42). Running MLXLMCommon.generate() for the first time
        // triggers Metal JIT shader compilation across all unique kernel variants
        // (attention, MLP, PLE, RoPE ...). This compilation adds a temporary
        // memory spike on top of the already-loaded 4.9 GB weights, which pushes
        // the process past the jetsam limit on iPhone 17 Pro Max.
        //
        // Skipping warmup means the first user inference compiles shaders lazily
        // (first response is ~2-3s slower) but avoids the OOM kill on startup.
        print("[MLX] Warmup skipped — shaders will compile on first inference")
        statusMessage = "模型已就绪 ✅"

        #if DEBUG && canImport(UIKit)
        // LiveComponentTest 在 Live/Debug/ 下, iOS-only. Mac CLI 不 symlink Live/,
        // 所以这个 opt-in Debug 分支只对 iOS build 生效.
        let isRunningXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

        if !isRunningXCTest && Self.takeLiveComponentTestLaunchToken() {
            // Debug-only opt-in E2E path for live voice validation.
            // Never override the user's selected model, and only launch once
            // per process so reloads/model switches don't start a second audio loop.
            Task { await LiveComponentTest.runLiveLoop(inference: self) }
        }
        #endif
    }

    public func load(modelID: String) async throws {
        if let option = Self.availableModels.first(where: { $0.id == modelID }) {
            if selectedModel.id != option.id {
                selectedModel = option
                if isLoaded || isLoading || modelContainer != nil {
                    await prepareForReload()
                }
            }
        }
        try await load()
        try await warmup()
    }

    public func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt, images: [], audios: [])
    }

    public func enterLiveMode(systemPrompt: String?) async throws {
        liveModeSystemPrompt = systemPrompt
        try await prepareForLiveMode()
    }

    public func exitLiveMode() async {
        liveModeSystemPrompt = nil
    }

    public func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        let mlxAudios = audios.map(Self.makeMLXAudio(from:))

        if systemPrompt.isEmpty {
            return generateStream(prompt: prompt, images: images, audios: mlxAudios)
        }

        let chatImages = images.map { UserInput.Image.ciImage($0) }
        let chat: [Chat.Message] = [
            .system(systemPrompt),
            .user(prompt, images: chatImages, audios: mlxAudios),
        ]
        return generateStream(chat: chat)
    }

    public func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        generateStream(rawText: text, images: images)
    }

    public func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        generateMultimodal(
            images: images,
            audios: audios,
            prompt: prompt,
            systemPrompt: liveModeSystemPrompt ?? ""
        )
    }

    public func generateStream(
        prompt: String,
        images: [CIImage],
        audios: [UserInput.Audio]
    ) -> AsyncThrowingStream<String, Error> {
        let input: UserInput
        if images.isEmpty, audios.isEmpty {
            input = UserInput(prompt: prompt)
        } else {
            input = UserInput(
                chat: [
                    .user(
                        prompt,
                        images: images.map { .ciImage($0) },
                        audios: audios
                    )
                ]
            )
        }
        return generateStream(input: input, isMultimodal: !images.isEmpty || !audios.isEmpty)
    }

    public func generateStream(chat: [Chat.Message]) -> AsyncThrowingStream<String, Error> {
        generateStream(chat: chat, additionalContext: nil)
    }

    public func generateStream(
        chat: [Chat.Message],
        additionalContext: [String: any Sendable]?
    ) -> AsyncThrowingStream<String, Error> {
        let input = UserInput(chat: chat, additionalContext: additionalContext)
        let hasMedia = !input.images.isEmpty || !input.audios.isEmpty
        return generateStream(input: input, isMultimodal: hasMedia)
    }

    /// Raw text prompt path — 绕开 tokenizer 的 applyChatTemplate.
    ///
    /// 历史遗留 raw text prompt 路径。
    /// 调用方手写完整模板时，可用它绕开 tokenizer 的 applyChatTemplate。
    ///
    /// 对比:
    ///   - `generateStream(prompt:images:audios:)`: 走标准 chat/user 输入
    ///   - 本方法 (纯文本): 命中 Gemma4Processor 的 text 分支, 直接按原文编码
    ///
    /// 多模态分流 (真机 2026-04-16 验证):
    ///   `.text` 分支在 E2B + vision 场景下 MLX 内部 forward graph 内存 spike 突破
    ///   jetsam 6144 MB → 应用闪崩. `.chat` 分支同场景已验证稳定 (用户多次摄像头
    ///   交互无崩溃). 因此**有 image 时回退到 chat path**, persona/marker 修复
    ///   只对纯文本场景生效 — 视觉场景 user 通常问"这是什么", 不需要 persona 锚点.
    public func generateStream(
        rawText: String,
        images: [CIImage] = []
    ) -> AsyncThrowingStream<String, Error> {
        if images.isEmpty {
            // 纯文本: 走 .text 分支, bypass chat template, 享受 Live persona/marker 修复
            let input = UserInput(prompt: .text(rawText))
            return generateStream(input: input, isMultimodal: false)
        } else {
            // 多模态: 走 .chat 分支, 复用已验证不崩的 vision 路径
            let chatImages: [UserInput.Image] = images.map { .ciImage($0) }
            let input = UserInput(chat: [.user(rawText, images: chatImages)])
            return generateStream(input: input, isMultimodal: true)
        }
    }


    private func currentMultimodalFallbackRecommendation() -> String {
        // 默认用户只装一个模型, 不建议"切换到另一个模型" (他可能根本没有)。
        // 给可执行的自救步骤: 关后台、减附件数量/尺寸。
        return "可尝试: 关闭后台应用释放内存; 减少附件数量; 或把图片缩小再试。"
    }


    private func generateStream(
        input: UserInput,
        isMultimodal: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: MLXError.modelNotLoaded)
                    return
                }

                // Admission gate: atomically check switch flag and register work
                let admitted: Bool = self.capabilitySwitchLock.withLock {
                    if self.capabilitySwitchPending { return false }
                    self.admittedWorkCount += 1
                    return true
                }
                guard admitted else {
                    print("[MLX] generateStream: capability switch pending, aborting")
                    continuation.finish(throwing: CancellationError())
                    return
                }
                // Decrement counter when generation Task exits (any path)
                defer {
                    self.capabilitySwitchLock.withLock { self.admittedWorkCount -= 1 }
                }

                do {
                    try await self.ensureAudioCapability(hasAudio: !input.audios.isEmpty)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                guard let container = modelContainer else {
                    continuation.finish(throwing: MLXError.modelNotLoaded)
                    return
                }

                // Free Metal buffers cached from previous inference before
                // allocating the new computation graph. Critical on low-headroom devices:
                // the follow-up prompt is longer than the first inference,
                // and without clearing, residual cache + new activations
                // exceed the 6GB jetsam limit on iPhone.
                //
                // NOTE: clearCache() frees Metal transient buffers but does NOT
                // touch KVCache tensors (those are MLXArray holdings on the
                // language model path, managed by `activeCache`). Prompt prefix
                // caching IS implemented — see MLXLocalLLMService+KVReuse.swift
                // and `kvReuseEnabled`.
                MLX.GPU.clearCache()

                // Multimodal invalidates reuse cache: image/audio tokens get
                // replaced with embeddings downstream, so the cached text-only
                // prefix is not semantically compatible with the new turn.
                if isMultimodal {
                    self.invalidateKVReuseCache()
                }

                let currentModel = self.loadedModel ?? self.selectedModel
                let profile = currentModel.runtimeProfile
                let headroom = MemoryStats.headroomMB

                let thinkingEnabled = RuntimeBudgets.isThinkingEnabled(input: input, profile: profile)
                let textBudget = RuntimeBudgets.text(profile: profile, headroom: headroom, enabled: !isMultimodal)
                let runtimeBudget: MultimodalBudget?
                do {
                    runtimeBudget = try RuntimeBudgets.multimodal(
                        profile: profile,
                        headroom: headroom,
                        hasImages: !input.images.isEmpty,
                        hasAudio: !input.audios.isEmpty,
                        modelDisplayName: currentModel.displayName,
                        fallbackRecommendation: "请关闭后台应用后重试，或减少附件数量。\(self.currentMultimodalFallbackRecommendation())"
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let thinkingBudget = RuntimeBudgets.thinking(profile: profile, headroom: headroom, enabled: thinkingEnabled)

                if let runtimeBudget {
                    print(
                        "[MEM] multimodal runtime budget — model=\(currentModel.displayName), "
                            + "headroom=\(headroom) MB, "
                            + "imageSoftTokenCap=\(runtimeBudget.imageSoftTokenCap.map(String.init) ?? "n/a"), "
                            + "outputCap=dynamic(headroomFloor=\(profile.headroomFloorMB)MB), "
                            + "audio=\(!input.audios.isEmpty ? 1 : 0)"
                    )
                }
                if let thinkingBudget {
                    print("[MEM] thinking runtime budget — model=\(currentModel.displayName), headroom=\(headroom) MB, maxOutputTokens=\(thinkingBudget.maxOutputTokens)")
                }
                if let textBudget {
                    print("[MEM] text runtime budget — model=\(currentModel.displayName), headroom=\(headroom) MB, maxOutputTokens=\(textBudget.maxOutputTokens)")
                }

                // TODO: 抽出 ModelAdapter 协议后移除 Gemma 专属耦合
                Gemma4Processor.setRuntimeImageSoftTokenCap(runtimeBudget?.imageSoftTokenCap)
                defer {
                    Gemma4Processor.setRuntimeImageSoftTokenCap(nil)
                }
                let effectiveMaxOutputTokens: Int = {
                    // 多模态不再有独立的静态 token 上限 — 完全依赖 headroomFloorMB 运行时检测。
                    // 只保留 thinking/text budget 的公式约束和 UI 滑块上限。
                    let thinkingCap = thinkingBudget?.maxOutputTokens ?? self.maxOutputTokens
                    let textCap = textBudget?.maxOutputTokens ?? self.maxOutputTokens
                    return min(self.maxOutputTokens, thinkingCap, textCap)
                }()
                let resolvedMaxOutputTokens = effectiveMaxOutputTokens

                self.isGenerating = true
                self.cancelled = false
                let genStart = CFAbsoluteTimeGetCurrent()
                var firstTokenTime: Double? = nil
                var tokenCount = 0
                var hitTokenCap = false
                var hitMemoryFloor = false
                let headroomFloor = profile.headroomFloorMB

                let (fp, _) = MemoryStats.footprintMB()
                let mlxMemory = Self.isSimulatorRuntime ? "simulator-skip" : "\(MLX.GPU.activeMemory / 1_048_576) MB"
                print("[MEM] generateStream start — footprint: \(Int(fp)) MB, MLX active: \(mlxMemory)")

                do {
                    try await self.ensureForegroundGPUExecution()
                    _ = try await container.perform { (context) -> Void in
                        try await self.ensureForegroundGPUExecution()
                        if isMultimodal {
                            print("[VLM] multimodal budget — maxOutputTokens=\(resolvedMaxOutputTokens)")
                        } else if thinkingEnabled {
                            print("[LLM] thinking budget — baseMaxOutputTokens=\(resolvedMaxOutputTokens)")
                        }
                        let preparedInput = try await context.processor.prepare(input: input)
                        let preparedSequenceLength = preparedInput.text.tokens.dim(1)
                        if isMultimodal {
                            print("[VLM] prepared sequence length=\(preparedSequenceLength)")
                        } else {
                            // 不再基于 prepared 长度二次扣减 output 上限。
                            // chunked prefill 让 prepared 长度对峰值内存几乎无影响,
                            // resolvedMaxOutputTokens 已由 textOutputBudget(headroom)
                            // 决定, 直接使用即可。
                            print(
                                "[LLM] prepared sequence length=\(preparedSequenceLength), "
                                    + "outputCap=\(resolvedMaxOutputTokens)"
                            )
                        }
                        try await self.ensureForegroundGPUExecution()

                        // prefillStepSize: chunked prefill window. 把长 prompt
                        // 切成 256 token / chunk 处理，每个 chunk 跑完调 eval(cache)
                        // 释放 compute graph，单 chunk transient 峰值控制在 ~400 MB
                        // 以内，避免长 prompt（800+ tokens）单次 forward 把 attention
                        // workspace 推过 iPhone 6.1 GB jetsam 上限。
                        //
                        // MLX 默认 512 是为桌面 Apple Silicon 调的；iPhone E4B
                        // (42 layers) 在 512 chunk 下 transient 峰值约 1.7 GB,
                        // 加上 4.6 GB 已驻留 weights+KV 会撞 jetsam。
                        // 这是框架层修复，与 prompt 内容、skill 数量、SKILL.md
                        // 格式完全无关。
                        // 2026-04-17: 256→128. E4B 42 层 chunk=256 真机 transient peak
                        // 超预期 (~600-800 MB vs 理论 400 MB), 在稳态 headroom ~1100 MB
                        // 下触发 jetsam. chunk=128 peak ~100-200 MB, 安全. 代价: prefill
                        // 吞吐降 ~10-15% (更多 eval 间隔). 无功能损失.
                        let generateParams = GenerateParameters(
                            maxTokens: resolvedMaxOutputTokens,
                            temperature: self.samplingTemperature,
                            topP: self.samplingTopP,
                            topK: self.samplingTopK,
                            prefillStepSize: 128
                        )

                        // Plan KV reuse (text-only). On multimodal / disabled /
                        // first call, plan falls through to a fresh cache and
                        // passes the full input — equivalent to the old path
                        // except the cache is now owned by the service and
                        // reused on the next call.
                        let reusePlan = self.planKVReuse(
                            preparedInput: preparedInput,
                            model: context.model,
                            parameters: generateParams,
                            isMultimodal: isMultimodal
                        )

                        let inputForGenerate: LMInput
                        let cacheForGenerate: [KVCache]?
                        if let plan = reusePlan {
                            inputForGenerate = plan.deltaInput
                            cacheForGenerate = plan.cache
                        } else {
                            inputForGenerate = preparedInput
                            cacheForGenerate = nil
                        }

                        // G2 (2026-04-17 实验, 已 revert): 试过 MinTokenEOSGuard 强制
                        // 至少生成 N token 防 R1 0-token 空回复. 数据揭示副作用更糟:
                        // 强制生成把 E2B 在 R2 follow-up 场景推到 "再次 emit tool_call"
                        // → 5 轮 repeat 重复创建日历事件 / 联系人, 数据风险远超 "(无回复)".
                        // 保留 MinTokenEOSGuard 实现以备将来精确路径使用 (例如只对 R1 启用,
                        // 但需要 framework 标识 R1/R2 上下文, 当前 generate 路径不感知).
                        let iterator = try TokenIterator(
                            input: inputForGenerate,
                            model: context.model,
                            cache: cacheForGenerate,
                            parameters: generateParams
                        )
                        _ = MLXLMCommon.generate(
                            input: inputForGenerate,
                            context: context,
                            iterator: iterator
                        ) { tokens in
                            if self.cancelled || !self.isForegroundGPUAllowed() {
                                return .stop
                            }

                            tokenCount = tokens.count
                            if firstTokenTime == nil {
                                firstTokenTime = (CFAbsoluteTimeGetCurrent() - genStart) * 1000
                            }

                            if let lastToken = tokens.last {
                                let text = context.tokenizer.decode(tokenIds: [lastToken])
                                continuation.yield(text)
                            }

                            if tokens.count >= resolvedMaxOutputTokens {
                                hitTokenCap = true
                                return .stop
                            }

                            // 实时内存地板检测: 每 32 token 查一次 headroom,
                            // 低于地板值立即停止, 防止 jetsam 闪崩。
                            // 每个 token 都查太贵 (task_info syscall), 32 是合理间隔。
                            if tokens.count % 32 == 0 {
                                let currentHeadroom = MemoryStats.headroomMB
                                if currentHeadroom < headroomFloor {
                                    print("[MEM] ⚠️ headroom \(currentHeadroom) MB < floor \(headroomFloor) MB at token \(tokens.count), stopping")
                                    hitMemoryFloor = true
                                    return .stop
                                }
                            }

                            return .more
                        }

                        // Commit or invalidate based on outcome.
                        if let plan = reusePlan {
                            if self.cancelled {
                                self.invalidateKVReuseCache()
                            } else {
                                self.commitKVReuse(plan: plan)
                            }
                        }
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - genStart
                    self.stats.ttftMs = firstTokenTime ?? 0
                    self.stats.chunksPerSec = elapsed > 0
                        ? Double(tokenCount) / elapsed : 0
                    self.stats.totalChunks = tokenCount

                    print(
                        "[MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s"
                    )
                    print(
                        "[MLX] TTFT: \(String(format: "%.0f", self.stats.ttftMs))ms, "
                            + "Speed: \(String(format: "%.1f", self.stats.chunksPerSec)) tok/s")

                    // 推理结束后立即释放 Metal activation 缓存，
                    // 确保下一轮有最大可用 headroom。
                    MLX.GPU.clearCache()
                    let (fpEnd, _) = MemoryStats.footprintMB()
                    print("[MEM] generateStream end  — footprint: \(Int(fpEnd)) MB, headroom: \(self.availableHeadroomMB) MB")
                    print("[MEM] MLX post-clear — \(Self.mlxMemoryDiagnostics())")

                    // If we hit the token cap mid-sentence, append a visible notice.
                    // This makes truncation explicit rather than silently dropping content.
                    if hitTokenCap || hitMemoryFloor {
                        let isChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
                        if hitMemoryFloor {
                            let msg = isChinese
                                ? "\n\n> ⚠️ 内存不足，已在 \(tokenCount) tokens 处停止生成。请关闭后台应用释放内存后重试。"
                                : "\n\n> ⚠️ Low memory, stopped at \(tokenCount) tokens. Close background apps and retry."
                            continuation.yield(msg)
                        } else {
                            let modeLabel = isChinese
                                ? (thinkingEnabled ? "思考" : "输出")
                                : (thinkingEnabled ? "Thinking" : "Output")
                            continuation.yield("\n\n> ⚠️ \(modeLabel)已达单次输出上限（\(resolvedMaxOutputTokens) tokens），内容可能不完整。")
                        }
                    }
                    continuation.finish()
                } catch {
                    self.invalidateKVReuseCache()
                    continuation.finish(throwing: error)
                }

                self.isGenerating = false
                self.currentGenerationTask = nil
            }

            currentGenerationTask = task
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                if self?.currentGenerationTask?.isCancelled == true {
                    self?.currentGenerationTask = nil
                }
            }
        }
    }

    public func cancel() {
        cancelled = true
        currentGenerationTask?.cancel()
        currentLoadTask?.cancel()
    }

    public func prepareForReload(
        cancelCurrentGeneration: Bool = true,
        cancelCurrentLoad: Bool = true
    ) async {
        cancelled = true
        if cancelCurrentGeneration {
            currentGenerationTask?.cancel()
        }
        if cancelCurrentLoad {
            currentLoadTask?.cancel()
        }

        while isGenerating || isLoading {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        unload(
            cancelCurrentGeneration: cancelCurrentGeneration,
            cancelCurrentLoad: cancelCurrentLoad
        )
        MLX.GPU.clearCache()
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    public func unload() {
        unload(cancelCurrentGeneration: true, cancelCurrentLoad: true)
    }

    public func unload(
        cancelCurrentGeneration: Bool = true,
        cancelCurrentLoad: Bool = true
    ) {
        if cancelCurrentGeneration {
            currentGenerationTask?.cancel()
        }
        if cancelCurrentLoad {
            currentLoadTask?.cancel()
        }
        modelContainer = nil
        isLoaded = false
        isLoading = false
        isGenerating = false
        loadedModel = nil
        cancelled = false
        liveModeSystemPrompt = nil
        stats = LLMStats()
        stats.backend = "mlx-gpu"
        invalidateKVReuseCache()
        MLX.GPU.clearCache()
        statusMessage = "模型已卸载"
        print("[MLX] Model unloaded")
    }
}
