import Foundation
import CoreImage
import MLXLMCommon

// MARK: - LiveTurnProcessor
//
// 单轮处理器 — LiveModeEngine 的下游. 把 "ASR transcript + 摄像头 frame + 历史"
// 一次转化成 LLM prompt, 调 MLX, 把 token 流解析成语义事件推给 engine.
//
// 分层职责:
//   LiveModeEngine (会话状态机, VAD/ASR/TTS pipeline)
//     └→ LiveTurnProcessor (单轮协调, 本文件)
//           ├→ PromptBuilder.buildLiveVoicePrompt  (prompt 拼接)
//           ├→ MLXLocalLLMService.generateStream(rawText:images:)  (推理)
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

    private let llm: MLXLocalLLMService

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

    init(llm: MLXLocalLLMService) {
        self.llm = llm
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

        let tokenStream: AsyncThrowingStream<String, Error>

        if let frame {
            // ── Vision 路径: 完全复刻之前 Antigravity chat path 已验证不崩的代码 ──
            //
            // 直接构造 [Chat.Message] (system + history + user(text, images:))
            // 调 llm.generateStream(chat:). chat template 自己处理 image
            // placeholder 注入, 不走 rawText path 的 single-message 包装,
            // 内存特征完全等价于"重构前已经稳定多次摄像头交互"的代码.
            //
            // System prompt 使用简化版 (不引用 SYSPROMPT.md), 这是 vision
            // 场景下的有意 trade-off: persona 锚点(如"手机龙虾")在视觉问答
            // 里不重要, 用户问"看到什么"只需准确识图; 短 prompt 更省 KV cache,
            // 给 vision tower 留出更多内存 spike 空间, 避免 jetsam OOM.
            let cfg = locale.config
            var visionSystem = PromptBuilder.defaultSystemPrompt + "\n\n" + cfg.voiceConstraints
            visionSystem += "\n" + cfg.visionConstraint

            var chatMessages: [Chat.Message] = [.system(visionSystem)]
            for msg in history.suffix(historyDepth) {
                switch msg.role {
                case .user:      chatMessages.append(.user(msg.content))
                case .assistant: chatMessages.append(.assistant(msg.content))
                }
            }
            // user content 不拼 imagePromptSuffix —— chat template 自己注入.
            //
            // Vision 强约束放在 user message 末尾 (距离 generation 最近, 影响最强).
            // Gemma 4 4bit 对 system prompt 里的"必须以 X 开头"跟随弱, 但对紧挨着
            // generation 的指令敏感. 真机 + harness 验证: 放 system 不生效, 放 user 末尾
            // 才能压住 "这是一个 XXX" / "宣传图" 等离题措辞.
            chatMessages.append(.user(transcript + cfg.userHint + cfg.visionUserGuard, images: [.ciImage(frame)]))

            tokenStream = llm.generateStream(chat: chatMessages)
        } else {
            // ── 纯文本路径: 走 rawText / .text 分支, 享受 persona / marker 修复 ──
            //
            // Harness (2026-04-16) 已验证:
            //   prompt path → Gemma 4 持得住 persona ("手机龙虾") + marker (✓/○/◐)
            //   chat path  → applyChatTemplate 稀释 system role, persona/marker 失效
            // SYSPROMPT.md 全暴露 + skill 章节 trim + alias 替换 + suppression 兜底
            // 都在 buildLiveVoicePrompt 内处理, 保证 LLM 看到干净一致的 system.
            let rawTextPrompt = PromptBuilder.buildLiveVoicePrompt(
                userSystemPrompt: userSystemPrompt,
                locale: locale,
                history: history.map { (role: $0.role.rawValue, content: $0.content) },
                historyDepth: historyDepth,
                userTranscript: transcript,
                hasVision: false,
                imageCount: 0,
                preloadedSkills: enableSkillInvocation ? preloadedSkillsForThisTurn() : []
            )
            tokenStream = llm.generateStream(rawText: rawTextPrompt, images: [])
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
