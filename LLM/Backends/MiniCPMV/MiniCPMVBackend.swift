import Foundation
import Combine
import CoreImage
import MTMDEngine

// MARK: - MiniCPM-V Backend
//
// InferenceService 实现，封装 OpenBMB 的 mtmd-ios C API (llama.cpp 推 LLM,
// CoreML 推 SigLIP2 vision tower 走 ANE)。
//
// 跟 LiteRTBackend 的差异:
//   - 模型由 3 个文件组成: LLM .gguf + mmproj .gguf + 可选 CoreML .mlmodelc
//     bundleResolver 把这 3 个路径打包返回, 而不是 LiteRT 的单文件 path。
//   - MTMDWrapper 是 @MainActor + ObservableObject (OpenBMB demo 风格),
//     这里通过 Task { @MainActor in ... } 桥接。
//   - 没有 KV 持久化 session 的概念 — MTMD 内部维护对话状态, 切换/清理
//     走 reset()。InferenceService 协议里的 KV session 方法走默认 no-op。
//   - 没有 MTP speculative decoding — setEnableSpeculativeDecoding 为 no-op。
//
// 当前状态 (Phase 1.2):
//   ✅ load / unload
//   ✅ generate(prompt:) 纯文本路径 (通过 Combine→AsyncStream 桥接)
//   ⏳ generateMultimodal — Phase 1.2.2
//   ⏳ generateRaw with images — Phase 1.2.2
//   ⏳ generateLive — Phase 1.2.3
//   ⏳ enterLiveMode / exitLiveMode — Phase 1.2.3
//
// 未对接到 AgentEngine — 路由层 (后端选择) 走 Phase 1.3。

// MARK: - Path Bundle

/// MiniCPM-V 模型的 3 个文件路径打包。
public struct MTMDPathBundle: Sendable {
    /// LLM 主权重 .gguf (e.g. MiniCPM-V-4_6-Q4_K_M.gguf)
    public let modelPath: URL
    /// 多模态投影 .gguf (e.g. MiniCPM-V-4_6-mmproj-f16.gguf)
    public let mmprojPath: URL
    /// CoreML/ANE 加速的 vision tower .mlmodelc 目录 (可选)。
    /// nil 时 vision encoder fallback 到 llama.cpp GPU/CPU 路径 (会慢很多,
    /// 视频场景几乎不可用)。
    public let coremlPath: URL?

    public init(modelPath: URL, mmprojPath: URL, coremlPath: URL? = nil) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.coremlPath = coremlPath
    }
}

// MARK: - Backend

@Observable
final class MiniCPMVBackend: InferenceService {

    // MARK: InferenceService State

    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var statusMessage = tr("等待加载模型...", "Waiting to load model...")
    private(set) var stats = InferenceStats()

    // MARK: Sampling (per InferenceService)
    //
    // MiniCPM-V 默认 temperature 0.7 (OpenBMB demo 设定, 对齐模型
    // generation_config.json), top_k/top_p 在 mtmd-ios.cpp 内部统一禁用,
    // 走纯温度采样。这里保留协议要求的 4 个字段, top_k/top_p 实际不参与
    // 采样, 留着是为了 UI 滑条共用代码路径。

    var samplingTopK = 40
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 0.7
    var maxOutputTokens = 1024

    // MARK: Private

    @ObservationIgnored private let bundleResolver: (String) -> MTMDPathBundle?

    /// MTMDWrapper 在 @MainActor 上构造, 首次 load 时懒加载。
    @ObservationIgnored private var wrapper: MTMDWrapper?

    @ObservationIgnored private var loadedModelID: String?
    @ObservationIgnored private var preferGPU: Bool = true

    /// KV reuse 状态: 当前 wrapper KV cache 里已 prefill 过的 (role, content) 序列。
    /// 下次 generate 比对 newSegments 与此列表的最长前缀, 只 prefill 增量部分,
    /// 避免每轮重跑 system prompt + 全部历史。
    ///
    /// 何时更新:
    ///   - generate 成功完成 (isEnd): 追加 (assistant, 实际生成内容)。下一轮
    ///     PromptBuilder 会把同一条 assistant message 放进 newSegments, 前缀
    ///     匹配上 → 只 prefill 新 user message。
    ///   - generate 失败 / 中途取消: 不动, 但下一轮如果发现 newSegments 不能
    ///     完全延续 prefilledSegments, 会触发 cleanKVCache + 全量重 prefill。
    ///
    /// 何时清空 (cleanKVCache + 列表归零):
    ///   - 调用 load 切换到不同模型
    ///   - 调用 unload
    ///   - newSegments 跟 prefilledSegments 出现 divergence (system 变了 /
    ///     skill 加载了 / 历史被截断了 — 任何前缀不再 match 的情况)
    @ObservationIgnored private var prefilledSegments: [PromptSegment] = []

    // MARK: Init

    init(bundleResolver: @escaping (String) -> MTMDPathBundle?) {
        self.bundleResolver = bundleResolver
    }

    // MARK: - Lifecycle

    func load(modelID: String) async throws {
        if loadedModelID == modelID, isLoaded { return }
        if isLoading { return }

        guard let bundle = bundleResolver(modelID) else {
            throw ModelBackendError.modelFileMissing(modelID)
        }

        // 文件存在性预检
        guard FileManager.default.fileExists(atPath: bundle.modelPath.path) else {
            throw ModelBackendError.modelFileMissing(bundle.modelPath.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: bundle.mmprojPath.path) else {
            throw ModelBackendError.modelFileMissing(bundle.mmprojPath.lastPathComponent)
        }
        // coremlPath 是可选, 不存在不报错 — fallback 到 CPU/GPU vision

        await MainActor.run {
            self.isLoading = true
            self.statusMessage = tr("加载 MiniCPM-V...", "Loading MiniCPM-V...")
        }

        // 如果之前有其它模型, 先清掉
        if let old = wrapper {
            await old.cleanup()
        }
        // 切模型后 KV cache 状态完全失效, 重置 tracker
        prefilledSegments = []

        // MTMDWrapper 是 @MainActor 类, 构造和方法调用都需要 main 上下文。
        // 这里通过 await MainActor.run 完成跨 actor 桥接。
        let w: MTMDWrapper = await MainActor.run {
            let new = MTMDWrapper()
            self.wrapper = new
            return new
        }

        // 决定 n_ctx — v4.6 视频路径需要 8192, 其它默认 4096。
        // Phase 1.2 文本场景统一 4096, 视频路径在 Phase 1.2.3 引入。
        let nCtx = 4096

        let params = MTMDParams(
            modelPath: bundle.modelPath.path,
            mmprojPath: bundle.mmprojPath.path,
            coremlPath: bundle.coremlPath?.path ?? "",
            nPredict: maxOutputTokens,
            nCtx: nCtx,
            nThreads: 4,
            temperature: samplingTemperature,
            useGPU: preferGPU,
            mmprojUseGPU: preferGPU,
            warmup: true,
            imageMaxSliceNums: 9
        )

        do {
            try await w.initialize(with: params)
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.statusMessage = tr("加载失败: \(error.localizedDescription)",
                                        "Load failed: \(error.localizedDescription)")
            }
            throw error
        }

        await MainActor.run {
            self.loadedModelID = modelID
            self.isLoaded = true
            self.isLoading = false
            // backend 标签用于 [Perf] 行 + UI tooltip; "llama.cpp-metal" 对齐
            // LiteRTBackend 的 "litert-gpu" / "litert-cpu" 命名约定 (后端_设备).
            // CoreML/ANE 只在 vision encode 时介入, 纯文本路径全在 llama.cpp,
            // 所以这里跟 vision 状态无关.
            self.stats.backend = self.preferGPU ? "llama.cpp-metal" : "llama.cpp-cpu"
            self.statusMessage = tr("MiniCPM-V 已就绪",
                                    "MiniCPM-V ready")
        }
    }

    func unload() {
        // 协议是 sync, 实际清理需要跑 @MainActor 上的 wrapper.cleanup。
        // 同步状态先翻掉, 后台异步执行 wrapper 清理 — 跟 LiteRTBackend 同款套路。
        isLoaded = false
        loadedModelID = nil
        statusMessage = tr("已卸载", "Unloaded")
        prefilledSegments = []  // KV reuse 跟踪状态归零

        Task { @MainActor [weak self] in
            await self?.wrapper?.cleanup()
            self?.wrapper = nil
        }
    }

    func cancel() {
        isGenerating = false
        Task { @MainActor [weak self] in
            self?.wrapper?.stopGeneration()
        }
    }

    // MARK: - Live Mode (stub — Phase 1.2.3)

    func enterLiveMode(systemPrompt: String?) async throws {
        // TODO Phase 1.2.3: 持久 conversation + 多模态帧流
        // 暂时只把 system prompt 注入 wrapper, 等于普通 chat 起一个 system turn。
        guard let w = wrapper else {
            throw ModelBackendError.modelNotLoaded
        }
        if let sp = systemPrompt, !sp.isEmpty {
            try await w.addTextInBackground(sp, role: "system")
        }
    }

    func exitLiveMode() async {
        // TODO Phase 1.2.3
        if let w = wrapper {
            await w.reset()
        }
    }

    // MARK: - Gemma → Qwen prompt translation
    //
    // InferenceService 协议规定调用方 (AgentEngine / PromptBuilder) 构造的
    // prompt 走 Gemma 4 turn marker 格式:
    //   <|turn>system\n<sys><turn|>\n<|turn>user\n<u1><turn|>\n
    //   <|turn>model\n<a1><turn|>\n<|turn>user\n<u2><turn|>\n<|turn>model\n
    //
    // MiniCPM-V (Qwen3.5 backbone + OpenBMB mtmd-ios) 用 Qwen chat template:
    //   <|im_start|>system\n<sys><|im_end|>
    //   <|im_start|>user\n<u1><|im_end|>
    //   <|im_start|>assistant\n<a1><|im_end|>
    //   ...
    //
    // 把 Gemma 整段塞给 mtmd_ios_prefill_text(role="user") 会:
    //   1. 模型看到嵌套乱码 marker (Qwen 把整块 Gemma 包裹在 user 里),
    //      生成乱跳 / 输出残破 turn marker 不停。
    //   2. mtmd_ios 自动在最前面塞默认 "You are a helpful assistant" system,
    //      把 PhoneClaw 真正的 system prompt 顶下去, agent 行为完全失效。
    //
    // 这里做转换: 解析 Gemma marker 把 prompt 拆成 (role, content) 数组,
    // 按顺序逐段 prefill_text 喂给 mtmd_ios, 让它走原生 Qwen 模板。
    // 角色映射: gemma "system" → qwen "system",
    //          gemma "user"   → qwen "user",
    //          gemma "model"  → qwen "assistant" (这是关键 — Qwen 不认 model 角色)。
    //
    // 末尾的 "<|turn>model\n" 开口 turn (没闭合 <turn|>) 是 "请现在生成助手回复"
    // 的提示, mtmd_ios 在 startGeneration 时会自动添加 <|im_start|>assistant\n,
    // 我们丢弃它。

    /// Gemma 4 turn marker 解析的输出。`role` 已映射到 Qwen 词汇。
    /// Equatable 让 KV reuse 比较 prefilled vs new 时能直接 ==。
    private struct PromptSegment: Equatable {
        let role: String       // "system" | "user" | "assistant" (或 "__cancelled__" / "__error__" 哨兵)
        let content: String
    }

    /// 计算 prefilled 跟 new 的最长公共前缀长度 (按 role + content 完全匹配)。
    /// 用于决定 KV reuse 时只 prefill 哪些尾部 segments。
    private static func commonPrefixLength(
        prefilled: [PromptSegment],
        new: [PromptSegment]
    ) -> Int {
        var i = 0
        let limit = min(prefilled.count, new.count)
        while i < limit && prefilled[i] == new[i] {
            i += 1
        }
        return i
    }

    /// 把 Gemma 4 风格 prompt 解析成 (role, content) 段, 丢弃末尾 open turn。
    /// 找不到任何 Gemma marker 的话, 整段当 user role 兜底。
    private static func translateGemmaToQwen(_ prompt: String) -> [PromptSegment] {
        var segments: [PromptSegment] = []

        // 匹配完整闭合的 turn: <|turn>ROLE\nCONTENT<turn|>
        // \w+ 抓 role, [\s\S]*? 非贪婪抓 content (要跨行)。
        let pattern = #"<\|turn>(\w+)\n([\s\S]*?)<turn\|>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [PromptSegment(role: "user", content: prompt)]
        }

        let nsPrompt = prompt as NSString
        let matches = regex.matches(in: prompt, range: NSRange(location: 0, length: nsPrompt.length))

        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let gemmaRole = nsPrompt.substring(with: match.range(at: 1))
            let content = nsPrompt.substring(with: match.range(at: 2))
            let qwenRole: String
            switch gemmaRole {
            case "model":  qwenRole = "assistant"
            case "system": qwenRole = "system"
            case "user":   qwenRole = "user"
            default:       qwenRole = "user"  // 未知角色降级为 user
            }
            // 跳过空内容 (有时 Gemma 模板的 system block 会是占位空段)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            segments.append(PromptSegment(role: qwenRole, content: content))
        }

        // 没匹配到任何 marker → prompt 是裸文本, 当 user 处理
        if segments.isEmpty {
            return [PromptSegment(role: "user", content: prompt)]
        }
        return segments
    }

    // MARK: - Text Generation

    /// 纯文本推理: 通过 Combine 订阅 wrapper.$currentToken 把 publisher 流
    /// 转换为 InferenceService 协议要求的 AsyncThrowingStream<String, Error>。
    ///
    /// prompt 走 Gemma 4 turn marker 格式 (PromptBuilder 的输出), 这里通过
    /// `translateGemmaToQwen` 拆解成 (role, content) 段, 逐段 prefill_text
    /// 喂给 mtmd_ios, 让 Qwen3.5 chat template 在底层正确包装。详见上文。
    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard self.isLoaded, let w = self.wrapper else {
                    continuation.finish(throwing: ModelBackendError.modelNotLoaded)
                    return
                }

                self.isGenerating = true

                // Combine 订阅: 每次 currentToken 变化 yield content 给 stream,
                // is_end 时 finish。同时累积 emittedTokens 用于 KV reuse 跟踪。
                //
                // 用 final class 包一层 (Swift 6 strict concurrency 不接受
                // 跨并发边界捕获 `var cancellable` / `var emittedTokens`, 见 SE-0420)。
                //
                // 性能埋点字段 (ttftMs / chunkCount): 对齐 LiteRTBackend, sink 里
                // 每来一个非空 chunk +1, 首个非空 chunk 记 TTFT。isEnd 时算
                // chunks_per_sec 写回 self.stats + 走 PCLog.perf。
                final class StreamState: @unchecked Sendable {
                    var c: AnyCancellable?
                    var emittedTokens: String = ""
                    var completedSuccessfully: Bool = false
                    var ttftMs: Double?
                    var chunkCount: Int = 0
                }
                let state = StreamState()

                // Snapshot 新 segments + 决定增量 prefill 范围, 用于成功后更新 tracker。
                let newSegments = Self.translateGemmaToQwen(prompt)

                // 计时起点: prefill 开始的瞬间。TTFT = 这个时刻到首个非空 chunk
                // 的间隔, 包括 prefill 延迟 + 首 token 解码, 跟 LiteRT 对齐。
                let startTime = CFAbsoluteTimeGetCurrent()

                state.c = w.$currentToken
                    .dropFirst()  // 忽略初始 .empty
                    .sink { token in
                        if !token.content.isEmpty {
                            if state.ttftMs == nil {
                                state.ttftMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                            }
                            state.chunkCount += 1
                            state.emittedTokens += token.content
                            continuation.yield(token.content)
                        }
                        if token.isEnd {
                            state.completedSuccessfully = true
                            continuation.finish()
                            state.c?.cancel()
                            // 算完整 perf 行所需的 elapsed (相对 startTime, 不是相对首 token)
                            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                            let chunksPerSec: Double = (elapsed > 0 && state.chunkCount > 0)
                                ? Double(state.chunkCount) / elapsed
                                : 0
                            let finalTtftMs = state.ttftMs ?? 0
                            let finalChunkCount = state.chunkCount
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.isGenerating = false
                                // 把 stats 三件套写回 (loadTimeMs / backend / peakMemoryMB
                                // 由 load() 时填的或默认值, 这里只动 ttft / chunks / rate)
                                self.stats.ttftMs = finalTtftMs
                                self.stats.totalChunks = finalChunkCount
                                self.stats.chunksPerSec = chunksPerSec
                                PCLog.perf(
                                    ttftMs: Int(finalTtftMs),
                                    chunks: finalChunkCount,
                                    chunksPerSec: chunksPerSec,
                                    headroomMB: MemoryStats.headroomMB
                                )
                                // KV cache 里现在有: prefilledSegments (前缀) + 本轮新增 segments + 生成的 assistant 内容。
                                // 把这三段拼起来作为下次 generate 的"已 prefill"基线。
                                self.prefilledSegments = newSegments + [
                                    PromptSegment(role: "assistant", content: state.emittedTokens)
                                ]
                            }
                        }
                    }

                continuation.onTermination = { _ in
                    state.c?.cancel()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // 自然完成时 sink 已经把 isEnd 处理完了, 这里不要再调
                        // stopGeneration —— 它会无谓地打 "MTMDWrapper: 生成已停止"
                        // 一行噪音 (因为 wrapper 内部把 completed → completed 当
                        // 状态变更打印). 只有真的被外部 cancel/throw 时才需要停。
                        if !state.completedSuccessfully {
                            self.wrapper?.stopGeneration()
                            self.isGenerating = false
                            // 中途取消: 当前 KV cache 状态半成品 — 下次 generate
                            // 会检测到 newSegments != prefilledSegments + assistant
                            // → 触发 cleanKVCache + 全量重 prefill, 自动恢复。
                            // 标记为 stale: 下次必走 full re-prefill 路径 (前缀肯定不匹配)
                            self.prefilledSegments = [
                                PromptSegment(role: "__cancelled__", content: "")
                            ]
                        }
                    }
                }

                // 增量 prefill: 跟 prefilledSegments 比对最长公共前缀,
                // 只对新增 segments 调 addTextInBackground。
                do {
                    let commonPrefixLen = Self.commonPrefixLength(
                        prefilled: self.prefilledSegments,
                        new: newSegments
                    )
                    let needsReset = commonPrefixLen < self.prefilledSegments.count
                    let tailStart = needsReset ? 0 : commonPrefixLen

                    if needsReset {
                        // 前缀分叉 (system 变了 / skill 加载 / 历史截断 / 上轮 cancel).
                        // 清 KV cache (保留模型权重) + 从头 prefill。
                        w.cleanKVCache()
                        self.prefilledSegments = []
                    }

                    for seg in newSegments[tailStart...] {
                        try await w.addTextInBackground(seg.content, role: seg.role)
                    }

                    try await w.startGeneration()
                } catch {
                    continuation.finish(throwing: error)
                    state.c?.cancel()
                    self.isGenerating = false
                    // 出错后 KV 状态未知, 强制下次重置
                    self.prefilledSegments = [
                        PromptSegment(role: "__error__", content: "")
                    ]
                }
            }
        }
    }

    // MARK: - Multimodal Generation (stub — Phase 1.2.2)

    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        // TODO Phase 1.2.2:
        //   1. CIImage → 临时 PNG 落盘 (mtmd_ios_prefill_image 吃 path, 不吃 buffer)
        //   2. systemPrompt → wrapper.addTextInBackground(role: "system")
        //   3. 每张图 → wrapper.addImageInBackground(tmpPath)
        //   4. prompt → wrapper.addTextInBackground(role: "user")
        //   5. wrapper.startGeneration() + 同上文 Combine 桥接
        //   audios 暂不支持 (MiniCPM-V 4.6 无 audio, 4.5/o 系列才有)
        AsyncThrowingStream { $0.finish(throwing: MiniCPMVBackendError.notImplemented("multimodal")) }
    }

    func generateRaw(
        text: String,
        images: [CIImage]
    ) -> AsyncThrowingStream<String, Error> {
        // 没图就走文本路径, 有图回退到 multimodal (Phase 1.2.2 之后)。
        if images.isEmpty {
            return generate(prompt: text)
        }
        return AsyncThrowingStream { $0.finish(throwing: MiniCPMVBackendError.notImplemented("raw+images")) }
    }

    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        // TODO Phase 1.2.3
        AsyncThrowingStream { $0.finish(throwing: MiniCPMVBackendError.notImplemented("live")) }
    }

    // MARK: - Backend-specific overrides

    func setPreferredBackend(_ backend: String) {
        // MiniCPM-V 通过 MTMDParams.useGPU + mmprojUseGPU 控制 GPU/CPU,
        // 这里记下偏好, 下次 load 时生效。已加载的 engine 不会自动重启。
        preferGPU = (backend.lowercased() == "gpu")
    }

    func setEnableSpeculativeDecoding(_ enabled: Bool) {
        // MiniCPM-V 没有 MTP speculative decoding, 此开关无意义, no-op。
        // 协议里有这个方法是 LiteRT 专有的, 默认实现就是 no-op, 我们这里
        // 显式覆盖一个空 body 让意图清晰。
        _ = enabled
    }

    // KV session 相关 (revertToTextOnly, resetKVSession, prepareForSessionGroupTransition,
    // lastKVPrefillTokens, kvSessionActive, sessionHasContext) 全部走协议默认实现
    // (no-op / 0 / false), MiniCPM-V 没有 LiteRT 那种 persistent KV session 概念。
}

// MARK: - Errors

public enum MiniCPMVBackendError: LocalizedError {
    case notImplemented(String)
    case bundleResolutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what):
            return tr(
                "MiniCPM-V 后端尚未实现: \(what)",
                "MiniCPM-V backend not implemented yet: \(what)"
            )
        case .bundleResolutionFailed(let modelID):
            return tr(
                "找不到 MiniCPM-V 模型 \(modelID) 的文件路径",
                "Cannot resolve MiniCPM-V model \(modelID) file paths"
            )
        }
    }
}
