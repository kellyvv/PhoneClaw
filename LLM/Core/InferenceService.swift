import Foundation
import CoreImage

private let callbackFlushInterval: CFTimeInterval = 0.05
private let callbackBatchSizeThreshold = 160
private let callbackImmediateFlushCharacters: Set<Character> = [
    "\n", ".", "!", "?", "。", "！", "？"
]
private let callbackControlMarkers = [
    "<tool_call>",
    "</tool_call>",
    "<function_call>",
    "</function_call>",
    "[[PHONECLAW_THINK]]",
    "[[/PHONECLAW_THINK]]"
]

// MARK: - Inference Service Protocol
//
// Agent / Live 调用 LLM 的唯一入口。
//
// 产品层不知道也不关心底层是 MLX、LiteRT、CoreML 还是远程 API。
// 它只调这个协议上的方法，拿到 token stream。
//
// 设计约束:
//   - 不 import 任何推理框架
//   - 参数全用 LLMTypes.swift 里的值类型
//   - @Observable 需要 class，所以用 AnyObject 约束
//   - 所有 generate 方法返回 AsyncThrowingStream<String, Error>

public protocol InferenceService: AnyObject {

    // MARK: - Lifecycle

    /// 加载指定模型。幂等 — 已加载同一模型时 no-op。
    func load(modelID: String) async throws

    /// 卸载当前模型，释放内存。
    func unload()

    /// 取消当前正在进行的推理。
    func cancel()

    /// 进入 Live 模式，切换到 Live 专用的持久化会话/对话形态。
    /// `systemPrompt` 为 Live conversation 的一次性 system 指令。
    func enterLiveMode(systemPrompt: String?) async throws

    /// 退出 Live 模式，恢复普通聊天使用的会话形态。
    func exitLiveMode() async

    // MARK: - Text Generation

    /// 文本推理。`prompt` 已包含完整 turn marker 模板。
    ///
    /// 调用方 (AgentEngine / PromptBuilder) 负责构造 Gemma 4 的
    /// `<|turn>system\n...<turn|>\n<|turn>user\n...<turn|>\n<|turn>model\n` 格式。
    /// 后端按原样编码 + 生成。
    func generate(prompt: String) -> AsyncThrowingStream<String, Error>

    // MARK: - Multimodal Generation

    /// 多模态推理。传入图片/音频 + 文本 prompt + 可选 system prompt。
    ///
    /// 后端内部决定使用 Session API 还是 Conversation API。
    /// - LiteRT: 有图/音频时走 Conversation API，纯文本走 Session API
    /// - MLX: 走 VLM pipeline
    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error>

    // MARK: - Raw Text

    /// Raw text prompt — 调用方手写完整模板 (含 turn markers) 时使用，
    /// 后端按原样编码，bypass chat template / Conversation API。
    /// 有 image 时回退到多模态路径。
    func generateRaw(
        text: String,
        images: [CIImage]
    ) -> AsyncThrowingStream<String, Error>

    // MARK: - Live Generation

    /// Live 模式专用生成入口。
    ///
    /// 调用方传入“本轮新增”的纯文本与可选图片/音频，
    /// 历史由 Live backend 内部的 persistent conversation 维护。
    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error>

    // MARK: - Observable State

    /// 模型是否已加载且可用
    var isLoaded: Bool { get }

    /// 是否正在加载模型
    var isLoading: Bool { get }

    /// 是否正在推理
    var isGenerating: Bool { get }

    /// 状态消息 (显示在 UI 上)
    var statusMessage: String { get set }

    /// 推理统计
    var stats: InferenceStats { get }

    // MARK: - Sampling Configuration

    var samplingTopK: Int { get set }
    var samplingTopP: Float { get set }
    var samplingTemperature: Float { get set }
    var maxOutputTokens: Int { get set }

    // MARK: - KV Cache Session (optional backend capability)
    //
    // 持久化 session 能力的可选接口。后端没有这个概念时走默认实现，
    // 产品层 (AgentEngine) 不需要 as? 到具体后端类型。
    //
    // - LiteRT: 真实实现 (persistent session + KV cache reuse + benchmark snapshot)
    // - MLX / 其它: 走协议默认 (0 / false / 空 no-op), 功能降级但语义正确

    /// 上一轮实际 prefill 的 token 数。无 KV 能力的后端返回 0。
    /// 给 hotfix 观测 `kv_prefill_tokens` 字段提供真实数据源。
    var lastKVPrefillTokens: Int { get }

    /// 持久化 session 是否激活。用于 AgentEngine 判断能否走 delta prompt。
    var kvSessionActive: Bool { get }

    /// 当前 session 是否已经累积过 context (= 非首轮)。
    /// delta prompt 判断两个条件: kvSessionActive && sessionHasContext。
    var sessionHasContext: Bool { get }

    /// 重置 KV session (关掉 + 重开)。无 KV 能力的后端为 no-op。
    func resetKVSession() async

    /// 如果后端当前 engine 带了懒加载的多模态 (vision/audio) encoder,
    /// 释放掉回到纯文本状态。只 LiteRT 有意义, 其他后端 no-op。
    /// 典型调用点: 用户新建会话 / 切换会话 — 释放 ~800 MB pinned memory,
    /// 下次需要多模态时再 lazy reload 回来。
    func revertToTextOnly() async

    /// 通知后端切换推理 backend (`"gpu"` / `"cpu"`). 只 LiteRT 实际使用这个值;
    /// MLX 等后端 no-op。**不会**自动 reload engine, 调用方需要随后 unload + load。
    func setPreferredBackend(_ backend: String)

    /// 通知后端是否启用 Gemma 4 MTP speculative decoding。仅 LiteRT 后端 +
    /// Gemma 4 (.litertlm 含 mtp_drafter section) 有效, 其他后端 no-op。
    /// **不会**自动 reload engine, 调用方需要随后 unload + load。
    func setEnableSpeculativeDecoding(_ enabled: Bool)

    /// Prompt/session group 切换前的后端准备钩子。
    /// 用于像 LiteRT 这类“同一时刻只能有一种 session 形态”的后端在
    /// text <-> multimodal 切换时做显式收敛。
    func prepareForSessionGroupTransition(
        from previousGroup: SessionGroup?,
        to nextGroup: SessionGroup
    ) async
}

// MARK: - Default no-op implementations for backends without KV session

public extension InferenceService {
    var lastKVPrefillTokens: Int { 0 }
    var kvSessionActive: Bool { false }
    var sessionHasContext: Bool { false }
    func resetKVSession() async { /* no-op */ }
    func revertToTextOnly() async { /* no-op */ }
    func setPreferredBackend(_ backend: String) { /* no-op */ }
    func setEnableSpeculativeDecoding(_ enabled: Bool) { /* no-op */ }
    func prepareForSessionGroupTransition(
        from previousGroup: SessionGroup?,
        to nextGroup: SessionGroup
    ) async { /* no-op */ }
}

// MARK: - Shared Backend Error

/// Backend-neutral 推理错误。任何 InferenceService 实现都可以抛这个类型;
/// AgentEngine 按 enum case 做分类, 不依赖具体后端文件是否在编译单元里。
public enum ModelBackendError: LocalizedError {
    case modelNotLoaded
    case modelFileMissing(String)
    case memoryRisk(model: String, headroomMB: Int, recommendation: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return tr(
                "模型未加载，请先在配置页下载并加载模型。",
                "Model not loaded. Please download and load a model from the configuration page first."
            )
        case .modelFileMissing(let name):
            return tr(
                "\(name) 模型文件不存在，请先在配置页下载。",
                "\(name) model file not found. Please download it from the configuration page first."
            )
        case .memoryRisk(let model, let headroomMB, let recommendation):
            return tr(
                "\(model) 当前剩余内存仅约 \(headroomMB) MB。\(recommendation)",
                "\(model): only about \(headroomMB) MB of memory is available. \(recommendation)"
            )
        }
    }
}

// MARK: - Callback convenience wrappers

/// 产品层 (AgentEngine) 大量使用 callback 风格调用。
/// 这些扩展基于 stream 版本自动适配，后端不需要实现它们。
///
/// 批量把 token 推给主线程，避免流式阶段每个 token 都触发一次 UI 刷新。
private func splitFlushableCallbackBuffer(_ text: String) -> (flushable: String, remainder: String) {
    guard !text.isEmpty else { return ("", "") }

    let lookbehind = max(0, (callbackControlMarkers.map(\.count).max() ?? 0) - 1)
    guard lookbehind > 0 else { return (text, "") }

    let suffixCount = min(text.count, lookbehind)
    let suffixStart = text.index(text.endIndex, offsetBy: -suffixCount)
    let suffix = String(text[suffixStart...])

    var holdback = 0
    for marker in callbackControlMarkers {
        let maxCandidate = min(marker.count - 1, suffix.count)
        guard maxCandidate > 0 else { continue }
        for candidateLength in stride(from: maxCandidate, through: 1, by: -1) {
            let candidate = String(suffix.suffix(candidateLength))
            if marker.hasPrefix(candidate) {
                holdback = max(holdback, candidateLength)
                break
            }
        }
    }

    guard holdback > 0, holdback < text.count else {
        return holdback >= text.count ? ("", text) : (text, "")
    }

    let splitIndex = text.index(text.endIndex, offsetBy: -holdback)
    return (String(text[..<splitIndex]), String(text[splitIndex...]))
}

private func shouldFlushCallbackBuffer(
    pending: String,
    newestChunk: String,
    now: CFTimeInterval,
    lastFlushAt: CFTimeInterval
) -> Bool {
    if pending.count >= callbackBatchSizeThreshold {
        return true
    }

    if newestChunk.last.map(callbackImmediateFlushCharacters.contains) == true {
        return true
    }

    return (now - lastFlushAt) >= callbackFlushInterval
}

private func streamWithBatchedCallbacks(
    source: AsyncThrowingStream<String, Error>,
    onToken: @escaping @Sendable (String) -> Void,
    onComplete: @escaping @Sendable (Result<String, Error>) -> Void
) {
    Task {
        var fullResponse = ""
        var pending = ""
        var lastFlushAt = CFAbsoluteTimeGetCurrent()

        func flushPending(force: Bool = false) async {
            guard !pending.isEmpty else { return }

            let flushable: String
            let remainder: String
            if force {
                flushable = pending
                remainder = ""
            } else {
                let split = splitFlushableCallbackBuffer(pending)
                flushable = split.flushable
                remainder = split.remainder
            }

            pending = remainder
            guard !flushable.isEmpty else { return }

            lastFlushAt = CFAbsoluteTimeGetCurrent()
            await MainActor.run { onToken(flushable) }
        }

        do {
            for try await token in source {
                fullResponse += token
                pending += token

                let now = CFAbsoluteTimeGetCurrent()
                if shouldFlushCallbackBuffer(
                    pending: pending,
                    newestChunk: token,
                    now: now,
                    lastFlushAt: lastFlushAt
                ) {
                    await flushPending()
                }
            }

            await flushPending(force: true)
            let completedResponse = fullResponse
            await MainActor.run { onComplete(.success(completedResponse)) }
        } catch {
            await flushPending(force: true)
            await MainActor.run { onComplete(.failure(error)) }
        }
    }
}

public extension InferenceService {

    func generate(
        prompt: String,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        streamWithBatchedCallbacks(
            source: generate(prompt: prompt),
            onToken: onToken,
            onComplete: onComplete
        )
    }

    func generateMultimodal(
        images: [CIImage] = [],
        audios: [AudioInput] = [],
        prompt: String,
        systemPrompt: String = "",
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        streamWithBatchedCallbacks(
            source: generateMultimodal(
                images: images,
                audios: audios,
                prompt: prompt,
                systemPrompt: systemPrompt
            ),
            onToken: onToken,
            onComplete: onComplete
        )
    }
}
