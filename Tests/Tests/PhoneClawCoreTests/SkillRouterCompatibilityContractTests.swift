import XCTest

final class SkillRouterCompatibilityContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhoneClawCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testProductionSourcesDoNotImportIOS27OnlyFrameworksWithoutGuards() throws {
        let productionDirectories = ["Agent", "LLM", "Shared", "Skills", "Tools", "UI", "Live", "App"]
        let forbiddenImports = ["import FoundationModels", "import CoreAI"]
        let fileManager = FileManager.default

        for directory in productionDirectories {
            let root = repoRoot.appendingPathComponent(directory)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for forbiddenImport in forbiddenImports {
                    guard content.contains(forbiddenImport) else { continue }
                    XCTAssertTrue(
                        fileURL.lastPathComponent.hasPrefix("IOS27") && content.contains("#if canImport("),
                        "\(fileURL.path) must guard \(forbiddenImport) behind an iOS 27 compatibility boundary"
                    )
                }
            }
        }
    }

    func testGuardedDirectAnswerBlocksModelIntentFallback() throws {
        let processInput = try source("Agent/Engine/ProcessInput.swift")

        XCTAssertTrue(processInput.contains("guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("!guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("guardedRouteDecision?.action == .answerDirectly"))
    }

    func testIOS27FoundationRouterIsAutoEnabledAndFallbackOnly() throws {
        let flags = try source("Agent/HotfixFeatureFlags.swift")
        let processInput = try source("Agent/Engine/ProcessInput.swift")
        let router = try source("Agent/Engine/Router.swift")
        let ios27Router = try source("Agent/Engine/IOS27FoundationSkillRouter.swift")

        XCTAssertTrue(flags.contains("ENABLE_IOS27_FOUNDATION_ROUTER"))
        XCTAssertTrue(flags.contains("value(for: .enableIOS27FoundationRouter, defaultValue: true)"))
        XCTAssertTrue(processInput.contains("ios27FoundationSkillRouteDecision"))
        XCTAssertTrue(processInput.contains("!guardedRouteBlocksModelIntent"))
        XCTAssertTrue(processInput.contains("!ios27RouteBlocksModelIntent"))
        XCTAssertTrue(router.contains("shouldAttemptIOS27FoundationSkillRoute"))
        XCTAssertTrue(ios27Router.contains("#if canImport(FoundationModels)"))
        XCTAssertTrue(ios27Router.contains("if #available(iOS 27.0, macOS 27.0, *)"))
    }

    func testIOS27FoundationRouterUsesIOS27ModelAPIsWithDiagnostics() throws {
        let router = try source("Agent/Engine/Router.swift")
        let ios27Router = try source("Agent/Engine/IOS27FoundationSkillRouter.swift")

        XCTAssertTrue(ios27Router.contains("session.prewarm()"))
        XCTAssertTrue(ios27Router.contains("GenerationOptions("))
        XCTAssertTrue(ios27Router.contains("toolCallingMode: .disallowed"))
        XCTAssertTrue(ios27Router.contains("ContextOptions(includeSchemaInPrompt: true)"))
        XCTAssertTrue(ios27Router.contains("metadata: ["))
        XCTAssertTrue(ios27Router.contains("response.usage.input.totalTokenCount"))
        XCTAssertTrue(ios27Router.contains("response.usage.output.reasoningTokenCount"))
        XCTAssertTrue(router.contains("source=foundation_probe"))
        XCTAssertTrue(router.contains("prewarm_ms="))
        XCTAssertTrue(router.contains("route_ms="))
        XCTAssertTrue(router.contains("total_tokens="))
    }

    func testRouteSourceLogsAreStandardized() throws {
        let processInput = try source("Agent/Engine/ProcessInput.swift")
        let router = try source("Agent/Engine/Router.swift")

        XCTAssertTrue(processInput.contains("source=trigger"))
        XCTAssertTrue(router.contains("source=guarded"))
        XCTAssertTrue(router.contains("source=foundation"))
        XCTAssertTrue(router.contains("source=model"))
    }

    func testLiveSkillInfoDisplayDoesNotExposeRawToolJSON() throws {
        let liveOutputEvent = try source("Live/Turn/Types/LiveOutputEvent.swift")

        XCTAssertTrue(liveOutputEvent.contains("case skillInfo(LiveSkillInfoOutput)"))
        XCTAssertTrue(liveOutputEvent.contains("jsonPayload(from: detail)"))
        XCTAssertTrue(liveOutputEvent.contains("looksMachineReadable"))
        XCTAssertTrue(liveOutputEvent.contains("\"eventid\""))
        XCTAssertTrue(liveOutputEvent.contains("return Self.clipped(normalizedSummary, maxLength: 2200)"))
        XCTAssertFalse(liveOutputEvent.contains("normalizedSummary + \"\\n\\n\" + String(normalizedDetail.prefix"))
    }

    func testLiveBackgroundContinuationFollowsContinuedProcessingContract() throws {
        let continuation = try source("Live/Core/LiveBackgroundContinuation.swift")
        let infoPlist = try source("Info.plist")

        XCTAssertTrue(continuation.contains("static let taskIdentifier = \"com.kellyvv.phoneclaw.live-continuation\""))
        XCTAssertTrue(continuation.contains("registrationAccepted"))
        XCTAssertTrue(continuation.contains("submit skipped: no registered launch handler"))
        XCTAssertTrue(continuation.contains("BGContinuedProcessingTaskRequest("))
        XCTAssertTrue(continuation.contains("identifier: requestIdentifier"))
        XCTAssertTrue(infoPlist.contains("com.kellyvv.phoneclaw.live-continuation"))
        XCTAssertTrue(continuation.contains("BGTaskScheduler.supportedResources.contains(.gpu)"))
        XCTAssertTrue(continuation.contains("task.setTaskCompleted(success: success)"))
        XCTAssertTrue(continuation.contains("reason: \"expired_by_system\""))
        XCTAssertTrue(continuation.contains("case \"understanding\": return 55"))
        XCTAssertTrue(continuation.contains("case \"searching\", \"executing\": return 72"))
        XCTAssertTrue(continuation.contains("case \"summarizing\": return 84"))
    }

    func testLiveActivityDismissalStopsLiveSession() throws {
        let bridge = try source("Live/Activity/LiveActivityBridge.swift")
        let liveModeEngine = try source("Live/Core/LiveModeEngine.swift")
        let liveModeUI = try source("Live/UI/LiveModeUI.swift")

        XCTAssertTrue(bridge.contains("func waitForDismissal() async -> Bool"))
        XCTAssertTrue(bridge.contains("activity.activityStateUpdates"))
        XCTAssertTrue(bridge.contains("case .dismissed:"))
        XCTAssertTrue(bridge.contains("dismissed by user"))

        XCTAssertTrue(liveModeEngine.contains("endedByLiveActivityDismissal"))
        XCTAssertTrue(liveModeEngine.contains("liveActivityDismissalTask"))
        XCTAssertTrue(liveModeEngine.contains("observeLiveActivityDismissal()"))
        XCTAssertTrue(liveModeEngine.contains("await self.liveActivity.waitForDismissal()"))
        XCTAssertTrue(liveModeEngine.contains("stopFromLiveActivityDismissal()"))
        XCTAssertTrue(liveModeEngine.contains("await stopLegacy()"))
        XCTAssertTrue(liveModeEngine.contains("cancelLiveActivityDismissalObservation()"))

        XCTAssertTrue(liveModeUI.contains(".onChange(of: liveEngine.endedByLiveActivityDismissal)"))
        XCTAssertTrue(liveModeUI.contains("isPresented = false"))
    }

    func testLiveAppIntentCanExecuteSkillsWithoutOpeningMainChat() throws {
        let shortcuts = try source("App/LiveModeShortcuts.swift")
        let agentEngine = try source("Agent/AgentEngine.swift")

        XCTAssertTrue(shortcuts.contains("struct AskPhoneClawLiveIntent: AppIntent"))
        XCTAssertTrue(shortcuts.contains("static var openAppWhenRun: Bool = false"))
        XCTAssertTrue(shortcuts.contains("PhoneClawLiveAgentRuntime.shared.run(request: request)"))
        XCTAssertTrue(shortcuts.contains("final class PhoneClawLiveAgentRuntime"))
        XCTAssertTrue(shortcuts.contains("await engine.processInput(normalized)"))
        XCTAssertTrue(shortcuts.contains("engine.setSessionPersistenceEnabled(false)"))
        XCTAssertTrue(shortcuts.contains("engine.messages = []"))
        XCTAssertTrue(shortcuts.contains("engine.sessionStore.cancelPendingSave()"))
        XCTAssertTrue(shortcuts.contains("phase: \"understanding\""))
        XCTAssertTrue(shortcuts.contains("phase: \"executing\""))
        XCTAssertTrue(shortcuts.contains("phase: \"ended\""))
        XCTAssertTrue(shortcuts.contains("AppShortcut("))
        XCTAssertTrue(shortcuts.contains("AskPhoneClawLiveIntent()"))
        XCTAssertTrue(shortcuts.contains("requestValueDialog: \"What should PhoneClaw do?\""))
        XCTAssertFalse(shortcuts.contains("\\(\\.$request)"))

        XCTAssertTrue(agentEngine.contains("@ObservationIgnored private var isSessionPersistenceEnabled = true"))
        XCTAssertTrue(agentEngine.contains("func setSessionPersistenceEnabled(_ enabled: Bool)"))
        XCTAssertTrue(agentEngine.contains("if isSessionPersistenceEnabled"))
        XCTAssertTrue(agentEngine.contains("sessionStore.cancelPendingSave()"))
    }

    func testLiveLauncherWidgetSupportsLockScreenEntryPoints() throws {
        let widget = try source("PhoneClawLiveActivityWidget/PhoneClawLiveActivityWidget.swift")

        XCTAssertTrue(widget.contains("private let phoneClawLiveLaunchURL = URL(string: \"phoneclaw://live?mode=voice\")!"))
        XCTAssertTrue(widget.contains("PhoneClawLiveLauncherWidget()"))
        XCTAssertTrue(widget.contains("kind: \"PhoneClawLiveLauncherWidget\""))
        XCTAssertTrue(widget.contains(".widgetURL(phoneClawLiveLaunchURL)"))
        XCTAssertTrue(widget.contains(".supportedFamilies(["))
        XCTAssertTrue(widget.contains(".systemSmall"))
        XCTAssertTrue(widget.contains(".accessoryCircular"))
        XCTAssertTrue(widget.contains(".accessoryRectangular"))
        XCTAssertTrue(widget.contains(".accessoryInline"))
        XCTAssertTrue(widget.contains("@Environment(\\.widgetFamily)"))
        XCTAssertTrue(widget.contains("case .accessoryCircular"))
        XCTAssertTrue(widget.contains("case .accessoryRectangular"))
        XCTAssertTrue(widget.contains("case .accessoryInline"))
        XCTAssertTrue(widget.contains("AccessoryWidgetBackground()"))
    }

    func testLiveControlWidgetSupportsControlCenterEntryPoint() throws {
        let widget = try source("PhoneClawLiveActivityWidget/PhoneClawLiveActivityWidget.swift")

        XCTAssertTrue(widget.contains("import AppIntents"))
        XCTAssertTrue(widget.contains("if #available(iOS 18.0, *)"))
        XCTAssertTrue(widget.contains("PhoneClawLiveControlWidget()"))
        XCTAssertTrue(widget.contains("struct PhoneClawLiveControlWidget: ControlWidget"))
        XCTAssertTrue(widget.contains("StaticControlConfiguration(kind: \"PhoneClawLiveControlWidget\")"))
        XCTAssertTrue(widget.contains("ControlWidgetButton(action: OpenURLIntent(phoneClawLiveLaunchURL))"))
        XCTAssertTrue(widget.contains("Label(\"PhoneClaw LIVE\", systemImage: \"waveform\")"))
        XCTAssertTrue(widget.contains(".displayName(\"PhoneClaw LIVE\")"))
    }

    func testLiveDynamicIslandSeparatesVoiceAndThinkingGlyphs() throws {
        let widget = try source("PhoneClawLiveActivityWidget/PhoneClawLiveActivityWidget.swift")

        XCTAssertTrue(widget.contains("private enum LiveIslandStage"))
        XCTAssertTrue(widget.contains("private enum LiveIslandVisualPhase"))
        XCTAssertTrue(widget.contains("private struct LiveIslandPresentation"))
        XCTAssertTrue(widget.contains("LiveIslandCoreVisual(presentation: presentation, diameter: 58)"))
        XCTAssertTrue(widget.contains("LiveIslandCoreVisual(presentation: presentation, diameter: 34)"))
        XCTAssertTrue(widget.contains("LiveIslandCoreVisual(presentation: presentation, diameter: 24)"))
        XCTAssertTrue(widget.contains("compactTrailing: {\n                EmptyView()"))
        XCTAssertTrue(widget.contains("private enum LiveTheme"))
        XCTAssertTrue(widget.contains("static let signal = Color"))
        XCTAssertTrue(widget.contains("private struct LiveAuroraCapsuleBackground: View"))
        XCTAssertTrue(widget.contains("private struct LiveIslandCoreVisual: View"))
        XCTAssertTrue(widget.contains("private struct LiveListeningDotWave: View"))
        XCTAssertTrue(widget.contains("private struct LiveSystemSkillProgress: View"))
        XCTAssertTrue(widget.contains("private struct LiveResultMark: View"))
        XCTAssertTrue(widget.contains("private struct LiveIdleMark: View"))
        XCTAssertTrue(widget.contains("private static let skillProgressDuration: TimeInterval = 32"))
        XCTAssertTrue(widget.contains("var primaryLine: String"))
        XCTAssertTrue(widget.contains("var visualPhase: LiveIslandVisualPhase"))
        XCTAssertTrue(widget.contains("var skillProgressInterval: ClosedRange<Date>"))
        XCTAssertTrue(widget.contains("let start = state.phaseStartedAt ?? state.startedAt ?? Date()"))
        XCTAssertTrue(widget.contains("return start...start.addingTimeInterval(Self.skillProgressDuration)"))
        XCTAssertTrue(widget.contains("var moodText: String"))
        XCTAssertTrue(widget.contains("ProgressView(timerInterval: presentation.skillProgressInterval, countsDown: false)"))
        XCTAssertTrue(widget.contains(".progressViewStyle(.circular)"))
        XCTAssertTrue(widget.contains(".tint(presentation.accent.glyph)"))
        XCTAssertTrue(widget.contains(".labelsHidden()"))
        XCTAssertFalse(widget.contains("ProgressView()"))
        XCTAssertFalse(widget.contains("private let liveIslandFrameInterval"))
        XCTAssertFalse(widget.contains("TimelineView(.periodic"))
        XCTAssertFalse(widget.contains("TimelineView(.animation(minimumInterval: 0.08"))
        XCTAssertFalse(widget.contains("TimelineView(.animation(minimumInterval: 0.016"))
        XCTAssertTrue(widget.contains("let levels: [CGFloat] = [0.42, 0.72, 1.0, 0.82, 0.56, 0.34]"))
        XCTAssertTrue(widget.contains("ForEach(levels.indices"))
        XCTAssertFalse(widget.contains("sin(t * 7.0"))
        XCTAssertFalse(widget.contains("let envelope = 0.62 + 0.38"))
        XCTAssertFalse(widget.contains("let rotation = t * 1.45"))
        XCTAssertFalse(widget.contains("cos(phase)"))
        XCTAssertFalse(widget.contains("sin(phase)"))
        XCTAssertFalse(widget.contains(".rotationEffect(.degrees(t * 42.0))"))
        XCTAssertFalse(widget.contains(".trim(from: 0.10, to: 0.82)"))
        XCTAssertTrue(widget.contains("case \"listening\", \"recording\": return .voice"))
        XCTAssertTrue(widget.contains("case \"understanding\", \"processing\": return .thinking"))
        XCTAssertTrue(widget.contains("case \"searching\": return .searching"))
        XCTAssertTrue(widget.contains("case \"executing\": return .executing"))
        XCTAssertTrue(widget.contains("case \"summarizing\", \"speaking\": return .responding"))
        XCTAssertTrue(widget.contains("case .starting, .thinking, .searching, .executing, .responding:\n            return .skill"))
        XCTAssertTrue(widget.contains("case .voice, .thinking, .searching, .executing, .responding, .starting: return .amber"))
        XCTAssertFalse(widget.contains("var compactTitle: String"))
        XCTAssertFalse(widget.contains("var compactStageText: String"))
        XCTAssertFalse(widget.contains("var phaseStartedAt: Date?"))
        XCTAssertFalse(widget.contains("var statusText: String"))
        XCTAssertFalse(widget.contains("var iconName: String"))
        XCTAssertFalse(widget.contains("LiveCompactLeadingSurface(presentation: presentation)"))
        XCTAssertFalse(widget.contains("LiveCompactTrailingSurface(presentation: presentation)"))
        XCTAssertFalse(widget.contains("LiveCompactGlyph"))
        XCTAssertFalse(widget.contains("private struct LiveCompactHalo: View"))
        XCTAssertFalse(widget.contains("private struct LiveCompactStatusPulse"))
        XCTAssertFalse(widget.contains("private struct LiveProgressRing"))
        XCTAssertFalse(widget.contains("private struct LivePipelineTrack"))
        XCTAssertFalse(widget.contains("private func liveIsVoiceInputPhase"))
        XCTAssertFalse(widget.contains("private func liveIsThinkingPhase"))
        XCTAssertFalse(widget.contains("private func liveProgress(for state"))
    }

    func testLiveDynamicIslandExpandedModeUsesLargeLivePanel() throws {
        let widget = try source("PhoneClawLiveActivityWidget/PhoneClawLiveActivityWidget.swift")

        XCTAssertTrue(widget.contains("DynamicIslandExpandedRegion(.center, priority: 3)"))
        XCTAssertTrue(widget.contains("DynamicIslandExpandedRegion(.bottom, priority: 2)"))
        XCTAssertTrue(widget.contains("private struct LiveIslandResultPanel: View"))
        XCTAssertTrue(widget.contains("private struct LiveMinimalActivityCard: View"))
        XCTAssertTrue(widget.contains("Text(presentation.primaryLine)"))
        XCTAssertTrue(widget.contains("LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 17)"))
        XCTAssertTrue(widget.contains("if presentation.visualPhase == .result"))
        XCTAssertTrue(widget.contains(".frame(maxWidth: .infinity, minHeight: 48)"))
        XCTAssertTrue(widget.contains("ForEach(levels.indices"))
        XCTAssertFalse(widget.contains("DynamicIslandExpandedRegion(.leading"))
        XCTAssertFalse(widget.contains("DynamicIslandExpandedRegion(.trailing"))
        XCTAssertFalse(widget.contains("LiveIslandLeadingRail(presentation: presentation)"))
        XCTAssertFalse(widget.contains("LiveIslandCenterLabel(presentation: presentation)"))
        XCTAssertFalse(widget.contains("LiveIslandTrailingRail(presentation: presentation)"))
        XCTAssertFalse(widget.contains("LiveIslandBottomPanel(presentation: presentation)"))
        XCTAssertFalse(widget.contains("private struct LiveIslandSurroundingVisual: View"))
        XCTAssertFalse(widget.contains("private struct LiveExpandedVoiceWave: View"))
        XCTAssertFalse(widget.contains("private struct LiveExpandedThinkingGlyph: View"))
        XCTAssertFalse(widget.contains("private struct LiveExpandedSkillGlyph: View"))
        XCTAssertFalse(widget.contains("private struct LiveExpandedMilestones: View"))
        XCTAssertFalse(widget.contains("milestone(\"听\""))
        XCTAssertFalse(widget.contains("milestone(\"想\""))
        XCTAssertFalse(widget.contains("milestone(\"做\""))
        XCTAssertFalse(widget.contains("milestone(\"答\""))
        XCTAssertFalse(widget.contains("LiveDynamicIslandExpandedPanel"))
        XCTAssertFalse(widget.contains("LiveExpandedIslandVisualizer"))
    }

    func testLiveASRReusesMainAgentSkillChain() throws {
        let contentView = try source("UI/ContentView.swift")
        let liveModeUI = try source("Live/UI/LiveModeUI.swift")
        let liveModeEngine = try source("Live/Core/LiveModeEngine.swift")
        let liveWarmPool = try source("Live/Core/LiveWarmPool.swift")
        let liveActivityWidget = try source("PhoneClawLiveActivityWidget/PhoneClawLiveActivityWidget.swift")

        XCTAssertTrue(contentView.contains("agentEngine: engine"))
        XCTAssertTrue(liveModeUI.contains("let agentEngine: AgentEngine"))
        XCTAssertTrue(liveModeUI.contains("agentEngine: agentEngine"))
        XCTAssertTrue(liveModeUI.contains("liveEngine.setup(inference: inference, agentEngine: agentEngine)"))

        XCTAssertTrue(liveModeEngine.contains("private var agentEngine: AgentEngine?"))
        XCTAssertTrue(liveModeEngine.contains("processMainAgentTextTurn("))
        XCTAssertTrue(liveModeEngine.contains("await agentEngine.processInput(transcript)"))
        XCTAssertTrue(liveModeEngine.contains("liveInfoOutputFromMainAgentMessages"))
        XCTAssertTrue(liveModeEngine.contains("persistent live LLM conversation skipped"))
        XCTAssertTrue(liveModeEngine.contains("refusing LIVE-local Skill path"))
        XCTAssertTrue(liveModeEngine.contains("missing MAIN AgentEngine during ASR turn"))
        XCTAssertTrue(liveModeEngine.contains("didEnterLLMLiveMode"))
        XCTAssertTrue(liveModeEngine.contains("mainAgentTurnTimeout: TimeInterval = 180"))
        XCTAssertTrue(liveModeEngine.contains("liveTimedOutInfoOutput("))
        XCTAssertTrue(liveModeEngine.contains("main Agent turn still processing after"))
        XCTAssertTrue(liveModeEngine.contains("LiveAgentProgressSnapshot"))
        XCTAssertTrue(liveModeEngine.contains("publishMainAgentProgress("))
        XCTAssertTrue(liveModeEngine.contains("liveActivityListeningRefreshTask"))
        XCTAssertTrue(liveModeEngine.contains("scheduleLiveActivityListeningRefresh(afterResultGeneration: gen)"))
        XCTAssertTrue(liveModeEngine.contains("cancelLiveActivityListeningRefresh()"))
        XCTAssertTrue(liveModeEngine.contains("Task.sleep(for: .milliseconds(2500))"))
        XCTAssertTrue(liveModeEngine.contains("正在搜索相关信息，请稍等。"))
        XCTAssertTrue(liveModeEngine.contains("已检索到相关信息，正在整理答案。"))
        XCTAssertTrue(liveModeEngine.contains("已收到指令，请稍等。"))
        XCTAssertTrue(liveModeUI.contains("liveProgressHeadline"))
        XCTAssertTrue(liveActivityWidget.contains("case .thinking, .searching: return \"思考\""))
        XCTAssertTrue(liveActivityWidget.contains("case .responding: return \"回应\""))
        XCTAssertTrue(liveActivityWidget.contains("case .starting, .thinking, .searching, .executing, .responding:"))
        XCTAssertTrue(liveWarmPool.contains("agentEngine: AgentEngine"))
        XCTAssertTrue(liveWarmPool.contains("engine.setup(inference: inference, agentEngine: agentEngine)"))
        XCTAssertFalse(liveWarmPool.contains("engine.setup(inference: inference)\n"))

        // LIVE must not rebuild tool arguments from ASR text. The ASR text is handed to
        // AgentEngine; Router/PromptBuilder/ToolChain remain the only Skill execution path.
        XCTAssertFalse(liveModeUI.contains("calendar-create-event\", \"arguments\""))
        XCTAssertFalse(liveModeUI.contains("reminders-create\", \"arguments\""))
        XCTAssertFalse(liveModeEngine.contains("calendar-create-event\", \"arguments\""))
        XCTAssertFalse(liveModeEngine.contains("reminders-create\", \"arguments\""))
        XCTAssertFalse(liveModeEngine.contains("LiveTurnProcessor("))
        XCTAssertFalse(liveModeEngine.contains("LiveSkillRouter"))
        XCTAssertFalse(liveModeEngine.contains("liveSkillRegistry"))
    }

    func testLiveDoesNotForceLiteRTLiveConversationForMainAgentMode() throws {
        let processor = try source("Live/Turn/LiveTurnProcessor.swift")
        let foundation = try source("Live/Turn/IOS27LiveFoundationTokenSource.swift")
        let liveModeEngine = try source("Live/Core/LiveModeEngine.swift")

        XCTAssertTrue(liveModeEngine.contains("guard agentEngine != nil"))
        XCTAssertFalse(liveModeEngine.contains("try await inference.enterLiveMode(systemPrompt: liveSystemPrompt)"))
        XCTAssertTrue(liveModeEngine.contains("didEnterLLMLiveMode = false"))
        XCTAssertTrue(liveModeEngine.contains("if didEnterLLMLiveMode"))

        // The older LIVE-local token source remains available as a non-default path, but
        // production LIVE from ContentView now passes AgentEngine and therefore uses MAIN.
        XCTAssertTrue(processor.contains("LiveTurnProcessor"))
        XCTAssertTrue(foundation.contains("#if canImport(FoundationModels)"))
        XCTAssertTrue(foundation.contains("if #available(iOS 27.0, macOS 26.0, *)"))

        // FM source must not introduce a second domain-specific Skill understanding layer.
        XCTAssertFalse(foundation.lowercased().contains("calendar"))
        XCTAssertFalse(foundation.lowercased().contains("reminder"))
        XCTAssertFalse(foundation.lowercased().contains("web-search"))
    }
}
