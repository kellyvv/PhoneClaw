import Foundation
import CoreImage

// MARK: - LiveTurnProcessor
//
// 单轮处理器 — LiveModeEngine 的下游. 把 "ASR transcript + 摄像头 frame + 历史"
// 一次转化成 LLM prompt, 调推理后端, 把 token 流解析成语义事件推给 engine.
//
// 分层职责:
//   LiveModeEngine (会话状态机, VAD/ASR/TTS pipeline)
//     └→ LiveTurnProcessor (单轮协调, 本文件)
//           ├→ PromptBuilder.buildLiveVoicePrompt  (prompt 拼接)
//           ├→ InferenceService.generateRaw(text:images:)  (推理)
//           └→ LiveOutputParser  (token 流解析)
//
// 阶段 1 (MVP):
//   enableSkillInvocation = false → preloadedSkills 永远空, LLM 不输出 tool_call,
//   parser 虽有 tool_call 状态机代码但走不到. 纯聊天 + 多模态 + marker 能力.
//
// 阶段 3 (Skill):
//   enableSkillInvocation = true → Router 算出 matched skills, 拼 preloadedSkills
//   进 prompt, parser 截获 tool_call, processor 调 ToolRegistry 执行, 再启第二轮
//   LLM inference 做结果总结 (emit .skillResult), TTS 朗读.

// 注意: 不标 @MainActor — processor 只做 prompt 拼接 + LLM stream + parse,
// 没有 UI 操作, 不需要主线程约束. 让调用方 (LiveModeEngine.processAudio) 在自己
// 的 actor 上下文里自由构造和调用.
final class LiveTurnProcessor {

    // MARK: - Dependencies

    private let inference: InferenceService

    // MARK: - Configuration

    /// 阶段开关. 阶段 1 = false (纯聊天, 无 Skill), 阶段 3 打开真正的 tool_call 通道.
    var enableSkillInvocation: Bool = false

    /// 历史轮数. 默认 4 和原 LiveModeEngine.maxLiveHistoryDepth 一致.
    var historyDepth: Int = 4

    /// 最大输出 token 数. Live 口语回答应该短, 默认 200 token 足够.
    var maxOutputTokens: Int = 200

    /// i18n — 语音 locale (zh-CN / en-US / ...). 决定 persona 名字、prompt 模板、
    /// fallback 话术. 默认中文; engine 可以按用户偏好/系统 locale 覆写.
    var locale: LiveLocale = .zhCN

    /// 当 engine 收到 unexpected tool_call 时朗读的口语兜底. 直接从当前 locale 取,
    /// 避免 engine 侧硬编码中文字符串.
    var fallbackUtterance: String { locale.config.fallbackUtterance }

    // MARK: - Init

    init(inference: InferenceService) {
        self.inference = inference
    }

    // MARK: - Public

    /// 处理一轮 Live 对话. 返回事件流, 调用方 (LiveModeEngine) 用 for-await 消费.
    ///
    /// - Parameters:
    ///   - transcript: ASR 输出的当前轮用户纯文本.
    ///   - frame: 可选摄像头画面 (由 LiveCameraService 提供).
    ///   - history: 历史 (user/assistant 交替). 会按 historyDepth 截断.
    ///   - userSystemPrompt: 用户 SYSPROMPT.md 内容 (来自 AgentEngine.config.systemPrompt).
    ///     nil 走 PromptBuilder.defaultSystemPrompt 兜底.
    func processTurn(
        transcript: String,
        frame: CIImage?,
        history: [LiveHistoryMessage],
        userSystemPrompt: String?
    ) -> AsyncThrowingStream<LiveOutputEvent, Error> {

        // 构造完整 prompt — vision 和纯文本都走 buildLiveVoicePrompt,
        // 区别在于 hasVision 标志和是否传 frame 给推理后端.
        let fullPrompt = PromptBuilder.buildLiveVoicePrompt(
            userSystemPrompt: userSystemPrompt,
            locale: locale,
            history: history.map { (role: $0.role.rawValue, content: $0.content) },
            historyDepth: historyDepth,
            userTranscript: transcript,
            hasVision: frame != nil,
            imageCount: frame != nil ? 1 : 0,
            preloadedSkills: enableSkillInvocation ? preloadedSkillsForThisTurn() : []
        )

        let images: [CIImage] = frame.map { [$0] } ?? []

        let tokenStream: AsyncThrowingStream<String, Error>

        if images.isEmpty,
           let litert = inference as? LiteRTBackend,
           litert.kvSessionActive
        {
            // 纯文本 + session 活跃: 走 persistent session (KV cache 复用)
            if history.isEmpty {
                // 首轮: 完整 prompt → 全量 prefill
                tokenStream = inference.generate(prompt: fullPrompt)
            } else {
                // Follow-up: delta only → ~300ms TTFT
                let cfg = locale.config
                let delta = PromptBuilder.buildDeltaTurnPrompt(
                    userMessage: transcript + cfg.userHint
                )
                print("[Live] KV delta: \(delta.count) chars (vs full \(fullPrompt.count) chars)")
                tokenStream = inference.generate(prompt: delta)
            }
        } else {
            // 有图 / 无 session: 走 generateRaw (multimodal 或 one-shot)
            tokenStream = inference.generateRaw(text: fullPrompt, images: images)
        }

        return makeEventStream(tokenStream: tokenStream)
    }

    // MARK: - Private — stream composition

    /// 把原始 token stream 包成 LiveOutputEvent stream:
    ///   - 每个 delta 喂 parser.consume(delta:), forward 产出的事件.
    ///   - 收到超过 maxOutputTokens 后主动 break (安全护栏).
    ///   - stream 正常结束时 parser.finish() flush 残余并 emit .done.
    ///   - 错误时 continuation.finish(throwing:).
    private func makeEventStream(
        tokenStream: AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<LiveOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                let parser = LiveOutputParser()
                var emittedTokens = 0

                do {
                    for try await delta in tokenStream {
                        emittedTokens += 1
                        for event in parser.consume(delta: delta) {
                            continuation.yield(event)
                            if case .done = event {
                                continuation.finish()
                                return
                            }
                        }
                        if emittedTokens >= self.maxOutputTokens {
                            break
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private — skill hook (阶段 3 填充)

    /// 阶段 3 打开 tool_call 通道时填充. 现在永远返空.
    /// 未来实现: 调 Router.matchedSkillIds(for: transcript), 从 SkillRegistry 取 body,
    /// 返回 PreloadedSkill 数组给 prompt builder.
    private func preloadedSkillsForThisTurn() -> [PromptBuilder.PreloadedSkill] {
        []
    }
}
