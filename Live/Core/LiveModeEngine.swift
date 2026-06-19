import Foundation
import AVFoundation
import CoreImage

enum LiveIncompleteTurnType: Equatable {
    case short
    case long

    var marker: Character {
        switch self {
        case .short: return "○"
        case .long: return "◐"
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .short: return 5.0
        case .long: return 10.0
        }
    }
}

struct LiveTurnCompletionParseResult {
    var speakableText: String = ""
    var markerText: String?
    var incompleteType: LiveIncompleteTurnType?
}

struct LiveTurnCompletionParser {
    enum State {
        case awaitingMarker
        case complete
        case suppressed(LiveIncompleteTurnType)
    }

    private(set) var state: State = .awaitingMarker
    private(set) var bufferedText = ""
    private(set) var sawCompleteMarker = false

    mutating func consume(_ incoming: String) -> LiveTurnCompletionParseResult {
        switch state {
        case .complete:
            return LiveTurnCompletionParseResult(speakableText: incoming)
        case .suppressed:
            return LiveTurnCompletionParseResult()
        case .awaitingMarker:
            bufferedText += incoming

            if bufferedText.contains("○") {
                state = .suppressed(.short)
                bufferedText = ""
                return LiveTurnCompletionParseResult(
                    markerText: "○",
                    incompleteType: .short
                )
            }

            if bufferedText.contains("◐") {
                state = .suppressed(.long)
                bufferedText = ""
                return LiveTurnCompletionParseResult(
                    markerText: "◐",
                    incompleteType: .long
                )
            }

            guard let markerIndex = bufferedText.firstIndex(of: "✓") else {
                return LiveTurnCompletionParseResult()
            }

            let afterMarker = bufferedText.index(after: markerIndex)
            var speakable = String(bufferedText[afterMarker...])
            if speakable.first == " " {
                speakable.removeFirst()
            }

            bufferedText = ""
            sawCompleteMarker = true
            state = .complete
            return LiveTurnCompletionParseResult(
                speakableText: speakable,
                markerText: "✓"
            )
        }
    }

    mutating func finalizeWithoutMarker() -> String {
        guard case .awaitingMarker = state else { return "" }
        let fallback = bufferedText
        bufferedText = ""
        state = .complete
        return fallback
    }
}

// MARK: - Live Mode Engine
//
// 架构: VAD → VoiceTurnController / interruption semantics → ASR → LLM (streaming) → StreamingSanitizer → speakable segment → TTS Queue
// 核心: VAD 和 TTS 共享同一个 AVAudioEngine (LiveAudioIO), iOS AEC 消除 TTS 回声
//
// Turn lifecycle managed by VoiceTurnController:
//   listening → recording → pendingStop (100ms grace) → confirmed → processAudio
//
// Interruption policy (Pipecat-style semantics):
//   Idle: VAD speechStart can start aggregation immediately
//   Bot speaking: speechStart only opens an interruption candidate
//   Candidate becomes a real user turn only after streaming ASR returns enough
//   semantic units (min 3 while bot speaking, min 1 otherwise)
//
// Context: 1-turn history via PromptBuilder.buildLightweightTextPrompt(history:)
// Metrics: structured per-turn LiveTurnMetrics with E2E breakdown

@Observable
class LiveModeEngine {

    enum State: String {
        case idle
        case listening
        case recording
        case processing
        case speaking
    }

    enum TurnPhase {
        case inactive
        case starting
        case listening
        case recording
        case processing
        case speaking
        case stopping
    }

    struct LiveAgentProgressSnapshot: Equatable {
        let key: String
        let phase: String
        let headline: String
        let detail: String
        let skillID: String?
        let skillName: String?
        let toolName: String?
    }

    var state: State = .idle
    private(set) var lastTranscript: String = ""
    var lastReply: String = ""
    var lastSkillInfo: LiveSkillInfoOutput?
    var liveProgressHeadline: String?
    var liveCaption: String = ""
    private(set) var endedByLiveActivityDismissal = false
    var inputLevel: Double = 0
    var statusMessage: String = LiveLocale.zhCN.config.statusStrings.preparingLive

    /// 可视化音频分析器（由 OrbSceneView 弱引用）
    /// start() 前为 nil，stop() 后清零。@Observable 无需额外通知机制。
    private(set) var inputAnalyser:  OrbAudioAnalyser? = nil
    private(set) var outputAnalyser: OrbAudioAnalyser? = nil

    private let vad = VADService()
    let tts = TTSService()
    private let asr = ASRService()
    let liveActivity = LiveActivityBridge()
    let backgroundContinuation = LiveBackgroundContinuation.shared
    private var audioIO: LiveAudioIO?
    var ttsQueue: AudioPlaybackQueue?
    private weak var inference: (any InferenceService)?
    var agentEngine: AgentEngine?
    private var didEnterLLMLiveMode = false

    var turnPhase: TurnPhase = .inactive
    var turnGeneration: UInt64 = 0
    private var liveActivityListeningRefreshTask: Task<Void, Never>?
    private var liveActivityDismissalTask: Task<Void, Never>?

    private var synthesisPipeline: AsyncStream<String>.Continuation?
    private var synthesisTask: Task<Void, Never>?

    // MARK: - Turn Controller

    private let turnController = VoiceTurnController()

    // MARK: - Pipecat-style Interruption State

    private struct PendingInterruption {
        var transcript: String = ""
        var unitCount: Int = 0
    }

    private var isPreviewingCurrentTurn = false
    private var pendingInterruption: PendingInterruption?
    private let minInterruptionUnitsWhileAssistantActive = 3

    // MARK: - Context Continuity

    private var liveHistory: [ChatMessage] = []
    private let maxLiveHistoryDepth = 4  // incomplete marker + follow-up 会让一次交互超过 2 条消息
    let mainAgentTurnTimeout: TimeInterval = 180

    // MARK: - Echo Suppression

    /// Timestamp when the last assistant playback finished.
    /// Used for diagnostics and potential future echo-window gating.
    var lastAssistantPlaybackEndTime: CFAbsoluteTime = 0

    // MARK: - Metrics

    /// Shared reference so enqueueForPlayback can stamp ttsFirstChunkAt
    /// on the same metrics struct that processAudio prints.
    var currentTurnMetrics: LiveTurnMetrics?

    // MARK: - Incomplete Turn Follow-up

    private var incompleteTurnTimeoutTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// 摄像头帧提供器，由 UI 层注入。Engine 不直接依赖 LiveCameraService。
    var frameProvider: (() -> CIImage?)?

    /// 当前摄像头是否开启 (由 UI 层通过 notifyCameraStateChanged 同步)。
    /// 用于判断下一轮 user prompt 是否需要 "(摄像头未开启)" marker (跟 hasOpenedCameraEver 配合)。
    private var cameraEnabled: Bool = false

    /// 本次 Live 会话是否曾经开启过摄像头。会话开始时 reset。
    /// 跟 cameraEnabled 配合, 决定纯文本轮是否需要 camera-off marker:
    /// 仅当 hasOpenedCameraEver=true && cameraEnabled=false 时贴, 防止模型基于陈旧 vision KV 幻觉。
    private var hasOpenedCameraEver: Bool = false

    /// 通知 engine 摄像头状态变化.
    ///
    /// 历史: 原实现在这里额外 prefill 一条系统消息进 KV (`generateLive` + 立即 cancel),
    /// 让模型感知摄像头状态。但这条路径会跟 greeting / 用户轮次的 generateLive 并发,
    /// 在 iPhone 16 Pro / iOS 26.5 上撞到 MiniCPM-V 原生 ctx 导致闪退。
    ///
    /// 现在只记状态, 不触发任何推理。摄像头状态通过两条路径反映到 prompt:
    ///   1. ON + 有 frame: PromptBuilder 在视觉轮加 task hint, 模型直接看图作答
    ///   2. OFF + 之前开过: PromptBuilder 加 "(摄像头未开启)" marker, 防 stale KV 幻觉
    /// 详见 `PromptBuilder.buildLiveVoiceUserPrompt`。
    func notifyCameraStateChanged(isOn: Bool) {
        cameraEnabled = isOn
        if isOn { hasOpenedCameraEver = true }
        print("[Live] 📷 Camera state → \(isOn ? "ON" : "OFF") (state only, no inference)")
    }

    private var liveLocaleConfig: LiveLocaleConfig { LiveLocale.zhCN.config }
    var liveStrings: LiveLocaleConfig.StatusStrings { liveLocaleConfig.statusStrings }

    func setup(inference: InferenceService, agentEngine: AgentEngine? = nil) {
        self.inference = inference
        self.agentEngine = agentEngine
        print("[LiveAgent] setup main_agent=\(agentEngine != nil)")
    }

    /// 调用方注入的用户 SYSPROMPT.md 内容（来自 AgentEngine.config.systemPrompt）。
    /// Phase 1 起 Live 不再读取这份通用 system prompt；先保留注入口，避免接口变化。
    var userSystemPrompt: String?

    func start() async {
        await startLegacy()
    }

    func prewarmVoiceStack() async {
        guard turnPhase == .inactive else { return }
        guard LiveModelDefinition.isAvailable else { return }

        print("[LiveWarm] prewarm starting")
        await vad.initialize()
        guard !Task.isCancelled else { return }
        await asr.initialize()
        guard !Task.isCancelled else { return }
        await tts.initialize()
        print("[LiveWarm] prewarm completed vad=\(vad.isAvailable) asr=\(asr.isAvailable) tts=\(tts.isAvailable)")
    }

    // MARK: - Legacy path (only path)

    @MainActor
    private func startLegacy() async {
        if turnPhase == .stopping {
            print("[Live] start requested while stopping — waiting for teardown")
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if turnPhase == .inactive { break }
            }
        }
        guard turnPhase == .inactive else { return }
        turnPhase = .starting
        endedByLiveActivityDismissal = false
        // state 保持 .idle — orb 暗色, 用户看到 "加载中"。
        // 历史 bug: 这里本来过早把 state 设成 .listening, 跟下面 line ~405
        // 注释里的"state 保持 .idle"意图相反。UI 上 camera/麦克风入口如果按
        // state == .listening 判定 ready, 就会在 greeting 还没播完之前允许
        // 用户交互 — 摄像头按钮可点 → 触发并发推理 → MTMD ctx 撞死 → 闪退。
        // 状态机正解: starting (state=.idle) → speaking (greeting 播放) → listening (VAD 起)。
        statusMessage = liveStrings.preparingLive
        // 新会话: 重置摄像头跟踪状态。上一次会话 KV 已经被 enterLiveMode 的
        // cleanKVCache 清掉, "hasOpenedCameraEver" 跟着归零, 否则会在新会话第一轮
        // 错误地贴 (摄像头未开启) marker。
        cameraEnabled = false
        hasOpenedCameraEver = false
        print("[Live] Starting (legacy)...")
        await Task.yield()

        // 检查 LIVE 语音模型是否已就绪 (ASR + TTS)
        if !LiveModelDefinition.isAvailable {
            print("[Live] ❌ LIVE voice models not available")
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.liveModelMissing
            return
        }

        let io = LiveAudioIO()
        do {
            try io.start()
        } catch {
            print("[Live] ❌ Audio engine error: \(error)")
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.audioEngineFailed
            return
        }
        audioIO = io
        tts.audioIO = io

        // ── 可视化 analyser 接线（对齐原版 audio-orb） ──
        // 原版: inputNode(GainNode) → AnalyserNode，默认参数，无中间缓冲。
        // input / output 路径对称：都直接喂 analyser，都用默认参数。
        let inAn  = OrbAudioAnalyser()
        let outAn = OrbAudioAnalyser()
        inputAnalyser  = inAn
        outputAnalyser = outAn
        io.visualisationInputHandler = { [weak inAn] samples in
            inAn?.process(samples: samples)
        }
        io.visualisationOutputHandler = { [weak outAn] ptr, cnt in outAn?.process(pointer: ptr, count: cnt) }

        guard turnPhase == .starting else { return }

        await vad.initialize()
        guard turnPhase == .starting else { return }

        await asr.initialize()
        await tts.initialize()
        guard turnPhase == .starting else { return }

        ttsQueue = AudioPlaybackQueue(tts: tts)

        guard vad.isAvailable else {
            print("[Live] ❌ VAD not available")
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.vadUnavailable
            return
        }
        guard turnPhase == .starting else { return }

        await ttsQueue?.reset()
        guard turnPhase == .starting else { return }

        // Wire turn controller callbacks
        turnController.onTurnStarted = { [weak self] in
            guard let self else { return }
            self.cancelLiveActivityListeningRefresh()
            self.cancelIncompleteTurnFollowUp()
            self.beginCurrentTurnPreview()
            self.lastTranscript = ""
            self.lastReply = ""
            self.lastSkillInfo = nil
            self.liveProgressHeadline = nil
            self.liveCaption = ""
            self.turnPhase = .recording
            self.state = .recording
            self.statusMessage = self.liveStrings.recording
            Task {
                await self.liveActivity.update(
                    phase: "recording",
                    headline: "PhoneClaw LIVE",
                    detail: self.liveStrings.recording
                )
            }
            self.backgroundContinuation.update(phase: "recording", detail: self.liveStrings.recording)
            print("[Live] 🎤 Recording...")
        }

        turnController.onTurnConfirmed = { [weak self] samples in
            guard let self else { return }
            self.finalizeCurrentTurnPreview()
            self.turnGeneration &+= 1
            self.turnPhase = .processing
            self.state = .processing
            self.statusMessage = self.liveStrings.processing
            // Don't stop VAD — keep it running for barge-in detection during processing/speaking
            let dur = Double(samples.count) / 16000.0
            Task {
                await self.liveActivity.update(
                    phase: "processing",
                    headline: "正在理解",
                    detail: self.liveStrings.processing
                )
            }
            self.backgroundContinuation.update(phase: "processing", detail: self.liveStrings.processing)
            print("[Live] 🔇 Turn confirmed (\(String(format: "%.1f", dur))s audio)")
            let gen = self.turnGeneration
            Task { await self.processAudio(samples, generation: gen) }
        }

        turnController.onTurnCancelled = { [weak self] in
            guard let self else { return }
            self.cancelCurrentTurnPreview()
            print("[Live] ⚠️ Turn cancelled (pendingStop timeout)")
            self.turnPhase = .listening
            self.state = .listening
            self.statusMessage = self.liveStrings.listeningPrompt
            Task {
                await self.liveActivity.update(
                    phase: "listening",
                    headline: "PhoneClaw LIVE",
                    detail: self.liveStrings.listeningPrompt
                )
            }
        }

        // Wire VAD callbacks
        vad.onSpeechStart = { [weak self] in
            guard let self else { return }
            switch self.turnPhase {
            case .listening, .recording:
                self.turnController.handleSpeechStart()
            case .processing, .speaking:
                self.beginPendingInterruptionIfNeeded()
            default:
                break
            }
        }

        vad.onSpeechEnd = { [weak self] samples in
            guard let self else { return }
            if self.finalizePendingInterruptionIfNeeded(with: samples) {
                return
            }
            guard self.turnPhase == .listening || self.turnPhase == .recording else { return }
            self.turnController.handleSpeechEnd(samples: samples)
        }

        vad.onSpeechChunk = { [weak self] chunk in
            guard let self else { return }
            if self.pendingInterruption != nil {
                self.handleInterruptionSpeechChunk(chunk)
            } else {
                self.handleCurrentTurnSpeechChunk(chunk)
            }
        }

        vad.onProbabilityUpdate = { [weak self] probability in
            guard let self else { return }
            // Probability no longer gates barge-in directly.
            // Pipecat-style interruption uses semantic confirmation from ASR.
            self.inputLevel = max(0, min(Double(probability), 1))
        }

        // Wire audio idle detection
        io.onAudioInputIdle = { [weak self] in
            guard let self else { return }
            // Only act on idle during processing — during starting/speaking/listening
            // the audio input may be legitimately quiet (e.g. TTS initialization takes ~3s)
            guard self.turnPhase == .processing else { return }
            print("[Live] ⚠️ Audio input idle — full cleanup")
            Task {
                await self.cancelActiveGeneration()
                self.turnController.reset()
                self.turnPhase = .listening
                self.state = .listening
                self.statusMessage = self.liveStrings.listeningPrompt
            }
        }

        // Announce then listen, with conversation-powered greeting.
        // 用 persistent multimodal conversation 推理替代固定文案, 一举三得:
        //   1. shader 预热 (首次推理触发 XNNPACK 编译)
        //   2. Live 的 system prompt 灌入同一个 conversation KV cache
        //   3. 文本 turn / 图像 turn 后续都复用这一份会话上下文
        //
        // Orb 动画时序:
        //   .idle (暗色)  → LLM 推理 + TTS 合成, 用户体感 "加载中"
        //   .speaking     → TTS 播放开始, orb 亮起
        turnPhase = .starting
        // state 保持 .idle — orb 暗色, 用户看到 "加载中"
        statusMessage = liveStrings.preparing

        guard let inference, inference.isLoaded else {
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.loadModelFirst
            return
        }

        guard agentEngine != nil else {
            print("[LiveAgent] ❌ missing MAIN AgentEngine injection; refusing LIVE-local Skill path")
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.initializationFailed
            return
        }

        // ASR -> AgentEngine.processInput mode:
        // keep LiteRT in normal chat mode so the MAIN Skill/ToolChain can use generate(...).
        didEnterLLMLiveMode = false
        print("[LiveAgent] using MAIN AgentEngine; persistent live LLM conversation skipped")
        backgroundContinuation.begin()
        await liveActivity.startSession()
        observeLiveActivityDismissal()
        turnPhase = .listening
        state = .listening
        inputLevel = 0
        statusMessage = liveStrings.listeningPrompt
        await vad.startListening(audioIO: io)
        await liveActivity.update(
            phase: "listening",
            headline: "PhoneClaw LIVE",
            detail: liveStrings.listeningPrompt
        )
        backgroundContinuation.update(phase: "listening", detail: liveStrings.listeningPrompt)
        print("[Live] 👂 Listening (ready, no greeting)")
    }

    func stop() async {
        await stopLegacy()
    }

    @MainActor
    private func stopLegacy() async {
        guard turnPhase != .stopping, turnPhase != .inactive else { return }
        turnPhase = .stopping
        cancelLiveActivityListeningRefresh()
        cancelLiveActivityDismissalObservation()

        vad.stopListening()
        await cancelActiveGeneration()

        if didEnterLLMLiveMode {
            await inference?.exitLiveMode()
            didEnterLLMLiveMode = false
        }

        // 先断 handler，再清 analyser（防止 displayLink 读到 deallocating 对象）
        audioIO?.visualisationInputRawHandler = nil
        audioIO?.visualisationInputHandler  = nil
        audioIO?.visualisationOutputHandler = nil
        inputAnalyser  = nil
        outputAnalyser = nil

        audioIO?.stop()
        audioIO = nil
        tts.audioIO = nil

        turnController.reset()

        turnPhase = .inactive
        state = .idle
        lastSkillInfo = nil
        liveProgressHeadline = nil
        liveCaption = ""
        inputLevel = 0
        statusMessage = liveStrings.ended
        await liveActivity.endSession()
        backgroundContinuation.end(success: true)
        print("[Live] Stopped")
    }

    // MARK: - Pipecat-style Interruption

    private func beginPendingInterruptionIfNeeded() {
        guard pendingInterruption == nil else { return }
        cancelIncompleteTurnFollowUp()
        pendingInterruption = PendingInterruption()
        liveCaption = ""
        asr.beginStreaming()
    }

    private func beginCurrentTurnPreview() {
        guard pendingInterruption == nil else { return }
        isPreviewingCurrentTurn = true
        liveCaption = ""
        asr.beginStreaming()
    }

    private func handleCurrentTurnSpeechChunk(_ chunk: [Float]) {
        guard isPreviewingCurrentTurn else { return }

        let result = asr.appendStreaming(samples: chunk)
        guard !result.text.isEmpty else { return }
        liveCaption = result.text
    }

    private func handleInterruptionSpeechChunk(_ chunk: [Float]) {
        guard pendingInterruption != nil else { return }

        let result = asr.appendStreaming(samples: chunk)
        pendingInterruption?.transcript = result.text
        pendingInterruption?.unitCount = result.unitCount
        if !result.text.isEmpty {
            liveCaption = result.text
        }

        guard shouldPromotePendingInterruption(
            transcript: result.text,
            unitCount: result.unitCount
        ) else {
            return
        }

        promotePendingInterruptionToUserTurn()
    }

    @discardableResult
    private func finalizePendingInterruptionIfNeeded(with samples: [Float]) -> Bool {
        guard pendingInterruption != nil else { return false }

        let result = asr.endStreaming()
        pendingInterruption?.transcript = result.text
        pendingInterruption?.unitCount = result.unitCount

        let shouldPromote = shouldPromotePendingInterruption(
            transcript: result.text,
            unitCount: result.unitCount
        )

        if shouldPromote {
            promotePendingInterruptionToUserTurn()
            turnController.handleSpeechEnd(samples: samples)
            return true
        }

        clearPendingInterruption()
        return turnPhase == .processing || turnPhase == .speaking || turnPhase == .inactive
    }

    private func finalizeCurrentTurnPreview() {
        guard isPreviewingCurrentTurn else { return }
        let result = asr.endStreaming()
        if !result.text.isEmpty {
            liveCaption = result.text
        }
        isPreviewingCurrentTurn = false
    }

    private func cancelCurrentTurnPreview() {
        guard isPreviewingCurrentTurn else { return }
        asr.cancelStreaming()
        isPreviewingCurrentTurn = false
    }

    private func shouldPromotePendingInterruption(transcript: String, unitCount: Int) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let minimumUnits = isAssistantTurnActive ? minInterruptionUnitsWhileAssistantActive : 1
        return unitCount >= minimumUnits
    }

    private func promotePendingInterruptionToUserTurn() {
        let transcript = pendingInterruption?.transcript ?? ""
        clearPendingInterruption()

        turnGeneration &+= 1
        turnController.reset()
        turnController.handleSpeechStart()
        turnPhase = .recording
        state = .recording

        stopSynthesisPipeline()

        if transcript.isEmpty {
            print("[Live] ⚡ Barge-in — user turn started")
        } else {
            print("[Live] ⚡ Barge-in — user turn started: \"\(transcript)\"")
        }

        Task { [weak self] in
            guard let self else { return }
            await self.ttsQueue?.reset()
            self.inference?.cancel()
        }
    }

    private func clearPendingInterruption() {
        pendingInterruption = nil
        asr.cancelStreaming()
    }

    private var isAssistantTurnActive: Bool {
        turnPhase == .processing || turnPhase == .speaking
    }

    private func cancelIncompleteTurnFollowUp() {
        incompleteTurnTimeoutTask?.cancel()
        incompleteTurnTimeoutTask = nil
    }

    func appendLiveHistory(role: ChatMessage.Role, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        liveHistory.append(ChatMessage(role: role, content: trimmed))
        if liveHistory.count > maxLiveHistoryDepth {
            liveHistory.removeFirst(liveHistory.count - maxLiveHistoryDepth)
        }
    }

    private func scheduleIncompleteTurnFollowUp(
        type: LiveIncompleteTurnType,
        transcript: String,
        generation gen: UInt64
    ) {
        cancelIncompleteTurnFollowUp()

        incompleteTurnTimeoutTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: UInt64(type.timeout * 1_000_000_000))
            } catch {
                return
            }

            guard self.turnGeneration == gen,
                  self.turnPhase == .listening,
                  self.pendingInterruption == nil,
                  self.turnController.phase == .listening
            else {
                return
            }

            let followUp = await self.generateIncompleteTurnFollowUp(for: type, transcript: transcript)
            let cleaned = self.stripForTTS(followUp.spokenText)
            guard !cleaned.isEmpty,
                  self.turnGeneration == gen,
                  self.turnPhase == .listening
            else {
                return
            }

            let followUpGen = self.turnGeneration &+ 1
            self.turnGeneration = followUpGen
            self.turnPhase = .speaking
            self.state = .speaking
            self.statusMessage = self.liveStrings.speaking
            self.lastReply = cleaned
            await self.ttsQueue?.reset()
            await self.enqueueForPlayback(cleaned, generation: followUpGen)
            await self.ttsQueue?.waitUntilDone()

            guard self.turnGeneration == followUpGen, self.turnPhase == .speaking else { return }
            self.appendLiveHistory(role: .assistant, content: followUp.historyText)
            self.lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()
            self.turnPhase = .listening
            self.state = .listening
            self.statusMessage = self.liveStrings.listeningPrompt
            print("[Live] 👂 Listening...")
        }
    }

    private func generateIncompleteTurnFollowUp(
        for type: LiveIncompleteTurnType,
        transcript: String
    ) async -> (spokenText: String, historyText: String) {
        guard let inference, inference.isLoaded else {
            let fallback = fallbackIncompleteTurnFollowUp(for: type)
            return (fallback, "✓ \(fallback)")
        }

        let userMessage: String
        switch type {
        case .short:
            userMessage = "用户刚才那句大概率被打断了，几秒后请用一句很短的中文口语提醒他继续说。你必须输出 `✓` 加一个空格再接提醒正文，绝不能输出 `○` 或 `◐`。提醒只能一句，不要解释。用户刚才说的是：\(transcript)"
        case .long:
            userMessage = "用户刚才更像是在思考，稍等后请用一句很短的中文口语温和提醒他想好了再继续。你必须输出 `✓` 加一个空格再接提醒正文，绝不能输出 `○` 或 `◐`。提醒只能一句，不要解释。用户刚才说的是：\(transcript)"
        }

        let prompt = PromptBuilder.buildLiveVoiceUserPrompt(
            userTranscript: userMessage,
            locale: .zhCN,
            hasVision: false
        )

        var text = ""
        do {
            for try await token in inference.generateLive(prompt: prompt, images: [], audios: []) {
                text += token
                if text.count >= 48 {
                    inference.cancel()
                    break
                }
            }
        } catch {
            let fallback = fallbackIncompleteTurnFollowUp(for: type)
            return (fallback, "✓ \(fallback)")
        }

        var parser = LiveTurnCompletionParser()
        let parsed = parser.consume(text)
        let parsedSpoken = parsed.speakableText.isEmpty ? parser.finalizeWithoutMarker() : parsed.speakableText
        let spoken = OutputSanitizer.sanitizeFinal(parsedSpoken, mode: .liveVoice)

        if parser.sawCompleteMarker, !spoken.isEmpty {
            return (spoken, "✓ \(spoken)")
        }

        let cleaned = OutputSanitizer.sanitizeFinal(text, mode: .liveVoice)
        if !cleaned.isEmpty {
            return (cleaned, cleaned)
        }

        let fallback = fallbackIncompleteTurnFollowUp(for: type)
        return (fallback, "✓ \(fallback)")
    }

    private func fallbackIncompleteTurnFollowUp(for type: LiveIncompleteTurnType) -> String {
        switch type {
        case .short:
            return "你刚才那句还没说完，你继续说。"
        case .long:
            return "不着急，你想好了再继续说。"
        }
    }

    // MARK: - Active Generation Cleanup

    /// Full cleanup with await. Used by stop() and audio idle.
    /// Interruption path uses promotePendingInterruptionToUserTurn() instead,
    /// because that path must let the new user turn continue recording
    /// immediately while old assistant output is cancelled in the background.
    private func cancelActiveGeneration() async {
        turnGeneration &+= 1
        inference?.cancel()
        stopSynthesisPipeline()
        await ttsQueue?.flush()
        cancelCurrentTurnPreview()
        clearPendingInterruption()
        cancelIncompleteTurnFollowUp()
        inputLevel = 0
    }

    // MARK: - Synthesis Pipeline

    private func startSynthesisPipeline(generation gen: UInt64) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        synthesisPipeline = continuation
        synthesisTask = Task { [weak self] in
            for await text in stream {
                guard let self,
                      (self.turnPhase == .processing || self.turnPhase == .speaking),
                      self.turnGeneration == gen
                else { break }
                await self.enqueueForPlayback(text, generation: gen)
            }
        }
    }

    private func stopSynthesisPipeline() {
        synthesisPipeline?.finish()
        synthesisPipeline = nil
        synthesisTask?.cancel()
        synthesisTask = nil
    }

    // MARK: - Pipeline

    private func processAudio(_ samples: [Float], generation gen: UInt64) async {
        guard turnPhase == .processing, turnGeneration == gen else { return }
        state = .processing

        var metrics = LiveTurnMetrics(turnId: gen)
        metrics.turnConfirmedAt = CFAbsoluteTimeGetCurrent()
        metrics.speechSampleCount = samples.count
        currentTurnMetrics = metrics

        await ttsQueue?.reset()

        guard inference?.isLoaded == true else {
            print("[Live] ❌ LLM not loaded")
            guard turnPhase == .processing, turnGeneration == gen else { return }
            turnPhase = .listening
            state = .listening
            statusMessage = liveStrings.listeningPrompt
            await liveActivity.update(
                phase: "listening",
                headline: "PhoneClaw LIVE",
                detail: liveStrings.listeningPrompt
            )
            return
        }

        metrics.asrStartedAt = CFAbsoluteTimeGetCurrent()
        let transcript = await asr.transcribe(samples: samples)
        metrics.asrCompletedAt = CFAbsoluteTimeGetCurrent()
        let asrMs = metrics.asrLatency * 1000
        print("[Live] 📝 ASR (\(String(format: "%.0f", asrMs))ms): \"\(transcript)\"")

        guard !transcript.isEmpty else {
            print("[Live] (empty transcript, skipping)")
            guard turnPhase == .processing, turnGeneration == gen else { return }
            cancelCurrentTurnPreview()
            turnPhase = .listening
            state = .listening
            liveCaption = ""
            statusMessage = liveStrings.listeningPrompt
            await liveActivity.update(
                phase: "listening",
                headline: "PhoneClaw LIVE",
                detail: liveStrings.listeningPrompt
            )
            return
        }

        lastTranscript = transcript
        liveCaption = transcript
        await liveActivity.update(
            phase: "processing",
            headline: "正在理解",
            detail: transcript
        )
        backgroundContinuation.update(phase: "processing", detail: transcript)

        guard agentEngine != nil else {
            print("[LiveAgent] ❌ missing MAIN AgentEngine during ASR turn")
            turnPhase = .listening
            state = .listening
            statusMessage = liveStrings.listeningPrompt
            await liveActivity.update(
                phase: "listening",
                headline: "PhoneClaw LIVE",
                detail: liveStrings.listeningPrompt
            )
            return
        }

        await processMainAgentTextTurn(
            transcript: transcript,
            generation: gen,
            initialMetrics: metrics
        )
    }

    private func observeLiveActivityDismissal() {
        cancelLiveActivityDismissalObservation()
        liveActivityDismissalTask = Task { [weak self] in
            guard let self else { return }
            let dismissed = await self.liveActivity.waitForDismissal()
            guard dismissed, !Task.isCancelled else { return }
            await self.stopFromLiveActivityDismissal()
        }
    }

    private func cancelLiveActivityDismissalObservation() {
        liveActivityDismissalTask?.cancel()
        liveActivityDismissalTask = nil
    }

    @MainActor
    private func stopFromLiveActivityDismissal() async {
        guard turnPhase != .inactive, turnPhase != .stopping else { return }
        endedByLiveActivityDismissal = true
        print("[LiveActivity] user dismissed Dynamic Island; stopping LIVE")
        await stopLegacy()
    }

    private func cancelLiveActivityListeningRefresh() {
        liveActivityListeningRefreshTask?.cancel()
        liveActivityListeningRefreshTask = nil
    }

    func scheduleLiveActivityListeningRefresh(afterResultGeneration gen: UInt64) {
        cancelLiveActivityListeningRefresh()
        liveActivityListeningRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self else { return }
            guard self.turnPhase == .listening, self.turnGeneration == gen else { return }
            await self.liveActivity.update(
                phase: "listening",
                headline: "PhoneClaw LIVE",
                detail: self.liveStrings.listeningPrompt
            )
            self.backgroundContinuation.update(phase: "listening", detail: self.liveStrings.listeningPrompt)
        }
    }


}
