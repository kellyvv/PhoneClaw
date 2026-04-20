import Foundation
import CoreImage

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
}

// MARK: - Callback convenience wrappers

/// 产品层 (AgentEngine) 大量使用 callback 风格调用。
/// 这些扩展基于 stream 版本自动适配，后端不需要实现它们。
public extension InferenceService {

    func generate(
        prompt: String,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""
            do {
                for try await token in generate(prompt: prompt) {
                    fullResponse += token
                    await MainActor.run { onToken(token) }
                }
                let completedResponse = fullResponse
                await MainActor.run { onComplete(.success(completedResponse)) }
            } catch {
                await MainActor.run { onComplete(.failure(error)) }
            }
        }
    }

    func generateMultimodal(
        images: [CIImage] = [],
        audios: [AudioInput] = [],
        prompt: String,
        systemPrompt: String = "",
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        Task {
            var fullResponse = ""
            do {
                for try await token in generateMultimodal(
                    images: images, audios: audios,
                    prompt: prompt, systemPrompt: systemPrompt
                ) {
                    fullResponse += token
                    await MainActor.run { onToken(token) }
                }
                let completedResponse = fullResponse
                await MainActor.run { onComplete(.success(completedResponse)) }
            } catch {
                await MainActor.run { onComplete(.failure(error)) }
            }
        }
    }
}
