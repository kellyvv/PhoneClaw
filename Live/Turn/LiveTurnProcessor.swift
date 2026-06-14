import Foundation
import CoreImage

#if canImport(UIKit)
import UIKit
#endif

// MARK: - LiveTurnProcessor
//
// 单轮处理器 — LiveModeEngine 的下游. 把 "ASR transcript + 摄像头 frame + 历史"
// 一次转化成 LLM prompt, 调推理后端, 把 token 流解析成语义事件推给 engine.
//
// 分层职责:
//   LiveModeEngine (会话状态机, VAD/ASR/TTS pipeline)
//     └→ LiveTurnProcessor (单轮协调, 本文件)
//           ├→ PromptBuilder.buildLiveVoiceUserPrompt  (本轮 user text 拼接)
//           ├→ LiveTurnTokenSource                     (token 来源: local / foundation)
//           └→ LiveOutputParser                        (token 流解析)
//
// 非 Skill 轮:
//   enableSkillInvocation = false 或 router 未命中 → 不拼 Skill contract, LLM 不应输出
//   tool_call. 纯聊天 + 多模态 + marker 能力保持原路径 (永远走本地 persistent conversation).
//
// 阶段 3 (Skill):
//   enableSkillInvocation = true → LiveSkillRuntime 算出 matched skill, 把本轮
//   LIVE_SKILL_CONTRACT 拼进 user turn. parser 截获 tool_call 后, processor 调
//   ToolRegistry 执行并 emit .skillInfo, 先完成信息输出链路, 不进入 TTS.
//
// Skill 轮 token 源选择 (链路本身不变, 只换"谁来念这份 contract"):
//   1. IOS27LiveFoundationTokenSource — 系统模型, 系统进程推理, 后台不受 GPU 限制.
//      合法产出只有 contract 规定的两种: tool_call 或 ✓ 追问.
//   2. 任何失败 (不可用 / 报错 / 产出不符合 contract) → 回退 LocalLiveTurnTokenSource,
//      即原本地 contract 路径 — 不会比引入 FM 之前差.

// 注意: 不标 @MainActor — processor 只做 prompt 拼接 + LLM stream + parse,
// 没有 UI 操作, 不需要主线程约束. 让调用方 (LiveModeEngine.processAudio) 在自己
// 的 actor 上下文里自由构造和调用.
final class LiveTurnProcessor {

    // MARK: - Dependencies

    private let skillRuntime: LiveSkillRuntime
    private let localSource: LiveTurnTokenSource
    private let foundationSource: LiveTurnTokenSource

    // MARK: - Configuration

    /// 阶段开关. true 时 LIVE 会先路由到工具型 Skill，再打开受控 tool_call 通道.
    var enableSkillInvocation: Bool = true

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

    init(
        inference: InferenceService,
        skillRegistry: SkillRegistry = SkillRegistry(),
        toolRegistry: ToolRegistry = .shared,
        foundationSource: LiveTurnTokenSource = IOS27LiveFoundationTokenSource()
    ) {
        self.skillRuntime = LiveSkillRuntime(skillRegistry: skillRegistry, toolRegistry: toolRegistry)
        self.localSource = LocalLiveTurnTokenSource(inference: inference)
        self.foundationSource = foundationSource
    }

    // MARK: - Public

    /// 处理一轮 Live 对话. 返回事件流, 调用方 (LiveModeEngine) 用 for-await 消费.
    ///
    /// - Parameters:
    ///   - transcript: ASR 输出的当前轮用户纯文本.
    ///   - frame: 可选摄像头画面 (由 LiveCameraService 提供).
    ///   - cameraOff: 本会话开过摄像头但当前已关。true 时 PromptBuilder 加 "(摄像头未开启)"
    ///     marker, 防止模型基于陈旧 vision KV 幻觉。视觉轮 (frame != nil) 由 PromptBuilder
    ///     自己处理 vision hint, 不读这个值。
    /// - Parameter recentExchange: 最近一组对话 (engine 从 liveHistory 取)。只给 FM
    ///   源用 — FM session 每轮新建没有 KV, 没有它就解不开"追问→简短回答"的环;
    ///   本地路径的 persistent conversation 自带上下文, 不重复注入。
    func processTurn(
        transcript: String,
        frame: CIImage?,
        cameraOff: Bool = false,
        recentExchange: String? = nil
    ) async -> AsyncThrowingStream<LiveOutputEvent, Error> {
        _ = historyDepth
        let resolvedSkillRoute = enableSkillInvocation && frame == nil
            ? await skillRuntime.route(for: transcript)
            : nil

        var turnPrompt = PromptBuilder.buildLiveVoiceUserPrompt(
            userTranscript: transcript,
            locale: locale,
            hasVision: frame != nil,
            cameraOff: cameraOff
        )
        if let resolvedSkillRoute {
            turnPrompt += resolvedSkillRoute.contractPrompt
        }

        let images: [CIImage] = frame.map { [$0] } ?? []

        return makeEventStream(
            turnPrompt: turnPrompt,
            images: images,
            skillRoute: resolvedSkillRoute,
            recentExchange: recentExchange
        )
    }

    // MARK: - Private — stream composition

    /// 组装本轮事件流:
    ///   - Skill 轮且 FM 可用 → 先用 foundationSource 跑 (attemptSkillTurn),
    ///     成功则事件已发出, 直接 finish; 失败回退本地, 未发出任何事件.
    ///   - 其余 (chat 轮 / 回退) → 本地 token 流按原逻辑消费 (consumeTokenStream).
    private func makeEventStream(
        turnPrompt: String,
        images: [CIImage],
        skillRoute: LiveSkillRoute?,
        recentExchange: String? = nil
    ) -> AsyncThrowingStream<LiveOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { return }

                // network 型 skill (联网检索) 的 query 构造/结果判读是在原 LLM 链路上
                // 调教并做过泛化测试的 — FM 旁路只接单发结构化 skill, 检索轮永远走原链路。
                if let skillRoute, skillRoute.skillType == .network {
                    print("[LiveTokenSource] source=local skill=\(skillRoute.skillID) (network skill stays on tuned LLM chain)")
                } else if let skillRoute, self.foundationSource.isUsable {
                    let handled = await self.attemptSkillTurn(
                        via: self.foundationSource,
                        turnPrompt: turnPrompt,
                        recentExchange: recentExchange,
                        route: skillRoute,
                        continuation: continuation
                    )
                    if handled {
                        continuation.finish()
                        return
                    }
                    print("[LiveTokenSource] source=\(self.foundationSource.sourceName) → fallback to local skill=\(skillRoute.skillID)")
                }

                await self.consumeTokenStream(
                    from: self.localSource,
                    turnPrompt: turnPrompt,
                    images: images,
                    skillRoute: skillRoute,
                    continuation: continuation
                )
            }
        }
    }

    /// 用替代 token 源跑一次 Skill 轮. 产出全程缓冲, 只在确认符合 contract 后才发事件:
    ///   - tool_call        → handleSkillCall (normalize/validate/execute) → true
    ///   - ✓ 开头的短追问    → emit skillInfo (信息输出, 不 TTS) → true
    ///   - 其它/报错/空      → false, 调用方回退本地路径 (本函数未发出任何事件)
    private func attemptSkillTurn(
        via source: LiveTurnTokenSource,
        turnPrompt: String,
        recentExchange: String? = nil,
        route: LiveSkillRoute,
        continuation: AsyncThrowingStream<LiveOutputEvent, Error>.Continuation
    ) async -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let appState = await Self.applicationStateLabel()
        let parser = LiveOutputParser()
        var pendingCall: LiveSkillCall?
        var bufferedSpeech = ""
        var sawCompleteMarker = false

        func ingest(_ events: [LiveOutputEvent]) {
            for event in events {
                switch event {
                case .skillCall(let call):
                    pendingCall = call
                case .speechToken(let text):
                    bufferedSpeech += text
                case .marker(let marker):
                    if case .complete = marker { sawCompleteMarker = true }
                case .done, .skillInfo:
                    break
                }
            }
        }

        // FM 是无状态 session — 把最近一组对话拼在 turnPrompt 前, 让追问的答案可解。
        let contextBlock = recentExchange.map {
            tr(
                "【最近对话】\n\($0)\n\n",
                "[Recent conversation]\n\($0)\n\n",
                "【直近の会話】\n\($0)\n\n"
            )
        } ?? ""

        do {
            let stream = source.stream(turnPrompt: contextBlock + turnPrompt, images: [])
            for try await delta in stream {
                ingest(parser.consume(delta: delta))
                if pendingCall != nil {
                    source.cancel()
                    break
                }
            }
            if pendingCall == nil {
                ingest(parser.finish())
            }
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            print(
                "[LiveTokenSource] source=\(source.sourceName) outcome=error app=\(appState) " +
                "ms=\(ms) skill=\(route.skillID) error=\(Self.compactLogValue(String(describing: error)))"
            )
            return false
        }

        let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

        if let call = pendingCall {
            print("[LiveTokenSource] source=\(source.sourceName) outcome=tool_call app=\(appState) ms=\(ms) skill=\(route.skillID)")
            await handleSkillCall(call, route: route, continuation: continuation)
            return true
        }

        let clarification = OutputSanitizer.sanitizeFinal(bufferedSpeech, mode: .liveVoice)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sawCompleteMarker, !clarification.isEmpty {
            // contract 允许的第二种输出: ✓ 开头的短追问 → 信息输出, 不回退.
            print("[LiveTokenSource] source=\(source.sourceName) outcome=clarification app=\(appState) ms=\(ms) skill=\(route.skillID)")
            continuation.yield(skillRuntime.infoOutput(route: route, message: clarification).asEvent)
            continuation.yield(.done)
            return true
        }

        print("[LiveTokenSource] source=\(source.sourceName) outcome=no_contract_output app=\(appState) ms=\(ms) skill=\(route.skillID)")
        return false
    }

    /// 把 token 源的原始流包成 LiveOutputEvent 流 (原 makeEventStream 主体):
    ///   - 每个 delta 喂 parser.consume(delta:), forward 产出的事件.
    ///   - 收到超过 maxOutputTokens 后主动 break (安全护栏).
    ///   - stream 正常结束时 parser.finish() flush 残余并 emit .done.
    ///   - 错误时 continuation.finish(throwing:).
    private func consumeTokenStream(
        from source: LiveTurnTokenSource,
        turnPrompt: String,
        images: [CIImage],
        skillRoute: LiveSkillRoute?,
        continuation: AsyncThrowingStream<LiveOutputEvent, Error>.Continuation
    ) async {
        let parser = LiveOutputParser()
        var emittedTokens = 0
        var bufferedSkillSpeech = ""
        let shouldBufferSpeech = skillRoute != nil
        let tokenStream = source.stream(turnPrompt: turnPrompt, images: images)

        do {
            for try await delta in tokenStream {
                emittedTokens += 1
                for event in parser.consume(delta: delta) {
                    if case .skillCall(let call) = event,
                       let skillRoute {
                        source.cancel()
                        await self.handleSkillCall(
                            call,
                            route: skillRoute,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }

                    if shouldBufferSpeech {
                        switch event {
                        case .marker:
                            continue
                        case .speechToken(let text):
                            bufferedSkillSpeech += text
                            continue
                        case .done:
                            if let skillRoute,
                               !bufferedSkillSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                continuation.yield(skillRuntime.infoOutput(
                                    route: skillRoute,
                                    message: OutputSanitizer.sanitizeFinal(bufferedSkillSpeech, mode: .liveVoice)
                                ).asEvent)
                            }
                            bufferedSkillSpeech = ""
                        case .skillCall, .skillInfo:
                            break
                        }
                    }

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
                if shouldBufferSpeech {
                    switch event {
                    case .marker:
                        continue
                    case .speechToken(let text):
                        bufferedSkillSpeech += text
                        continue
                    case .done:
                        if let skillRoute,
                           !bufferedSkillSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            continuation.yield(skillRuntime.infoOutput(
                                route: skillRoute,
                                message: OutputSanitizer.sanitizeFinal(bufferedSkillSpeech, mode: .liveVoice)
                            ).asEvent)
                        }
                        bufferedSkillSpeech = ""
                    case .skillCall, .skillInfo:
                        break
                    }
                }

                continuation.yield(event)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func handleSkillCall(
        _ rawCall: LiveSkillCall,
        route: LiveSkillRoute,
        continuation: AsyncThrowingStream<LiveOutputEvent, Error>.Continuation
    ) async {
        guard let call = skillRuntime.normalize(call: rawCall, route: route) else {
            continuation.yield(skillRuntime.infoOutput(route: route, message: fallbackUtterance).asEvent)
            continuation.yield(.done)
            return
        }

        if let validationError = skillRuntime.validate(call: call) {
            continuation.yield(skillRuntime.infoOutput(route: route, message: validationError).asEvent)
            continuation.yield(.done)
            return
        }

        let result = await skillRuntime.execute(call: call)
        continuation.yield(skillRuntime.infoOutput(route: route, call: call, result: result).asEvent)
        continuation.yield(.done)
    }

    // MARK: - Helpers

    /// 后台可用性验证的关键观测点: FM 轮发生时 app 处于什么状态.
    private static func applicationStateLabel() async -> String {
        #if canImport(UIKit)
        return await MainActor.run { () -> String in
            switch UIApplication.shared.applicationState {
            case .active: return "active"
            case .inactive: return "inactive"
            case .background: return "background"
            @unknown default: return "unknown"
            }
        }
        #else
        return "unknown"
        #endif
    }

    private static func compactLogValue(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(160)
            .description
    }
}

private extension LiveSkillInfoOutput {
    var asEvent: LiveOutputEvent { .skillInfo(self) }
}
