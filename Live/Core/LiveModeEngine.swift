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

    private enum TurnPhase {
        case inactive
        case starting
        case listening
        case recording
        case processing
        case speaking
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var lastTranscript: String = ""
    private(set) var lastReply: String = ""
    private(set) var liveCaption: String = ""
    private(set) var inputLevel: Double = 0
    private(set) var statusMessage: String = "等待启动"

    /// 可视化音频分析器（由 OrbSceneView 弱引用）
    /// start() 前为 nil，stop() 后清零。@Observable 无需额外通知机制。
    private(set) var inputAnalyser:  OrbAudioAnalyser? = nil
    private(set) var outputAnalyser: OrbAudioAnalyser? = nil

    private let vad = VADService()
    private let tts = TTSService()
    private let asr = ASRService()
    private var audioIO: LiveAudioIO?
    private var ttsQueue: AudioPlaybackQueue?
    private weak var inference: (any InferenceService)?

    private var turnPhase: TurnPhase = .inactive
    private var turnGeneration: UInt64 = 0

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

    // MARK: - Echo Suppression

    /// Timestamp when the last assistant playback finished.
    /// Used for diagnostics and potential future echo-window gating.
    private var lastAssistantPlaybackEndTime: CFAbsoluteTime = 0

    // MARK: - Metrics

    /// Shared reference so enqueueForPlayback can stamp ttsFirstChunkAt
    /// on the same metrics struct that processAudio prints.
    private var currentTurnMetrics: LiveTurnMetrics?

    // MARK: - Incomplete Turn Follow-up

    private var incompleteTurnTimeoutTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// 摄像头帧提供器，由 UI 层注入。Engine 不直接依赖 LiveCameraService。
    var frameProvider: (() -> CIImage?)?

    /// 通知 engine 摄像头状态变化，engine 向 conversation 发一条系统事件消息.
    /// 让模型知道当前能否看到画面，防止基于旧 KV cache 幻觉.
    func notifyCameraStateChanged(isOn: Bool) {
        guard let inference else { return }
        let msg = isOn
            ? "(系统通知：用户已开启摄像头，你现在可以看到画面了)"
            : "(系统通知：用户已关闭摄像头，你现在无法看到任何画面。如果用户问你看到什么，告诉他需要先开启摄像头)"
        print("[Live] 📷 Camera state → \(isOn ? "ON" : "OFF"), injecting system event")
        // prompt prefill 后立即 cancel, 只保留 KV cache 上下文, 不浪费 decode 计算
        Task {
            let t0 = CFAbsoluteTimeGetCurrent()
            for try await _ in inference.generateLive(prompt: msg, images: [], audios: []) {
                // 首个 token 说明 prefill 完成, 立即 cancel 停止 decode
                inference.cancel()
                let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                print("[Live] 📷 Camera event prefilled & cancelled in \(ms)ms (saved ~2s decode)")
                break
            }
        }
    }

    private var liveLocaleConfig: LiveLocaleConfig { LiveLocale.zhCN.config }
    private var liveStrings: LiveLocaleConfig.StatusStrings { liveLocaleConfig.statusStrings }

    func setup(inference: InferenceService) {
        self.inference = inference
    }

    /// 调用方注入的用户 SYSPROMPT.md 内容（来自 AgentEngine.config.systemPrompt）。
    /// Phase 1 起 Live 不再读取这份通用 system prompt；先保留注入口，避免接口变化。
    var userSystemPrompt: String?

    func start() async {
        await startLegacy()
    }

    // MARK: - Legacy path (only path)

    @MainActor
    private func startLegacy() async {
        guard turnPhase == .inactive else { return }
        turnPhase = .starting
        state = .listening
        statusMessage = liveStrings.preparingLive
        print("[Live] Starting (legacy)...")

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

        asr.initialize()
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
            self.cancelIncompleteTurnFollowUp()
            self.beginCurrentTurnPreview()
            self.lastTranscript = ""
            self.lastReply = ""
            self.liveCaption = ""
            self.turnPhase = .recording
            self.state = .recording
            self.statusMessage = self.liveStrings.recording
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

        let liveSystemPrompt = PromptBuilder.buildLiveVoiceSystemPrompt(
            userSystemPrompt: userSystemPrompt,
            locale: .zhCN
        )

        do {
            // 双保险: API systemMessage (E4B 可能支持) + 嵌入首条 user message (E2B 需要)
            try await inference.enterLiveMode(systemPrompt: liveSystemPrompt)
        } catch {
            print("[Live] ❌ Failed to enter Live conversation: \(error)")
            turnPhase = .inactive
            state = .idle
            statusMessage = liveStrings.initializationFailed
            return
        }

        // 2. 用 Live conversation 生成一句简短开场白
        //    把 system prompt 嵌入第一条 user message, 确保模型看到指令
        var greetingText = ""
        let greetingUserText = liveLocaleConfig.greetingPrompt
        let greetingPrompt = """
        【系统指令】
        \(liveSystemPrompt)

        【用户】
        \(greetingUserText)
        """
        let t0 = CFAbsoluteTimeGetCurrent()
        let stream = inference.generateLive(prompt: greetingPrompt, images: [], audios: [])
        do {
            for try await token in stream {
                greetingText += token
            }
        } catch {}
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[Live] 🎤 Greeting generated in \(Int(ms))ms: \"\(greetingText.prefix(80))\"")

        guard turnPhase == .starting else { return }

        // 3. 解析 marker + 清理输出, TTS 播报
        let cleaned = OutputSanitizer.sanitizeFinal(greetingText, mode: .liveVoice)
        let spoken: String
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spoken = liveStrings.listeningPrompt + "。"
        } else {
            // 去掉 marker (✓/○/◐) 前缀 — 兼容有无空格: "✓ 哈喽" 和 "✓哈喽"
            var text = cleaned
            for marker in ["✓", "○", "◐"] {
                if text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count))
                    if text.hasPrefix(" ") { text = String(text.dropFirst()) }
                    break
                }
            }
            spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // TTS: 先合成 (orb 暗), 合成完成后播放 (orb 在 playerNode.play 时亮起)
        print("[TTS] 🔊 [greeting] \"\(spoken.prefix(40))\"")

        // 用 onPlaybackStarted 回调精准触发 orb 亮起 —
        // 在 playerNode.play() 调用时触发, 不是合成完就亮
        let playbackStartT0 = CFAbsoluteTimeGetCurrent()
        audioIO?.onPlaybackStarted = { [weak self] in
            let stateT = CFAbsoluteTimeGetCurrent()
            self?.turnPhase = .speaking
            self?.state = .speaking
            self?.statusMessage = ""
            print("[Live] 🔆 Orb bright at playback start (Δ\(Int((stateT - playbackStartT0) * 1000))ms from synth start)")
        }

        if let wavData = tts.synthesize(spoken) {
            await tts.playWAV(wavData)
        } else {
            turnPhase = .speaking
            state = .speaking
            statusMessage = ""
            await tts.speakSystem(spoken)
        }

        // 清理回调
        audioIO?.onPlaybackStarted = nil
        lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()

        // 4. conversation 已有 context (system + greeting)，后续 turn 直接复用
        guard turnPhase == .speaking else { return }

        turnPhase = .listening
        state = .listening
        inputLevel = 0
        statusMessage = liveStrings.listeningPrompt
        await vad.startListening(audioIO: io)
    }

    func stop() async {
        await stopLegacy()
    }

    @MainActor
    private func stopLegacy() async {
        guard turnPhase != .stopping, turnPhase != .inactive else { return }
        turnPhase = .stopping

        vad.stopListening()
        await cancelActiveGeneration()

        await inference?.exitLiveMode()

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
        liveCaption = ""
        inputLevel = 0
        statusMessage = liveStrings.ended
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

    private func appendLiveHistory(role: ChatMessage.Role, content: String) {
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

        // Initialize metrics (shared via currentTurnMetrics for TTS timestamp)
        var metrics = LiveTurnMetrics(turnId: gen)
        metrics.turnConfirmedAt = CFAbsoluteTimeGetCurrent()
        metrics.speechSampleCount = samples.count
        currentTurnMetrics = metrics

        await ttsQueue?.reset()

        guard let inference, inference.isLoaded else {
            print("[Live] ❌ LLM not loaded")
            guard turnPhase == .processing, turnGeneration == gen else { return }
            turnPhase = .listening
            state = .listening
            // VAD is already running (not stopped on turn confirm) — no restart needed
            return
        }

        // VAD stays running throughout — no startListening() here.
        // It was started once in start() and never stopped during a turn.

        // Step 1: ASR
        metrics.asrStartedAt = CFAbsoluteTimeGetCurrent()
        let transcript = asr.transcribe(samples: samples)
        metrics.asrCompletedAt = CFAbsoluteTimeGetCurrent()
        let asrMs = metrics.asrLatency * 1000
        print("[Live] 📝 ASR (\(String(format: "%.0f", asrMs))ms): \"\(transcript)\"")

        guard !transcript.isEmpty else {
            print("[Live] (empty transcript, skipping)")
            guard turnPhase == .processing, turnGeneration == gen else { return }
            // Clean up preview session that was opened at speechStart
            cancelCurrentTurnPreview()
            turnPhase = .listening
            state = .listening
            liveCaption = ""
            statusMessage = liveStrings.listeningPrompt
            return
        }
        lastTranscript = transcript
        liveCaption = transcript

        guard turnPhase == .processing, turnGeneration == gen else { return }

        // Step 2: LLM streaming with context
        // Vision 实测内存特征 (真机 2026-04-16, E2B + chat path + 单 placeholder):
        //   Turn 1 vision: footprint 4281 → 4756 (spike +475 MB)
        //   全程 footprint < 5054, 离 jetsam 6144 还有 1090 MB 余量, 从未崩.
        //
        // 阈值按模型分级:
        //   E2B: 500 MB. baseline ~4.3 GB, headroom 通常 1-2 GB, 阈值 500 让 vision
        //        几乎总能触发, 同时给 spike +500 留 margin (5644+500=6144=jetsam).
        //   E4B: 100 MB. baseline ~5.8 GB (权重 4 GB + Live runtime ~1.8 GB),
        //        headroom 经常只有 200-400 MB. 阈值 500 会一直 skip vision —
        //        用户感知"看不到图". 100 MB 算激进 (margin 紧), trade-off:
        //        宁可偶尔崩重启, 也比永远看不到图体验好. 长期解法是 Live + 摄像头
        //        强制切 E2B, 这里先按真机当前模型做差异阈值.
        let visionHeadroomThreshold: Int = 500  // TODO: per-model tuning via catalog
        let currentHeadroom = MemoryStats.headroomMB
        var frame: CIImage? = nil
        if frameProvider != nil {
            if currentHeadroom >= visionHeadroomThreshold {
                frame = frameProvider?()
                if frame == nil {
                    print("[Live] 📷 frameProvider returned nil (camera not ready?)")
                } else {
                    let ext = frame!.extent
                    print("[Live] 📷 captured frame \(Int(ext.width))x\(Int(ext.height)), headroom=\(currentHeadroom) MB")
                }
            } else {
                print("[Live] ⚠️ Skipping camera frame — headroom \(currentHeadroom) MB < \(visionHeadroomThreshold) MB threshold")
                liveCaption = "内存不足，已跳过画面识别"
            }
        } else {
            print("[Live] 📷 frameProvider is nil")
        }

        // ── 单轮处理: 委托给 LiveTurnProcessor ──────────────────────────
        //
        // Live 进入时已打开 persistent multimodal conversation，并把一次性
        // system prompt 注入 conversation config。这里每轮只发送新的 user 文本
        // 与可选画面；历史上下文和 KV cache 由 conversation 自己维护。
        //
        // LiveTurnProcessor 负责把 transcript/frame 变成本轮 payload，并把输出
        // token 流解析成 LiveOutputEvent (marker / speechToken / done / 预留
        // skillCall / skillResult)。
        let processor = LiveTurnProcessor(inference: inference)
        processor.enableSkillInvocation = false   // 阶段 1 MVP, 阶段 3 再打开

        metrics.llmStartedAt = CFAbsoluteTimeGetCurrent()
        startSynthesisPipeline(generation: gen)

        var rawBuffer = ""
        var sentenceBuffer = ""
        var sanitizer = StreamingSanitizer(mode: .liveVoice)
        var incompleteType: LiveIncompleteTurnType?
        var sawCompleteMarker = false    // ✓ marker 是否实际出现, 影响历史拼接前缀
        var isFirstToken = true
        var isFirstSentence = true

        let eventStream = processor.processTurn(
            transcript: transcript,
            frame: frame
        )

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw CancellationError()
                }
                // 整个 event loop 挂 @MainActor — 每次 `await` 期间 main actor
                // 可以处理 SwiftUI body redraw, lastReply 写入后能当帧看到.
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    for try await event in eventStream {
                        guard self.turnPhase == .processing, self.turnGeneration == gen else { break }

                        switch event {
                        case .marker(let marker):
                            if isFirstToken {
                                metrics.llmFirstTokenAt = CFAbsoluteTimeGetCurrent()
                                isFirstToken = false
                            }
                            switch marker {
                            case .complete:
                                sawCompleteMarker = true   // ✓, 继续接 speechToken 作为正常回答
                            case .interrupted:
                                incompleteType = .short
                                self.inference?.cancel()
                            case .thinking:
                                incompleteType = .long
                                self.inference?.cancel()
                            }

                        case .speechToken(let delta):
                            if isFirstToken {
                                metrics.llmFirstTokenAt = CFAbsoluteTimeGetCurrent()
                                isFirstToken = false
                            }
                            metrics.tokenCount += 1
                            rawBuffer += delta
                            self.lastReply = OutputSanitizer.sanitizeFinal(rawBuffer, mode: .liveVoice)
                            let sanitized = sanitizer.feed(rawBuffer)
                            guard !sanitized.isEmpty else { continue }

                            sentenceBuffer += sanitized
                            let (sentences, remainder) = self.extractSpeakableSegments(from: sentenceBuffer)
                            sentenceBuffer = remainder

                            for s in sentences where !s.isEmpty {
                                guard self.turnPhase == .processing, self.turnGeneration == gen else { break }
                                if isFirstSentence {
                                    metrics.firstSentenceAt = CFAbsoluteTimeGetCurrent()
                                    isFirstSentence = false
                                }
                                self.synthesisPipeline?.yield(s)
                            }

                        case .skillCall(let call):
                            // 阶段 1 MVP 不应触发 (enableSkillInvocation=false).
                            // 现在 Live prompt 已经不再继承 Chat 的工具协议文案；这里
                            // 仍保留兜底, 防止模型偶发产出控制块.
                            // Fallback: 朗读简短歉意, 不进 history.
                            // 阶段 3 实装: 这里调 toolRegistry.execute(call), 再启第二轮 LLM 总结.
                            print("[Live] ⚠️ unexpected tool_call in MVP: \(call.name)")
                            let fallback = processor.fallbackUtterance
                            self.lastReply = fallback
                            sentenceBuffer = ""
                            rawBuffer = fallback   // 防 history append 时 lastReply 是空导致 history 不记 turn
                            self.synthesisPipeline?.yield(fallback)
                            self.inference?.cancel()

                        case .skillResult(let summary):
                            // 同上, 阶段 3 才会触发 — 第二轮 LLM 对工具结果的口语总结.
                            print("[Live] ⚠️ unexpected skill result: \(summary.prefix(40))")

                        case .done:
                            break
                        }
                    }

                    // 流结束, flush sanitizer 残余 (只在完整轮 — incomplete turn 不朗读)
                    if self.turnPhase == .processing, self.turnGeneration == gen, incompleteType == nil {
                        let remaining = sanitizer.finalize(rawBuffer)
                        sentenceBuffer += remaining
                        let trimmed = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            if isFirstSentence {
                                metrics.firstSentenceAt = CFAbsoluteTimeGetCurrent()
                            }
                            self.synthesisPipeline?.yield(trimmed)
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            print("[Live] ⏱ LLM timeout (15s)")
        } catch {
            print("[Live] ❌ LLM error: \(error)")
        }

        metrics.llmCompletedAt = CFAbsoluteTimeGetCurrent()
        synthesisPipeline?.finish()
        await synthesisTask?.value
        synthesisTask = nil

        if let incompleteType {
            currentTurnMetrics = nil
            lastReply = ""

            guard turnPhase == .processing, turnGeneration == gen else {
                metrics.interrupted = true
                print(metrics.summary())
                return
            }

            let marker = String(incompleteType.marker)
            print("[Live] \(marker) Incomplete user turn — suppressing assistant reply")
            appendLiveHistory(role: .user, content: transcript)
            appendLiveHistory(role: .assistant, content: marker)

            turnPhase = .listening
            state = .listening
            statusMessage = liveStrings.listeningPrompt
            scheduleIncompleteTurnFollowUp(type: incompleteType, transcript: transcript, generation: gen)
            print("[Live] 👂 Listening...")
            return
        }

        lastReply = OutputSanitizer.sanitizeFinal(rawBuffer, mode: .liveVoice)
        print("[Live] 💬 Reply: \"\(lastReply.prefix(60))\"")

        guard turnPhase == .processing, turnGeneration == gen else {
            metrics.interrupted = true
            currentTurnMetrics = nil
            print(metrics.summary())
            return
        }
        turnPhase = .speaking
        state = .speaking
        statusMessage = liveStrings.speaking
        await ttsQueue?.waitUntilDone()

        // Sync TTS timestamp from shared metrics (set by enqueueForPlayback)
        if let shared = currentTurnMetrics {
            metrics.ttsFirstChunkAt = shared.ttsFirstChunkAt
        }
        currentTurnMetrics = nil

        // Final guard BEFORE updating history/metrics — don't commit interrupted turns
        guard turnPhase == .speaking, turnGeneration == gen else {
            metrics.interrupted = true
            print(metrics.summary())
            return
        }

        // Only commit to history if turn completed without interruption
        if !transcript.isEmpty && !lastReply.isEmpty {
            appendLiveHistory(role: .user, content: transcript)
            let assistantHistory = sawCompleteMarker ? "✓ \(lastReply)" : lastReply
            appendLiveHistory(role: .assistant, content: assistantHistory)
        }

        // Print metrics (uninterrupted turn)
        print(metrics.summary())

        lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()
        turnPhase = .listening
        state = .listening
        statusMessage = liveStrings.listeningPrompt
        inputLevel = 0
        print("[Live] 👂 Listening...")
    }

    // MARK: - Playback Enqueue

    private func enqueueForPlayback(_ text: String, generation gen: UInt64) async {
        let cleaned = stripForTTS(text)
        guard !cleaned.isEmpty else { return }

        // Generation guard: don't enqueue if this turn has been superseded
        guard turnGeneration == gen else { return }

        if tts.backend == "sherpa-onnx" {
            let wavData: Data? = await withTaskGroup(of: Data?.self) { group in
                group.addTask { [tts] in tts.synthesize(cleaned) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    return nil as Data?
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let wavData else {
                print("[Live] ⏱ TTS timeout or empty for: \"\(cleaned.prefix(20))\"")
                return
            }

            // Post-synthesis generation guard: stale turn's audio must not enter new turn's queue
            guard turnGeneration == gen else { return }

            // TTS first chunk metric: stamped AFTER synthesis, not before
            if currentTurnMetrics != nil && currentTurnMetrics!.ttsFirstChunkAt == 0 {
                currentTurnMetrics!.ttsFirstChunkAt = CFAbsoluteTimeGetCurrent()
            }

            await ttsQueue?.enqueueWAV(wavData)
        } else {
            guard turnGeneration == gen else { return }
            if currentTurnMetrics != nil && currentTurnMetrics!.ttsFirstChunkAt == 0 {
                currentTurnMetrics!.ttsFirstChunkAt = CFAbsoluteTimeGetCurrent()
            }
            await ttsQueue?.enqueueSystemSpeak(cleaned)
        }
    }

    private func stripForTTS(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "#", with: "")
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "（", with: "")
        s = s.replacingOccurrences(of: "）", with: "")
        s = s.replacingOccurrences(of: "(", with: "")
        s = s.replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: "：", with: "，")
        s = s.replacingOccurrences(of: ":", with: "，")
        s = s.replacingOccurrences(of: "- ", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Speakable Segment Extraction

    private func extractSpeakableSegments(from buffer: String) -> (segments: [String], remainder: String) {
        var segments: [String] = []
        var lastSplit = buffer.startIndex

        let hardChinesePunctuation: Set<Character> = ["。", "！", "？", "；"]
        let softChinesePunctuation: Set<Character> = ["，", "、", "："]
        let hardEnglishPunctuation: Set<Character> = [".", "!", "?", ";"]
        let softEnglishPunctuation: Set<Character> = [",", ":"]
        // minSoftClauseLength: 5 (was 8). 更激进地切逗号 → 首段 chunk 更小 →
        // TTS 合成更快出第一段音频 → TTFS 从 ~2.6s 降到 ~0.8s.
        // 5 个汉字对应约 2-3 个词, 仍然是自然的语调停顿点.
        let minSoftClauseLength = 5

        var i = buffer.startIndex
        while i < buffer.endIndex {
            let ch = buffer[i]
            let nextIdx = buffer.index(after: i)

            var isSplit = false

            if hardChinesePunctuation.contains(ch) || ch == "\n" {
                isSplit = true
            } else if softChinesePunctuation.contains(ch) || softEnglishPunctuation.contains(ch) {
                let clause = String(buffer[lastSplit..<nextIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                isSplit = clause.count >= minSoftClauseLength
            } else if hardEnglishPunctuation.contains(ch) && nextIdx < buffer.endIndex {
                let next = buffer[nextIdx]
                if next == " " || next == "\n" {
                    let clause = String(buffer[lastSplit..<nextIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    isSplit = clause.count >= minSoftClauseLength
                }
            } else if hardEnglishPunctuation.contains(ch) && nextIdx == buffer.endIndex {
                isSplit = true
            }

            if isSplit {
                let segmentEnd = nextIdx
                let segment = String(buffer[lastSplit..<segmentEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !segment.isEmpty {
                    segments.append(segment)
                    lastSplit = segmentEnd
                }
            }

            i = nextIdx
        }

        let remainder = String(buffer[lastSplit...])
        return (segments, remainder)
    }
}
