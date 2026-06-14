import AppIntents
import Foundation

struct PhoneClawLiveAgentResult: Equatable {
    let success: Bool
    let dialog: String
    let skillID: String?
    let toolName: String?
}

@MainActor
final class PhoneClawLiveAgentRuntime {
    static let shared = PhoneClawLiveAgentRuntime()

    private let liveActivity = LiveActivityBridge()
    private var engine: AgentEngine?
    private var isRunning = false

    private init() {}

    func run(request: String) async -> PhoneClawLiveAgentResult {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .init(
                success: false,
                dialog: "你想让 PhoneClaw 做什么？",
                skillID: nil,
                toolName: nil
            )
        }

        guard !isRunning else {
            return .init(
                success: false,
                dialog: "PhoneClaw LIVE 正在处理上一条请求，请稍后再试。",
                skillID: nil,
                toolName: nil
            )
        }

        isRunning = true
        defer { isRunning = false }

        await liveActivity.startSession()
        await liveActivity.update(
            phase: "understanding",
            headline: "PhoneClaw LIVE",
            detail: "正在理解请求"
        )

        let engine = engine ?? makeHeadlessEngine()
        self.engine = engine

        guard await waitUntilReady(engine: engine, timeout: 35) else {
            let message = "PhoneClaw 模型还没准备好。请先打开 App 完成模型下载或加载。"
            await liveActivity.update(
                phase: "ended",
                headline: "PhoneClaw LIVE",
                detail: message,
                success: false,
                alertTitle: "PhoneClaw LIVE",
                alertBody: message
            )
            await finishLiveActivitySoon()
            return .init(success: false, dialog: message, skillID: nil, toolName: nil)
        }

        engine.messages = []
        engine.sessionStore.cancelPendingSave()
        let startIndex = engine.messages.count
        await liveActivity.update(
            phase: "executing",
            headline: "正在执行",
            detail: clipped(normalized, limit: 72)
        )

        await engine.processInput(normalized)
        engine.flushPendingStreamingMessageContentUpdates()
        engine.sessionStore.cancelPendingSave()

        let newMessages = Array(engine.messages.dropFirst(min(startIndex, engine.messages.count)))
        let result = summarize(messages: newMessages)

        await liveActivity.update(
            phase: "ended",
            headline: result.success ? "已完成" : "需要处理",
            detail: clipped(result.dialog, limit: 86),
            skillID: result.skillID,
            skillName: result.skillID,
            toolName: result.toolName,
            success: result.success,
            alertTitle: "PhoneClaw LIVE",
            alertBody: clipped(result.dialog, limit: 86)
        )
        await finishLiveActivitySoon()
        return result
    }

    private func makeHeadlessEngine() -> AgentEngine {
        let engine = AgentEngine()
        engine.setSessionPersistenceEnabled(false)
        engine.setup()
        engine.messages = []
        engine.sessionStore.cancelPendingSave()
        return engine
    }

    private func waitUntilReady(engine: AgentEngine, timeout: TimeInterval) async -> Bool {
        if engine.isModelReady { return true }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.isModelReady { return true }
            if case .failed = engine.coordinator.sessionState { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return engine.isModelReady
    }

    private func summarize(messages: [ChatMessage]) -> PhoneClawLiveAgentResult {
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
            ?? "PhoneClaw 已处理请求。"
        let toolName = tool?.skillName
        let skillID = toolName ?? assistant?.skillName ?? messages.compactMap(\.skillName).last
        return .init(
            success: true,
            dialog: clippedForDialog(content),
            skillID: skillID,
            toolName: toolName
        )
    }

    private func finishLiveActivitySoon() async {
        try? await Task.sleep(for: .seconds(2))
        await liveActivity.endSession()
    }

    private func clippedForDialog(_ value: String) -> String {
        clipped(
            value
                .replacingOccurrences(of: "\n\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 360
        )
    }

    private func clipped(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}

struct StartPhoneClawLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Start PhoneClaw LIVE"
    static var description = IntentDescription("Open PhoneClaw directly in LIVE voice mode.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveLaunchRequestStore.requestVoiceLaunch()
        return .result()
    }
}

struct AskPhoneClawLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask PhoneClaw LIVE"
    static var description = IntentDescription("Ask PhoneClaw LIVE to understand and execute a request without opening the main chat.")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Request",
        requestValueDialog: "What should PhoneClaw do?"
    )
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await PhoneClawLiveAgentRuntime.shared.run(request: request)
        return .result(dialog: IntentDialog(stringLiteral: result.dialog))
    }
}

struct PhoneClawAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPhoneClawLiveIntent(),
            phrases: [
                "Start \(.applicationName) LIVE",
                "Open \(.applicationName) LIVE",
                "开始 \(.applicationName) 语音",
                "打开 \(.applicationName) LIVE",
                "和 \(.applicationName) 对话",
                "用 \(.applicationName) 开始语音"
            ],
            shortTitle: "LIVE",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskPhoneClawLiveIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) LIVE",
                "让 \(.applicationName) 处理",
                "用 \(.applicationName) 执行"
            ],
            shortTitle: "Ask LIVE",
            systemImageName: "sparkles"
        )
    }
}
