import Foundation

@MainActor
final class LiveLandVoiceRuntime {
    private static let shortPromptDwell: Duration = .milliseconds(2500)
    private static let resultDwell: Duration = .seconds(12)
    private static let acceptedPromptDelay: Duration = .milliseconds(500)
    private static let skillPromptMinimumDwellSeconds: TimeInterval = 0.8
    private static let startupConfirmationDwell: Duration = .milliseconds(900)

    private enum Phase {
        case idle
        case starting
        case listening
        case recording
        case processing
        case stopping
    }

    private enum IslandStatus: String, Sendable {
        case understanding = "已收到，正在理解"
        case querying = "正在查询"
        case executing = "正在执行"
        case processing = "正在处理"
        case summarizing = "正在整理"
        case result = "结果展示"

        var activityPhase: String {
            switch self {
            case .understanding:
                return "understanding"
            case .querying:
                return "searching"
            case .executing, .processing:
                return "executing"
            case .summarizing:
                return "summarizing"
            case .result:
                return "result"
            }
        }
    }

    private struct SkillPrompt: Equatable, Sendable {
        let status: IslandStatus
        let detail: String
        let skillID: String?
        let skillName: String?
        let toolName: String?

        var phase: String { status.activityPhase }
    }

    var onStatusChanged: ((String) -> Void)?
    var onTranscriptChanged: ((String) -> Void)?
    var onResultChanged: ((String) -> Void)?
    var onDismissRequested: (() -> Void)?

    private let liveActivity = LiveLandActivityBridge()
    private let backgroundContinuation = LiveLandBackgroundContinuation.shared
    private let skillPromptHaptics = LiveLandSkillPromptHaptics()
    private let vad = LiveLandVADService()
    private let asr = ASRService()
    private let turnController = LiveLandTurnController()
    private weak var agentEngine: AgentEngine?
    private var audioIO: LiveLandAudioIO?
    private var phase: Phase = .idle
    private var turnGeneration: UInt64 = 0
    private var listeningRefreshTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var backgroundPreparationTask: Task<Bool, Never>?
    private var preLiveLandBackend: String?
    private var hasLiveActivitySession = false
    private var isAppInBackground = false
    private var isStreamingASRTurnActive = false
    private var streamingTranscript = ""
    private var streamingPartialRevisionCount = 0
    private var liveActivitySkillSignalSeen = false
    private var hasVisibleSkillPresentation = false
    private var pendingSkillPrompt: SkillPrompt?
    private var skillPromptTask: Task<Void, Never>?
    private var visibleSkillPromptStartedAt: Date?
    private var isRunning = false

    func start(agentEngine: AgentEngine) async {
        guard !isRunning else { return }
        isRunning = true
        self.agentEngine = agentEngine
        isAppInBackground = false
        liveActivitySkillSignalSeen = false
        hasVisibleSkillPresentation = false
        resetSkillPromptState()
        phase = .starting
        setStatus("正在启动 LiveLand")
        setTranscript("")
        setResult("")
        skillPromptHaptics.prepare()

        backgroundContinuation.end(success: true)
        await liveActivity.startSession(headline: "LiveLand", entryPoint: "liveLand")
        hasLiveActivitySession = true
        observeLiveActivityDismissal()
        await liveActivity.update(
            phase: "starting",
            headline: "LiveLand",
            detail: "正在启动麦克风监听"
        )

        let io = LiveLandAudioIO()
        do {
            try await io.startForLiveLand()
            skillPromptHaptics.prepare()
        } catch {
            let message = "麦克风启动失败：\(error.localizedDescription)"
            await showFinalResult(message, success: false, status: message)
            await failStartup(message, stopAudio: false)
            return
        }
        audioIO = io

        wireCallbacks()
        await vad.initialize()
        await asr.initialize()

        guard vad.isAvailable, asr.isAvailable else {
            let message = "LiveLand 语音模型未就绪，请先在设置里下载 LIVE 语音模型。"
            await showFinalResult(message, success: false, status: message)
            await failStartup(message, stopAudio: true)
            return
        }

        phase = .listening
        await vad.startListening(audioIO: io)
        print("[LiveLand] microphone listening ready (VAD active, ASR initialized)")
        await showStartupConfirmationThenListen()
    }

    func prepareForAppBackground() {
        guard isRunning, let agentEngine else { return }
        isAppInBackground = true
        startBackgroundRuntimePreparation(agentEngine: agentEngine)
    }

    func restoreRuntimeForForeground() async {
        guard isRunning else { return }
        isAppInBackground = false
        let preparationTask = backgroundPreparationTask
        backgroundPreparationTask = nil
        if let preparationTask {
            _ = await preparationTask.value
        }
        await restoreRuntimeAfterLiveLand(agentEngine: agentEngine)
    }

    func stop(endLiveActivity: Bool = true) async {
        guard isRunning || hasLiveActivitySession || audioIO != nil else { return }
        let engine = agentEngine
        isRunning = false
        phase = .stopping
        listeningRefreshTask?.cancel()
        listeningRefreshTask = nil
        resetSkillPromptState()
        dismissalTask?.cancel()
        dismissalTask = nil
        let preparationTask = backgroundPreparationTask
        backgroundPreparationTask = nil
        preparationTask?.cancel()
        cancelStreamingASRTurn()
        vad.stopListening()
        turnController.reset()
        await cancelActiveAgentWork(agentEngine: engine)
        audioIO?.stop()
        audioIO = nil
        if endLiveActivity, hasLiveActivitySession {
            await liveActivity.endSession(headline: "LiveLand", entryPoint: "liveLand")
        }
        hasLiveActivitySession = false
        backgroundContinuation.end(success: true)
        if let preparationTask {
            _ = await preparationTask.value
        }
        await restoreRuntimeAfterLiveLand(agentEngine: engine)
        isAppInBackground = false
        phase = .idle
    }

    private func wireCallbacks() {
        turnController.onTurnStarted = { [weak self] in
            Task { @MainActor in
                await self?.handleTurnStarted()
            }
        }
        turnController.onTurnConfirmed = { [weak self] samples in
            Task { @MainActor in
                await self?.handleTurnConfirmed(samples)
            }
        }
        turnController.onTurnCancelled = { [weak self] in
            Task { @MainActor in
                await self?.handleTurnCancelled()
            }
        }
        vad.onSpeechStart = { [weak self] in
            Task { @MainActor in
                self?.handleSpeechStart()
            }
        }
        vad.onSpeechEnd = { [weak self] samples in
            Task { @MainActor in
                self?.handleSpeechEnd(samples)
            }
        }
        vad.onSpeechChunk = { [weak self] chunk in
            Task { @MainActor in
                await self?.handleSpeechChunk(chunk)
            }
        }
    }

    private func handleSpeechStart() {
        guard isRunning else { return }
        switch phase {
        case .listening, .recording:
            turnController.handleSpeechStart()
        case .starting, .processing, .stopping, .idle:
            break
        }
    }

    private func handleSpeechEnd(_ samples: [Float]) {
        guard isRunning else { return }
        guard phase == .recording else { return }
        turnController.handleSpeechEnd(samples: samples)
    }

    private func handleTurnStarted() async {
        guard isRunning else { return }
        listeningRefreshTask?.cancel()
        listeningRefreshTask = nil
        if hasVisibleSkillPresentation {
            await updateListening()
        }
        liveActivitySkillSignalSeen = false
        resetSkillPromptState()
        beginStreamingASRTurn()
        phase = .recording
        setStatus("正在聆听")
        setTranscript("")
        setResult("")
    }

    private func handleTurnConfirmed(_ samples: [Float]) async {
        guard isRunning else { return }
        let streamingTranscript = finishStreamingASRTurn()
        turnGeneration &+= 1
        let generation = turnGeneration
        phase = .processing
        setStatus("正在转录")
        await processAudio(samples, generation: generation, streamingTranscript: streamingTranscript)
    }

    private func handleTurnCancelled() async {
        guard isRunning else { return }
        cancelStreamingASRTurn()
        returnToListeningSilently()
    }

    private func handleSpeechChunk(_ chunk: [Float]) async {
        guard isRunning, phase == .recording, isStreamingASRTurnActive else { return }

        let result = asr.appendStreaming(samples: chunk)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != streamingTranscript else { return }

        let previousTranscript = streamingTranscript
        streamingTranscript = text
        setTranscript(text)
        streamingPartialRevisionCount += 1
        if previousTranscript.isEmpty {
            print("[LiveLand] ASR partial: #\(streamingPartialRevisionCount) \"\(text)\"")
        } else {
            print("[LiveLand] ASR partial correction: #\(streamingPartialRevisionCount) \"\(previousTranscript)\" -> \"\(text)\"")
        }
    }

    private func processAudio(
        _ samples: [Float],
        generation: UInt64,
        streamingTranscript: String
    ) async {
        let partialTranscript = streamingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrStart = CFAbsoluteTimeGetCurrent()
        print("[LiveLand] ASR full-turn start: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 16000.0))s)")
        let finalTranscript = await asr.transcribe(samples: samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let asrMs = (CFAbsoluteTimeGetCurrent() - asrStart) * 1000
        let transcript = finalTranscript.isEmpty ? partialTranscript : finalTranscript
        print("[LiveLand] ASR full-turn done: \(String(format: "%.0f", asrMs))ms, final=\"\(finalTranscript)\", partial=\"\(partialTranscript)\", using=\"\(transcript)\"")
        if !finalTranscript.isEmpty, finalTranscript != partialTranscript {
            print("[LiveLand] ASR full-turn correction: streaming=\"\(partialTranscript)\" -> final=\"\(finalTranscript)\"")
        }
        guard isRunning, phase == .processing, turnGeneration == generation else { return }

        guard !transcript.isEmpty else {
            setTranscript("")
            returnToListeningSilently()
            return
        }

        setTranscript(transcript)

        guard let agentEngine else {
            let message = "LiveLand 尚未连接到 PhoneClaw Agent。"
            await showFinalResult(message, success: false, status: message)
            phase = .listening
            scheduleListeningRefresh(after: generation, delay: Self.resultDwell)
            return
        }

        if isAppInBackground {
            let preparedForBackground = await ensureRuntimeReadyForLiveLandAgent(agentEngine: agentEngine)
            guard preparedForBackground else {
                let message = "LiveLand 后台语音运行无法切换到 CPU backend，请稍后再试。"
                await showFinalResult(message, success: false, status: message)
                phase = .listening
                scheduleListeningRefresh(after: generation, delay: Self.resultDwell)
                return
            }
        }

        setStatus("正在理解")
        liveActivitySkillSignalSeen = false
        let previousActivityEventSink = agentEngine.activityEventSink
        agentEngine.activityEventSink = { [weak self] event in
            await self?.scheduleSkillPrompt(for: event, generation: generation)
        }
        defer {
            agentEngine.activityEventSink = previousActivityEventSink
        }

        let liveLandMessages = await agentEngine.processLiveLandCommand(transcript)
        guard isRunning, phase == .processing, turnGeneration == generation else { return }

        let result = summarize(messages: liveLandMessages)
        cancelPendingSkillPrompt()
        guard await waitForVisibleSkillPromptMinimumDwell(generation: generation) else { return }

        let resultDialog = islandResultDialog(for: result)
        await showFinalResult(
            resultDialog,
            success: result.success,
            skillID: result.skillID,
            skillName: result.skillID,
            toolName: result.toolName
        )
        phase = .listening
        scheduleListeningRefresh(after: generation, delay: Self.resultDwell)
    }

    private func showFinalResult(
        _ resultDialog: String,
        success: Bool,
        status: String? = nil,
        skillID: String? = nil,
        skillName: String? = nil,
        toolName: String? = nil
    ) async {
        setStatus(status ?? (success ? IslandStatus.result.rawValue : "未完成"))
        setResult(resultDialog)
        hasVisibleSkillPresentation = true
        visibleSkillPromptStartedAt = nil

        _ = await liveActivity.presentTransientResult(
            headline: "LiveLand",
            detail: resultDialog,
            skillID: skillID,
            skillName: skillName,
            toolName: toolName,
            success: success,
            entryPoint: "liveLand",
            allowTransientRequest: true
        )
        playSkillPromptHaptic(for: IslandStatus.result.rawValue)
    }

    private func beginStreamingASRTurn() {
        streamingTranscript = ""
        streamingPartialRevisionCount = 0
        isStreamingASRTurnActive = true
        asr.beginStreaming()
        print("[LiveLand] ASR streaming start")
    }

    private func finishStreamingASRTurn() -> String {
        guard isStreamingASRTurnActive else { return streamingTranscript }
        let result = asr.endStreaming()
        let final = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            streamingTranscript = final
            setTranscript(final)
        }
        isStreamingASRTurnActive = false
        print("[LiveLand] ASR streaming final: \"\(streamingTranscript)\"")
        return streamingTranscript
    }

    private func cancelStreamingASRTurn() {
        guard isStreamingASRTurnActive || !streamingTranscript.isEmpty else { return }
        asr.cancelStreaming()
        isStreamingASRTurnActive = false
        streamingTranscript = ""
        streamingPartialRevisionCount = 0
        print("[LiveLand] ASR streaming cancelled")
    }

    private func scheduleSkillPrompt(for event: AgentActivityEvent, generation: UInt64) async {
        guard isRunning,
              phase == .processing,
              turnGeneration == generation
        else { return }

        let prompt = skillPrompt(from: event)
        if event.phase == .accepted {
            scheduleAcceptedPrompt(prompt, generation: generation)
            return
        }

        cancelPendingSkillPrompt()
        if event.phase == .summarizing {
            guard await waitForVisibleSkillPromptMinimumDwell(generation: generation) else { return }
        }

        await presentSkillPrompt(
            prompt,
            generation: generation,
            markSkillSignal: true,
            playHaptic: true
        )
    }

    private func scheduleAcceptedPrompt(_ prompt: SkillPrompt, generation: UInt64) {
        cancelPendingSkillPrompt()
        pendingSkillPrompt = prompt
        skillPromptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.acceptedPromptDelay)
            guard let self,
                  !Task.isCancelled,
                  self.pendingSkillPrompt == prompt
            else { return }
            await self.presentSkillPrompt(
                prompt,
                generation: generation,
                markSkillSignal: false,
                playHaptic: false
            )
        }
    }

    private func presentSkillPrompt(
        _ prompt: SkillPrompt,
        generation: UInt64,
        markSkillSignal: Bool,
        playHaptic: Bool
    ) async {
        guard isRunning,
              phase == .processing,
              turnGeneration == generation
        else { return }

        if markSkillSignal {
            liveActivitySkillSignalSeen = true
        }
        pendingSkillPrompt = prompt
        hasVisibleSkillPresentation = true
        visibleSkillPromptStartedAt = Date()
        setStatus(prompt.detail)
        if playHaptic {
            skillPromptHaptics.prepare()
        }
        await liveActivity.update(
            phase: prompt.phase,
            headline: "LiveLand",
            detail: prompt.detail,
            skillID: prompt.skillID,
            skillName: prompt.skillName,
            toolName: prompt.toolName
        )
        if playHaptic {
            playSkillPromptHaptic(for: prompt.detail)
        }
    }

    private func cancelPendingSkillPrompt() {
        skillPromptTask?.cancel()
        skillPromptTask = nil
        pendingSkillPrompt = nil
    }

    private func resetSkillPromptState() {
        cancelPendingSkillPrompt()
        visibleSkillPromptStartedAt = nil
    }

    private func waitForVisibleSkillPromptMinimumDwell(generation: UInt64) async -> Bool {
        guard let visibleSkillPromptStartedAt else { return true }

        let remaining = Self.skillPromptMinimumDwellSeconds
            - Date().timeIntervalSince(visibleSkillPromptStartedAt)
        if remaining > 0 {
            try? await Task.sleep(for: .milliseconds(Int(ceil(remaining * 1000))))
        }

        return isRunning && phase == .processing && turnGeneration == generation
    }

    private func skillPrompt(from event: AgentActivityEvent) -> SkillPrompt {
        let status = islandStatus(for: event)
        let detail = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillPrompt(
            status: status,
            detail: detail.isEmpty ? status.rawValue : detail,
            skillID: event.skillID,
            skillName: event.skillName,
            toolName: event.toolName
        )
    }

    private func islandStatus(for event: AgentActivityEvent) -> IslandStatus {
        switch event.phase {
        case .accepted:
            return .understanding
        case .searching:
            return .querying
        case .processing:
            return .processing
        case .summarizing:
            return .summarizing
        case .executing:
            return .executing
        }
    }

    private func playSkillPromptHaptic(for detail: String) {
        skillPromptHaptics.play(for: detail)
    }

    private func showStartupConfirmationThenListen() async {
        guard isRunning else { return }
        let generation = turnGeneration
        phase = .listening
        setStatus("LiveLand 已启动")
        await liveActivity.update(
            phase: "starting",
            headline: "LiveLand",
            detail: "LiveLand 已启动"
        )
        try? await Task.sleep(for: Self.startupConfirmationDwell)
        guard isRunning, phase == .listening, turnGeneration == generation else { return }
        await updateListening()
    }

    private func updateListening() async {
        guard isRunning else { return }
        phase = .listening
        setStatus("")
        hasVisibleSkillPresentation = false
        resetSkillPromptState()
        await liveActivity.startSession(headline: "LiveLand", detail: "", entryPoint: "liveLand")
        await liveActivity.update(
            phase: "listening",
            headline: "LiveLand",
            detail: ""
        )
    }

    private func returnToListeningSilently() {
        guard isRunning else { return }
        phase = .listening
        setStatus("")
        setResult("")
        resetSkillPromptState()
    }

    private func scheduleListeningRefresh(
        after generation: UInt64,
        delay: Duration? = nil
    ) {
        listeningRefreshTask?.cancel()
        let refreshDelay = delay ?? Self.shortPromptDwell
        let liveActivity = self.liveActivity
        listeningRefreshTask = Task { [weak self, liveActivity] in
            try? await Task.sleep(for: refreshDelay)
            let shouldRefresh = await MainActor.run {
                guard let self,
                      self.isRunning,
                      self.phase == .listening,
                      self.turnGeneration == generation
                else { return false }
                self.setStatus("")
                self.setResult("")
                self.hasVisibleSkillPresentation = false
                self.resetSkillPromptState()
                return true
            }
            guard shouldRefresh else { return }
            await liveActivity.startSession(headline: "LiveLand", detail: "", entryPoint: "liveLand")
            await liveActivity.update(
                phase: "listening",
                headline: "LiveLand",
                detail: ""
            )
        }
    }

    private func observeLiveActivityDismissal() {
        dismissalTask?.cancel()
        let liveActivity = self.liveActivity
        dismissalTask = Task { [weak self] in
            let dismissed = await liveActivity.waitForDismissal()
            guard dismissed else { return }
            await MainActor.run {
                self?.onDismissRequested?()
            }
            await self?.stop(endLiveActivity: false)
        }
    }

    private func failStartup(_ message: String, stopAudio: Bool) async {
        listeningRefreshTask?.cancel()
        listeningRefreshTask = nil
        resetSkillPromptState()
        let preparationTask = backgroundPreparationTask
        backgroundPreparationTask = nil
        preparationTask?.cancel()
        cancelStreamingASRTurn()
        vad.stopListening()
        turnController.reset()
        if stopAudio {
            audioIO?.stop()
            audioIO = nil
        }
        backgroundContinuation.end(success: false)
        if let preparationTask {
            _ = await preparationTask.value
        }
        await restoreRuntimeAfterLiveLand(agentEngine: agentEngine)
        isRunning = false
        isAppInBackground = false
        phase = .idle
    }

    private func startBackgroundRuntimePreparation(agentEngine: AgentEngine) {
        guard backgroundPreparationTask == nil else { return }
        backgroundPreparationTask = Task { [weak self, weak agentEngine] in
            guard let self, let agentEngine else { return false }
            return await self.prepareRuntimeForBackgroundLiveLand(agentEngine: agentEngine)
        }
    }

    private func ensureRuntimeReadyForLiveLandAgent(agentEngine: AgentEngine) async -> Bool {
        if let backgroundPreparationTask {
            return await backgroundPreparationTask.value
        }
        return await prepareRuntimeForBackgroundLiveLand(agentEngine: agentEngine)
    }

    private func prepareRuntimeForBackgroundLiveLand(agentEngine: AgentEngine) async -> Bool {
        guard !backgroundContinuation.supportsBackgroundGPU else { return true }
        guard case .ready(_, let backend) = agentEngine.coordinator.sessionState else { return true }
        guard backend == "gpu" else {
            print("[LiveLand] background GPU unavailable; LiveLand runtime already backend=\(backend)")
            return true
        }

        preLiveLandBackend = backend
        print("[LiveLand] background GPU unavailable; switching LiveLand runtime gpu -> cpu to keep microphone -> agent running in background")
        do {
            try await agentEngine.coordinator.switchBackend(to: "cpu")
            return true
        } catch {
            preLiveLandBackend = nil
            print("[LiveLand] CPU backend switch for background LiveLand failed: \(error.localizedDescription)")
            return false
        }
    }

    private func restoreRuntimeAfterLiveLand(agentEngine: AgentEngine?) async {
        guard let backend = preLiveLandBackend else { return }
        defer { preLiveLandBackend = nil }
        guard let agentEngine,
              case .ready(_, let currentBackend) = agentEngine.coordinator.sessionState,
              currentBackend != backend else {
            return
        }

        print("[LiveLand] restoring runtime backend \(currentBackend) -> \(backend)")
        do {
            try await agentEngine.coordinator.switchBackend(to: backend)
        } catch {
            print("[LiveLand] restore backend failed: \(error.localizedDescription)")
        }
    }

    private func cancelActiveAgentWork(agentEngine: AgentEngine?) async {
        guard let agentEngine else { return }
        guard agentEngine.isProcessing
                || agentEngine.isModelGenerating
                || agentEngine.coordinator.currentTransaction != nil else {
            return
        }

        agentEngine.cancelActiveGeneration()
        await agentEngine.coordinator.cancelCurrentGeneration()
    }

    private func summarize(messages: [ChatMessage]) -> LiveLandAgentResult {
        if let error = messages.last(where: {
            $0.role == .system
                && $0.skillName == nil
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .init(
                success: false,
                dialog: normalizedForDialog(error.content),
                skillID: error.skillName,
                toolName: nil
            )
        }

        let tool = messages.last(where: {
            $0.role == .skillResult && $0.skillResultKind == .toolExecution
        })
        let assistant = messages.last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) != "▍"
        })
        let content = assistant?.content
            ?? tool?.content
            ?? ""
        let toolName = tool?.skillName
        let skillID = toolName ?? assistant?.skillName ?? messages.compactMap(\.skillName).last
        let dialog = normalizedForDialog(content)
        guard !dialog.isEmpty else {
            return .init(
                success: false,
                dialog: "LiveLand 没有得到可显示的结果。",
                skillID: skillID,
                toolName: toolName
            )
        }
        return .init(
            success: true,
            dialog: dialog,
            skillID: skillID,
            toolName: toolName
        )
    }

    private func islandResultDialog(for result: LiveLandAgentResult) -> String {
        let dialog = normalizedForDialog(result.dialog)
        guard !result.success else { return dialog }
        guard !dialog.isEmpty else { return "未完成" }
        if dialog == "未完成" || dialog.hasPrefix("未完成\n") {
            return dialog
        }
        return "未完成\n\(dialog)"
    }

    private func setStatus(_ value: String) {
        onStatusChanged?(value)
    }

    private func setTranscript(_ value: String) {
        onTranscriptChanged?(value)
    }

    private func setResult(_ value: String) {
        onResultChanged?(value)
    }

    private func normalizedForDialog(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clipped(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
