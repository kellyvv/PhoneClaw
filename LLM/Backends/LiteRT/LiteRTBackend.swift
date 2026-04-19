import Foundation
import CoreImage
import LiteRTLMSwift

// MARK: - LiteRT Backend
//
// InferenceService conformer，内部持有 LiteRTLMEngine。
// CPU-only，无 GPU 分支。
//
// 推理路径:
//   - 纯文本: persistent session + 增量 delta → KV cache 复用
//   - 多模态 (图/音): Conversation API → multimodal()
//   - Raw text (Live): persistent session (同纯文本)
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
    var maxOutputTokens: Int = 4000

    // MARK: - Internal

    private var engine: LiteRTLMEngine?
    private var loadedModelID: String?
    private var cancelled = false

    // MARK: - KV Cache Session State
    /// persistent session 是否已打开
    private(set) var kvSessionActive = false
    /// 上一轮 model 输出 (用于拼 delta)。空 = 首轮。
    private(set) var lastModelOutput: String = ""

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
            statusMessage = "❌ \(error.localizedDescription)"
            PCLog.modelLoadFailed(modelID: modelID, reason: error.localizedDescription)
            throw error
        }
    }

    func unload() {
        engine?.closeSession()
        engine?.closeConversation()
        kvSessionActive = false
        lastModelOutput = ""
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
        engine.closeSession()
        kvSessionActive = false
        lastModelOutput = ""
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

    func cancel() {
        cancelled = true
        // Session API 没有显式 cancel — 通过 cancelled 标志在 stream 消费侧中断。
        // Conversation API 有 cancelConversation() — 未来补。
    }

    // MARK: - InferenceService: Text Generation

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        guard let engine, isLoaded else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        // Auto-reopen persistent session if it was closed (e.g. by Live mode)
        if !kvSessionActive {
            Task {
                await resetKVSession()
            }
            // First call after reopen — fall through to one-shot since session
            // may not be ready yet. Next call will use the session.
        }

        isGenerating = true
        cancelled = false
        let startTime = CFAbsoluteTimeGetCurrent()
        let useSession = kvSessionActive

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
                    let stream: AsyncThrowingStream<String, Error>
                    if useSession {
                        // Persistent session: prompt 是增量 delta，KV cache 复用
                        stream = engine.sessionGenerateStreaming(input: prompt)
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

                    // AudioInput → WAV Data
                    let audiosData = audios.map { $0.wavData }

                    let fullPrompt = systemPrompt.isEmpty
                        ? prompt
                        : systemPrompt + "\n" + prompt

                    #if DEBUG
                    // 诊断: 音频链路 — 证实传给引擎的 payload 是真实非空
                    for (i, audio) in audios.enumerated() {
                        let durationSec = Double(audio.samples.count) / max(audio.sampleRate, 1)
                        let n = Float(max(audio.samples.count, 1))
                        let rms = (audio.samples.reduce(Float(0)) { $0 + $1 * $1 } / n).squareRoot()
                        let peak = audio.samples.map { abs($0) }.max() ?? 0
                        let silent = peak < 0.01  // <0.01 归一化 ≈ 近乎静默
                        print("[LiteRT] audio[\(i)] samples=\(audio.samples.count) sr=\(Int(audio.sampleRate)) dur=\(String(format: "%.2f", durationSec))s wavBytes=\(audiosData[i].count) rms=\(String(format: "%.4f", rms)) peak=\(String(format: "%.4f", peak))\(silent ? " ⚠️SILENT" : "")")
                    }
                    print("[LiteRT] images=\(imagesData.count) audios=\(audios.count) promptChars=\(fullPrompt.count) prompt=\"\(fullPrompt.prefix(120))\"")
                    #endif

                    // Stream via Conversation API
                    for try await chunk in engine.multimodalStreaming(
                        audioData: audiosData,
                        imagesData: imagesData,
                        prompt: fullPrompt,
                        temperature: self.samplingTemperature,
                        maxTokens: self.maxOutputTokens
                    ) {
                        if self.cancelled {
                            continuation.finish()
                            break
                        }
                        continuation.yield(chunk)
                    }
                    if !self.cancelled {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }

                await MainActor.run { [weak self] in
                    self?.isGenerating = false
                }
            }
        }
    }

    // MARK: - InferenceService: Raw Text (Live)

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

// MARK: - Backend Error

enum ModelBackendError: LocalizedError {
    case modelNotLoaded
    case modelFileMissing(String)
    case memoryRisk(model: String, headroomMB: Int, recommendation: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "模型未加载，请先在配置页下载并加载模型。"
        case .modelFileMissing(let name):
            return "\(name) 模型文件不存在，请先在配置页下载。"
        case .memoryRisk(let model, let headroomMB, let recommendation):
            return "\(model) 当前剩余内存仅约 \(headroomMB) MB。\(recommendation)"
        }
    }
}
