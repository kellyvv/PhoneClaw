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

/// MLX GPU inference service for Gemma 4.
/// Forces MLX Metal GPU path — no CPU fallback.
@Observable
public class MLXLocalLLMService: LLMEngine {
    static let bundledModelDirectoryName = "gemma-4-e2b-it-4bit"
    static let bundledModelDisplayName = "Gemma 4 E2B"
    private static let multimodalMaxOutputTokens = 4000

    // MARK: - State

    public private(set) var isLoaded = false
    public private(set) var isGenerating = false
    public private(set) var stats = LLMStats()
    public var statusMessage = "等待加载模型..."
    public var modelDisplayName: String { Self.bundledModelDisplayName }

    // MARK: - Compatibility Settings

    public var useGPU = true
    public var samplingTopK: Int = 40
    public var samplingTopP: Float = 0.95
    public var samplingTemperature: Float = 1.0
    public var maxOutputTokens: Int = 4000

    private var modelContainer: ModelContainer?
    private var cancelled = false

    /// Local path to the model directory
    private let modelPath: URL

    // MARK: - Init

    public init(modelPath: URL) {
        self.modelPath = modelPath
        self.stats.backend = "mlx-gpu"
    }

    /// Convenience init with default model location
    public convenience init() {
        self.init(modelPath: Self.resolveDefaultModelPath())
    }

    private static func resolveDefaultModelPath() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let directBundleDir = resourceURL.appendingPathComponent(
                bundledModelDirectoryName,
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: directBundleDir.path) {
                return directBundleDir
            }

            let nestedBundleDir = resourceURL
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(bundledModelDirectoryName, isDirectory: true)
            if FileManager.default.fileExists(atPath: nestedBundleDir.path) {
                return nestedBundleDir
            }
        }

        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return documentsPath.appendingPathComponent("models/\(bundledModelDirectoryName)")
    }

    func loadModel() {
        Task {
            do {
                try await load()
                try await warmup()
            } catch {
                statusMessage = "❌ \(error.localizedDescription)"
                print("[MLX] Load failed: \(error)")
            }
        }
    }

    func generateStream(
        prompt: String,
        images: [CIImage] = [],
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""

            do {
                for try await token in generateStream(prompt: prompt, images: images) {
                    fullResponse += token
                    await MainActor.run {
                        onToken(token)
                    }
                }

                await MainActor.run {
                    onComplete(.success(fullResponse))
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
                    onComplete(.success(fullResponse))
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
        statusMessage = "正在初始化模型..."
        await Gemma4Registration.register()

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw MLXError.modelDirectoryMissing(modelPath.path)
        }

        statusMessage = "正在从磁盘加载模型..."
        let loadStart = CFAbsoluteTimeGetCurrent()

        // ── Memory diagnostics (read before load) ──────────────────────────────
        let physMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let (footprintBefore, limitBefore) = appMemoryFootprintMB()
        print("[MEM] Physical RAM: \(Int(physMB)) MB")
        print("[MEM] Before load — footprint: \(Int(footprintBefore)) MB, jetsam limit: \(Int(limitBefore)) MB")
        print("[MEM] MLX before — active: \(MLX.GPU.activeMemory / 1_048_576) MB, cache: \(MLX.GPU.cacheMemory / 1_048_576) MB")

        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelPath,
            using: MLXTokenizersLoader()
        )

        self.modelContainer = container
        self.isLoaded = true

        // ── Memory diagnostics (read after load) ───────────────────────────────
        let (footprintAfter, _) = appMemoryFootprintMB()
        print("[MEM] After load  — footprint: \(Int(footprintAfter)) MB")
        print("[MEM] MLX after   — active: \(MLX.GPU.activeMemory / 1_048_576) MB, cache: \(MLX.GPU.cacheMemory / 1_048_576) MB")

        let elapsed = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        stats.loadTimeMs = elapsed
        statusMessage = "模型已就绪 ✅ (\(Int(elapsed))ms)"

        print("[MLX] Model loaded in \(Int(elapsed))ms — backend: mlx-gpu")
    }

    /// Returns (footprint MB, jetsam limit MB) via task_info.
    private func appMemoryFootprintMB() -> (Double, Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let footprint = Double(info.phys_footprint) / 1_048_576
        let limit     = Double(info.limit_bytes_remaining) / 1_048_576 + footprint
        return (footprint, limit)
    }

    /// 当前可用内存 headroom（MB）。Agent 用来动态调整 history 深度。
    public var availableHeadroomMB: Int {
        let (footprint, limit) = appMemoryFootprintMB()
        return max(0, Int(limit - footprint))
    }

    /// 根据当前剩余内存推荐安全的 history 深度（消息条数）。
    /// E4B 每 ~200 token history ≈ ~200 MB 推理峰值，保守估算：
    ///   headroom > 1500 MB → suffix(4)  最近 2 轮
    ///   headroom > 900  MB → suffix(2)  最近 1 轮
    ///   headroom ≤ 900  MB → suffix(0)  无历史（临界状态）
    public var safeHistoryDepth: Int {
        let h = availableHeadroomMB
        switch h {
        case 1500...: return 4
        case  900..<1500: return 2
        default: return 0
        }
    }


    public func warmup() async throws {
        // Warmup skipped for E4B.
        //
        // E4B has 42 layers. Running MLXLMCommon.generate() for the first time
        // triggers Metal JIT shader compilation across all unique kernel variants
        // (attention, MLP, PLE, RoPE ...). This compilation adds a temporary
        // memory spike on top of the already-loaded 4.9 GB weights, which pushes
        // the process past the jetsam limit on iPhone 17 Pro Max.
        //
        // Skipping warmup means the first user inference compiles shaders lazily
        // (first response is ~2-3s slower) but avoids the OOM kill on startup.
        print("[MLX] Warmup skipped — shaders will compile on first inference")
        statusMessage = "模型已就绪 ✅"
    }

    public func generateStream(prompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        let input: UserInput
        if images.isEmpty {
            input = UserInput(prompt: prompt)
        } else {
            input = UserInput(
                chat: [
                    .user(
                        prompt,
                        images: images.map { .ciImage($0) }
                    )
                ]
            )
        }
        return generateStream(input: input, isMultimodal: !images.isEmpty)
    }

    public func generateStream(chat: [Chat.Message]) -> AsyncThrowingStream<String, Error> {
        let hasImages = chat.contains { !$0.images.isEmpty }
        let input = UserInput(chat: chat)
        return generateStream(input: input, isMultimodal: hasImages)
    }

    private func ensureForegroundGPUExecution() async throws {
        #if canImport(UIKit)
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else {
            throw MLXError.gpuExecutionRequiresForeground
        }
        #endif
    }

    private func generateStream(
        input: UserInput,
        isMultimodal: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let container = modelContainer else {
                    continuation.finish(throwing: MLXError.modelNotLoaded)
                    return
                }

                // Free Metal buffers cached from previous inference before
                // allocating the new computation graph. Critical for E4B:
                // the follow-up prompt is longer than the first inference,
                // and without clearing, residual cache + new activations
                // exceed the 6GB jetsam limit on iPhone.
                MLX.GPU.clearCache()

                self.isGenerating = true
                self.cancelled = false
                let genStart = CFAbsoluteTimeGetCurrent()
                var firstTokenTime: Double? = nil
                var tokenCount = 0

                let (fp, _) = appMemoryFootprintMB()
                print("[MEM] generateStream start — footprint: \(Int(fp)) MB, MLX active: \(MLX.GPU.activeMemory / 1_048_576) MB")

                do {
                    try await self.ensureForegroundGPUExecution()
                    _ = try await container.perform { context in
                        try await self.ensureForegroundGPUExecution()
                        let effectiveMaxOutputTokens =
                            isMultimodal ? min(maxOutputTokens, Self.multimodalMaxOutputTokens) : maxOutputTokens
                        if isMultimodal {
                            print("[VLM] multimodal budget — maxOutputTokens=\(effectiveMaxOutputTokens)")
                        }
                        let input = try await context.processor.prepare(input: input)
                        if isMultimodal {
                            print("[VLM] prepared sequence length=\(input.text.tokens.dim(1))")
                        }
                        try await self.ensureForegroundGPUExecution()

                        return try MLXLMCommon.generate(
                            input: input,
                            parameters: .init(
                                maxTokens: effectiveMaxOutputTokens,
                                temperature: samplingTemperature,
                                topP: samplingTopP,
                                topK: samplingTopK
                            ),
                            context: context
                        ) { tokens in
                            if self.cancelled {
                                return .stop
                            }

                            tokenCount = tokens.count
                            if firstTokenTime == nil {
                                firstTokenTime = (CFAbsoluteTimeGetCurrent() - genStart) * 1000
                            }

                            // Stream the latest token
                            if let lastToken = tokens.last {
                                let text = context.tokenizer.decode(tokenIds: [lastToken])
                                continuation.yield(text)
                            }

                            // Multimodal path uses a tighter generation budget on iPhone.
                            return tokens.count >= effectiveMaxOutputTokens ? .stop : .more
                        }
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - genStart
                    self.stats.ttftMs = firstTokenTime ?? 0
                    self.stats.tokensPerSec = elapsed > 0
                        ? Double(tokenCount) / elapsed : 0
                    self.stats.totalTokens = tokenCount

                    print(
                        "[MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s"
                    )
                    print(
                        "[MLX] TTFT: \(String(format: "%.0f", self.stats.ttftMs))ms, "
                            + "Speed: \(String(format: "%.1f", self.stats.tokensPerSec)) tok/s")

                    // 推理结束后立即释放 Metal activation 缓存，
                    // 确保下一轮有最大可用 headroom。
                    MLX.GPU.clearCache()
                    let (fpEnd, _) = appMemoryFootprintMB()
                    print("[MEM] generateStream end  — footprint: \(Int(fpEnd)) MB, headroom: \(self.availableHeadroomMB) MB")

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.isGenerating = false
            }
        }
    }

    public func cancel() {
        cancelled = true
    }

    public func unload() {
        modelContainer = nil
        isLoaded = false
        isGenerating = false
        stats = LLMStats()
        stats.backend = "mlx-gpu"
        statusMessage = "模型已卸载"
        print("[MLX] Model unloaded")
    }
}

// MARK: - Errors

enum MLXError: LocalizedError {
    case modelNotLoaded
    case modelDirectoryMissing(String)
    case gpuExecutionRequiresForeground

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "MLX model not loaded. Call load() first."
        case .modelDirectoryMissing(let path):
            return "MLX 模型目录不存在: \(path)"
        case .gpuExecutionRequiresForeground:
            return "应用进入后台时，iPhone 不允许继续提交 GPU 推理任务。"
        }
    }
}
