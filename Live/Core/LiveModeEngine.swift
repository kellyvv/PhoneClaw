import Foundation
import AVFoundation
import CoreImage
import MLXLMCommon

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
    private weak var llm: MLXLocalLLMService?

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

    func setup(llm: MLXLocalLLMService) {
        self.llm = llm
    }

    /// 调用方注入的用户 SYSPROMPT.md 内容（来自 AgentEngine.config.systemPrompt）。
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
        statusMessage = "正在准备 Live"
        print("[Live] Starting (legacy)...")

        let io = LiveAudioIO()
        do {
            try io.start()
        } catch {
            print("[Live] ❌ Audio engine error: \(error)")
            turnPhase = .inactive
            state = .idle
            statusMessage = "音频引擎启动失败"
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
            statusMessage = "VAD 不可用"
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
            self.statusMessage = "正在听你说"
            print("[Live] 🎤 Recording...")
        }

        turnController.onTurnConfirmed = { [weak self] samples in
            guard let self else { return }
            self.finalizeCurrentTurnPreview()
            self.turnGeneration &+= 1
            self.turnPhase = .processing
            self.state = .processing
            self.statusMessage = "正在理解"
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
            self.statusMessage = "我在听，请说话"
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
                self.statusMessage = "我在听，请说话"
            }
        }

        // Announce then listen, with concurrent LLM warmup
        turnPhase = .speaking
        state = .speaking

        // Kick off LLM shader warmup concurrently with TTS greeting.
        // Only for small models (E2B) where warmup is safe; E4B skips due to OOM risk.
        let warmupTask: Task<Void, Never>? = {
            guard let llm = self.llm,
                  llm.loadedModelID?.contains("e2b") == true else { return nil }
            return Task {
                let t0 = CFAbsoluteTimeGetCurrent()
                let stream = llm.generateStream(prompt: "你好")
                do {
                    for try await _ in stream {
                        break  // 1 token is enough to compile shaders
                    }
                } catch {}
                llm.cancel()
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                print("[Live] ⚡ LLM warmup done in \(Int(ms))ms")
            }
        }()

        await tts.speak("我在听，请说话。")
        lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()

        // Wait for warmup if it's still running (usually finishes before TTS)
        await warmupTask?.value

        guard turnPhase == .speaking else { return }

        turnPhase = .listening
        state = .listening
        inputLevel = 0
        statusMessage = "我在听，请说话"
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
        statusMessage = "Live 已结束"
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
            self.llm?.cancel()
        }
    }

    private func clearPendingInterruption() {
        pendingInterruption = nil
        asr.cancelStreaming()
    }

    private var isAssistantTurnActive: Bool {
        turnPhase == .processing || turnPhase == .speaking
    }

    private func liveVoiceSystemPrompt() -> String {
        PromptBuilder.defaultSystemPrompt + """
        你正在进行实时语音对话，必须先判断用户这句话在对话上是否已经说完整。若已经完整，第一字符必须输出 `✓`，后面紧跟一个空格和你的正常回答；若用户像是被打断、几秒内还会继续，只输出 `○`；若用户像是在思考、需要更久，只输出 `◐`。`○` 和 `◐` 后面绝对不能再输出任何字。正常回答时用纯中文口语，根据用户意图决定详略：默认简短（一两句），当用户要求"详细""展开""多说一点"等时可以展开，但始终保持口语化、多用中文逗号句号，禁止英文和 markdown 符号。你叫手机龙虾。
        """
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
            self.statusMessage = "正在回答"
            self.lastReply = cleaned
            await self.ttsQueue?.reset()
            await self.enqueueForPlayback(cleaned, generation: followUpGen)
            await self.ttsQueue?.waitUntilDone()

            guard self.turnGeneration == followUpGen, self.turnPhase == .speaking else { return }
            self.appendLiveHistory(role: .assistant, content: followUp.historyText)
            self.lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()
            self.turnPhase = .listening
            self.state = .listening
            self.statusMessage = "我在听，请说话"
            print("[Live] 👂 Listening...")
        }
    }

    private func generateIncompleteTurnFollowUp(
        for type: LiveIncompleteTurnType,
        transcript: String
    ) async -> (spokenText: String, historyText: String) {
        guard let llm, llm.isLoaded else {
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

        let prompt = PromptBuilder.buildLightweightTextPrompt(
            userMessage: userMessage,
            history: liveHistory,
            systemPrompt: PromptBuilder.defaultSystemPrompt + " 你正在语音模式，只能输出一句简短自然的中文口语提醒，不要列表，不要英文，不要 markdown。必须用 `✓` 开头。"
        )

        var text = ""
        do {
            for try await token in llm.generateStream(prompt: prompt, images: [], audios: []) {
                text += token
                if text.count >= 48 {
                    llm.cancel()
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
        llm?.cancel()
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

        guard let llm, llm.isLoaded else {
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
            statusMessage = "我在听，请说话"
            return
        }
        lastTranscript = transcript
        liveCaption = transcript

        guard turnPhase == .processing, turnGeneration == gen else { return }

        // Step 2: LLM streaming with context
        // Vision 需要额外 ~500-800MB，headroom 不足时主动跳过图片，避免 jetsam 闪退
        let visionHeadroomThreshold = 2000 // MB
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
            print("[Live] 📷 frameProvider is nil — camera button not pressed, or UI hook-up broken")
        }
        var liveHint = "\n[语音模式] 回答会被朗读出来。用纯中文口语回答，根据用户意图决定详略（默认简短，用户明确要求详细/展开时可多说几句），禁止英文和markdown符号。多用中文逗号和句号，方便语音自然分段播放。不要在回答开头自报名字。"
        if frame != nil {
            liveHint += "\n用户通过摄像头分享了当前画面，如果问题和画面有关请结合画面内容回答。"
        }
        let prompt = PromptBuilder.buildLightweightTextPrompt(
            userMessage: transcript + liveHint,
            history: liveHistory,
            systemPrompt: liveVoiceSystemPrompt(),
            enableThinking: false,
            historyDepth: maxLiveHistoryDepth
        )

        metrics.llmStartedAt = CFAbsoluteTimeGetCurrent()
        startSynthesisPipeline(generation: gen)

        var rawBuffer = ""
        var sentenceBuffer = ""
        var sanitizer = StreamingSanitizer(mode: .liveVoice)
        var completionParser = LiveTurnCompletionParser()
        var incompleteType: LiveIncompleteTurnType?
        var isFirstToken = true
        var isFirstSentence = true
        let images: [CIImage] = frame.map { [$0] } ?? []
        let stream = llm.generateStream(prompt: prompt, images: images, audios: [])

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw CancellationError()
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    for try await token in stream {
                        guard self.turnPhase == .processing, self.turnGeneration == gen else { break }

                        if isFirstToken {
                            metrics.llmFirstTokenAt = CFAbsoluteTimeGetCurrent()
                            isFirstToken = false
                        }
                        metrics.tokenCount += 1

                        let parseResult = completionParser.consume(token)
                        if let detectedIncompleteType = parseResult.incompleteType {
                            incompleteType = detectedIncompleteType
                            self.llm?.cancel()
                            break
                        }

                        guard !parseResult.speakableText.isEmpty else { continue }

                        rawBuffer += parseResult.speakableText
                        self.lastReply = OutputSanitizer.sanitizeFinal(rawBuffer, mode: .liveVoice)
                        let delta = sanitizer.feed(rawBuffer)
                        guard !delta.isEmpty else { continue }

                        sentenceBuffer += delta
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
                    }

                    if self.turnPhase == .processing, self.turnGeneration == gen, incompleteType == nil {
                        let markerFallback = completionParser.finalizeWithoutMarker()
                        if !markerFallback.isEmpty {
                            rawBuffer += markerFallback
                            let delta = sanitizer.feed(rawBuffer)
                            if !delta.isEmpty {
                                sentenceBuffer += delta
                                let (sentences, remainder) = self.extractSpeakableSegments(from: sentenceBuffer)
                                sentenceBuffer = remainder
                                for s in sentences where !s.isEmpty {
                                    if isFirstSentence {
                                        metrics.firstSentenceAt = CFAbsoluteTimeGetCurrent()
                                        isFirstSentence = false
                                    }
                                    self.synthesisPipeline?.yield(s)
                                }
                            }
                        }

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
            statusMessage = "我在听，请说话"
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
        statusMessage = "正在回答"
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
            let assistantHistory = completionParser.sawCompleteMarker ? "✓ \(lastReply)" : lastReply
            appendLiveHistory(role: .assistant, content: assistantHistory)
        }

        // Print metrics (uninterrupted turn)
        print(metrics.summary())

        lastAssistantPlaybackEndTime = CFAbsoluteTimeGetCurrent()
        turnPhase = .listening
        state = .listening
        statusMessage = "我在听，请说话"
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
        let minSoftClauseLength = 8

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
