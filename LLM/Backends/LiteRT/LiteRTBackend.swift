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
    var statusMessage = "等待加载模型..."
    private(set) var stats = InferenceStats()

    // MARK: - Sampling Config

    var samplingTopK: Int = 40
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 1.0
    var maxOutputTokens: Int = 8192

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
        self.stats.backend = "litert-cpu"
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
        guard !isLoading else { return }

        // 已加载同一模型 — no-op
        if isLoaded, loadedModelID == modelID { return }

        // 如果加载了不同模型，先卸载
        if isLoaded { unload() }

        guard let modelPath = modelPathResolver(modelID) else {
            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            let name = descriptor?.displayName ?? modelID
            statusMessage = "请先在配置中下载 \(name) 模型"
            throw ModelBackendError.modelFileMissing(name)
        }

        isLoading = true
        statusMessage = "正在加载模型..."
        cancelled = false

        let loadStart = CFAbsoluteTimeGetCurrent()

        do {
            let newEngine = LiteRTLMEngine(modelPath: modelPath, backend: "cpu")
            try await newEngine.load()

            self.engine = newEngine
            self.loadedModelID = modelID
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
        print("[LiteRT] Persistent session opened for KV cache reuse")

            let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
            self.stats.loadTimeMs = elapsed

            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            statusMessage = "已加载 \(descriptor?.displayName ?? modelID)"
            PCLog.modelLoaded(modelID: modelID, loadMs: elapsed)
            onModelLoaded?(modelID)
        } catch {
            isLoading = false
            isLoaded = false

            // 模型加载失败 → 文件可能损坏，自动清理并恢复下载按钮
            let descriptor = ModelDescriptor.allModels.first { $0.id == modelID }
            let displayName = descriptor?.displayName ?? modelID
            print("[LiteRT] ❌ 加载 \(displayName) 失败: \(error.localizedDescription)")
            print("[LiteRT] 自动清理可能损坏的模型文件...")
            try? FileManager.default.removeItem(at: modelPath)
            print("[LiteRT] 已删除: \(modelPath.lastPathComponent)")
            // 通知外部 store 刷新状态 (下次 refreshInstallStates 时会标记为 notInstalled)
            NotificationCenter.default.post(
                name: Notification.Name("LiteRTModelCorrupt"),
                object: nil,
                userInfo: ["modelID": modelID]
            )

            statusMessage = "❌ \(displayName) 文件损坏，请重新下载"
            PCLog.modelLoadFailed(modelID: modelID, reason: error.localizedDescription)
            throw error
        }
    }

    func unload() {
        engine?.closeSession()
        engine?.closeConversation()
        kvSessionActive = false
        liveModeActive = false
        lastModelOutput = ""
        pendingTextSessionRestore = false
        sessionGroupManagedMultimodal = false
        Task { @MainActor in
            engine?.unload()
        }
        engine = nil
        loadedModelID = nil
        isLoaded = false
        isGenerating = false
        statusMessage = "等待加载模型..."
        onModelUnloaded?()
        PCLog.modelUnloaded()
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
                        if self.cancelled {
                            continuation.finish()
                            break
                        }
                        tokenCount += 1
                        if firstTokenTime == nil {
                            firstTokenTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        }
                        modelOutput += token
                        continuation.yield(token)
                    }
                    if !self.cancelled {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                // Cache model output for next turn's delta construction
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
            }
        }
    }

    // MARK: - InferenceService: Multimodal Generation

    func generateMultimodal(
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
                        if !self.cancelled {
                            if !text.isEmpty {
                                continuation.yield(text)
                            }
                            continuation.finish()
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
                            if self.cancelled {
                                continuation.finish()
                                break
                            }
                            continuation.yield(chunk)
                        }
                        if !self.cancelled {
                            continuation.finish()
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                await MainActor.run { [weak self] in
                    self?.isGenerating = false
                    self?.sessionGroupManagedMultimodal = false
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
                        if self.cancelled {
                            continuation.finish()
                            break
                        }
                        tokenCount += 1
                        if firstTokenTime == nil {
                            firstTokenTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        }
                        continuation.yield(token)
                    }
                    if !self.cancelled {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

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
