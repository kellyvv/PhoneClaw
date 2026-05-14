import CoreImage
import Foundation
#if canImport(UIKit)
import UIKit
// 跨平台 image 类型别名 —— iOS 真编 UIKit 路径, macOS CLI 自动走 CIImage.
// AgentEngine 的 processInput(images:) 签名用这个别名, 调用端在各自平台用
// 自己的自然类型; iOS 二进制行为零改变 (UIImage == PlatformImage).
typealias PlatformImage = UIImage
#else
// macOS CLI: 不测图像输入场景, PlatformImage 只是签名占位.
typealias PlatformImage = CIImage
#endif

func log(_ message: String) {
    print(message)
}

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    static let selectedModelDefaultsKey = "PhoneClaw.selectedModelID"
    static let enableThinkingDefaultsKey = "PhoneClaw.enableThinking"
    static let preferredBackendDefaultsKey = "PhoneClaw.preferredBackend"
    static let enableSpeculativeDecodingDefaultsKey = "PhoneClaw.enableSpeculativeDecoding"

    // 采样参数不再暴露给用户调节 — 跟 KV cache = 2048 的现实对齐:
    //   maxTokens 1500 留 ~500 给输入; topK/topP/temperature 用 Gemma 4 推荐默认。
    var maxTokens = 1500
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? ModelDescriptor.defaultModel.id
    /// 推理后端偏好: `"gpu"` (Metal) 或 `"cpu"` (默认). 只 LiteRT 后端有意义;
    /// MLX / 其他后端忽略。切换后会 reload 引擎 (~3-7s), 具体 UX 见 ConfigurationsView。
    /// 默认 CPU: Sideloadly 免费签名的 App 内存上限较低, GPU + E4B 的 Metal buffer
    /// 会 OOM; CPU 更稳妥, 用户可按需切到 GPU。
    var preferredBackend: String = UserDefaults.standard.string(forKey: preferredBackendDefaultsKey)
        ?? "cpu"
    /// Gemma 4 MTP speculative decoding 开关。仅 LiteRT + Gemma 4 (.litertlm 含
    /// mtp_drafter section) 上有效。开启后 drafter 占 ~300-400 MB pinned RAM。
    /// 当前 V1 sampler 仅在 sequence_size=1 路径正确，sequence_size>1 时会跑诊断
    /// dump (一次性，stderr) 帮助定位 verifier logits 实际 layout。默认关闭。
    var enableSpeculativeDecoding: Bool = UserDefaults.standard.bool(forKey: enableSpeculativeDecodingDefaultsKey)
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
//
// 按当前语言从 PromptLocale 取. zh 版字节相同于原硬编码文本 (已经
// PromptLocale foundation commit 里做过 diff 验证), en 版翻译结构对齐。
// 用 var computed 而非 let: 保证用户切换语言后新生成的 SYSPROMPT.md
// 默认内容跟着变 (仅对 "文件不存在" 的首次写入有效, 已有 SYSPROMPT.md
// 不会被覆盖, 除非走到旧版模板的 migration 路径).
private var kDefaultSystemPrompt: String { PromptLocale.current.defaultSystemPromptAgent }

// MARK: - Hotfix Flags / Planning / Observability

private enum HotfixFlagKey: String {
    case useHotfixPromptPipeline = "PHONECLAW_USE_HOTFIX_PROMPT_PIPELINE"
    case enablePreflightBudget = "ENABLE_PREFLIGHT_BUDGET"
    case enableCanonicalToolResult = "ENABLE_CANONICAL_TOOL_RESULT"
    case enableHistoryTrim = "ENABLE_HISTORY_TRIM"
    case enableMultimodalSessionGroup = "ENABLE_MULTIMODAL_SESSION_GROUP"
    case enableImageFollowUpRegrounding = "ENABLE_IMAGE_FOLLOWUP_REGROUNDING"
}

enum HotfixFeatureFlags {
    static var useHotfixPromptPipeline: Bool {
        value(for: .useHotfixPromptPipeline, defaultValue: true)
    }

    static var enablePreflightBudget: Bool {
        value(for: .enablePreflightBudget, defaultValue: true)
    }

    static var enableCanonicalToolResult: Bool {
        value(for: .enableCanonicalToolResult, defaultValue: true)
    }

    static var enableHistoryTrim: Bool {
        value(for: .enableHistoryTrim, defaultValue: true)
    }

    static var enableMultimodalSessionGroup: Bool {
        value(for: .enableMultimodalSessionGroup, defaultValue: true)
    }

    static var enableImageFollowUpRegrounding: Bool {
        value(for: .enableImageFollowUpRegrounding, defaultValue: true)
    }

    private static func value(for key: HotfixFlagKey, defaultValue: Bool) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[key.rawValue] {
            switch raw.lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        if UserDefaults.standard.object(forKey: key.rawValue) != nil {
            return UserDefaults.standard.bool(forKey: key.rawValue)
        }

        return defaultValue
    }
}

private protocol ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision
}

private struct LegacyBudgetPlanner: ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision {
        let stats = ConversationMemoryPolicy.legacyHistoryStats(
            from: history,
            historyDepth: historyDepth
        )
        let estimatedPromptTokens = max(1, Int((Double(prompt.count) / 4.0).rounded(.up)))
        let reservedOutputTokens = min(maxOutputTokens, capabilities.defaultReservedOutputTokens)
        return BudgetDecision(
            estimatedPromptTokens: estimatedPromptTokens,
            reservedOutputTokens: reservedOutputTokens,
            historyMessagesIncluded: stats.messageCount,
            historyCharsIncluded: stats.characterCount
        )
    }
}

private struct HotfixBudgetPlanner: ContextBudgetPlanner {
    func makeDecision(
        prompt: String,
        capabilities: ModelCapabilities,
        history: [ChatMessage],
        historyDepth: Int,
        maxOutputTokens: Int
    ) -> BudgetDecision {
        let stats = ConversationMemoryPolicy.hotfixHistoryStats(
            fromPlanningHistory: history,
            historyDepth: historyDepth
        )
        let estimatedPromptTokens = max(1, Int((Double(prompt.count) / 4.0).rounded(.up)))
        let reservedOutputTokens = min(maxOutputTokens, capabilities.defaultReservedOutputTokens)
        return BudgetDecision(
            estimatedPromptTokens: estimatedPromptTokens,
            reservedOutputTokens: reservedOutputTokens,
            historyMessagesIncluded: stats.messageCount,
            historyCharsIncluded: stats.characterCount
        )
    }
}

private struct ConversationMemoryPolicy {
    struct LegacyHistoryStats: Equatable {
        let messageCount: Int
        let characterCount: Int
    }

    static func legacyHistorySlice(
        from history: [ChatMessage],
        historyDepth: Int
    ) -> ArraySlice<ChatMessage> {
        history.suffix(historyDepth)
    }

    static func legacyHistoryStats(
        from history: [ChatMessage],
        historyDepth: Int
    ) -> LegacyHistoryStats {
        let recentHistory = legacyHistorySlice(from: history, historyDepth: historyDepth)
        let lastUserID = recentHistory.last(where: { $0.role == .user })?.id

        var messageCount = 0
        var characterCount = 0

        for message in recentHistory {
            if message.role == .user, message.id == lastUserID {
                continue
            }
            messageCount += 1
            characterCount += message.content.count
        }

        return LegacyHistoryStats(
            messageCount: messageCount,
            characterCount: characterCount
        )
    }

    static func planningHistory(
        from priorHistory: [ChatMessage],
        currentUser: ChatMessage
    ) -> [ChatMessage] {
        priorHistory + [currentUser]
    }

    static func hotfixHistoryStats(
        fromPlanningHistory history: [ChatMessage],
        historyDepth: Int
    ) -> LegacyHistoryStats {
        let recentHistory = history.suffix(historyDepth)
        let effectiveHistory: ArraySlice<ChatMessage>
        if recentHistory.last?.role == .user {
            effectiveHistory = recentHistory.dropLast()
        } else {
            effectiveHistory = recentHistory
        }

        return LegacyHistoryStats(
            messageCount: effectiveHistory.count,
            characterCount: effectiveHistory.reduce(0) { $0 + $1.content.count }
        )
    }

    static func nextTrimmedPriorHistory(from priorHistory: [ChatMessage]) -> [ChatMessage]? {
        guard !priorHistory.isEmpty else { return nil }

        if let skillResultIndex = priorHistory.firstIndex(where: { $0.role == .skillResult }) {
            var trimmed = priorHistory
            let message = trimmed[skillResultIndex]
            if let toolName = message.skillName {
                let summary = canonicalToolResult(toolName: toolName, toolResult: message.content).summary
                let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedDetail = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSummary.isEmpty && normalizedSummary != normalizedDetail {
                    trimmed[skillResultIndex].update(content: normalizedSummary)
                    return trimmed
                }
            }
            trimmed.remove(at: skillResultIndex)
            return trimmed
        }

        let protectedAssistantIndex = priorHistory.lastIndex(where: { $0.role == .assistant })

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant
                && $0 != protectedAssistantIndex
                && priorHistory[$0].content.count > 240
        }) {
            var trimmed = priorHistory
            trimmed[assistantIndex].update(
                content: truncatedAssistantContent(trimmed[assistantIndex].content)
            )
            return trimmed
        }

        if let assistantIndex = priorHistory.indices.first(where: {
            priorHistory[$0].role == .assistant && $0 != protectedAssistantIndex
        }) {
            var trimmed = priorHistory
            trimmed.remove(at: assistantIndex)
            return trimmed
        }

        if let dropRange = oldestDroppableTurnRange(
            in: priorHistory,
            protectedAssistantIndex: protectedAssistantIndex
        ) {
            var trimmed = priorHistory
            trimmed.removeSubrange(dropRange)
            return trimmed
        }

        return nil
    }

    private static func truncatedAssistantContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        let prefix = String(trimmed.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }

    private static func oldestDroppableTurnRange(
        in priorHistory: [ChatMessage],
        protectedAssistantIndex: Int?
    ) -> Range<Int>? {
        let userIndices = priorHistory.indices.filter { priorHistory[$0].role == .user }
        guard !userIndices.isEmpty else { return nil }

        let protectedIndex = protectedAssistantIndex ?? Int.max
        for (offset, userIndex) in userIndices.enumerated() {
            let nextUserIndex = offset + 1 < userIndices.count
                ? userIndices[offset + 1]
                : priorHistory.count
            if nextUserIndex <= protectedIndex {
                return userIndex..<nextUserIndex
            }
        }

        return nil
    }
}

private struct HotfixTurnObservation: Codable, Equatable {
    let prompt_shape: String
    let session_group: String
    let session_reset_reason: String
    let estimated_prompt_tokens: Int
    let reserved_output_tokens: Int
    let history_messages_included: Int
    let history_chars_included: Int
    let kv_prefill_tokens: Int
    let preflight_hard_reject: Bool
    let timestamp_ms: Int64
}

private struct HotfixTurnObservationRingBuffer {
    private(set) var items: [HotfixTurnObservation] = []
    private let capacity = 10

    mutating func append(_ item: HotfixTurnObservation) {
        items.append(item)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    func recent(_ count: Int) -> ArraySlice<HotfixTurnObservation> {
        items.suffix(count)
    }
}

    private struct RecentImageFollowUpContext {
        let attachments: [ChatImageAttachment]
        var assistantSummary: String
        var remainingTextFollowUps: Int
    }

    private enum ImageFollowUpRoute {
        case normalText
        case imageText
        case reMultimodal
    }

private extension PromptPlan {
    var sessionResetReason: SessionResetReason {
        switch reuseDecision {
        case .reuse:
            return .normalContinuation
        case .reset(let reason):
            return reason
        }
    }
}

private extension HotfixTurnObservation {
    func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// MARK: - Agent Engine

@Observable
class AgentEngine {

    static let currentSessionDefaultsKey = "PhoneClaw.currentSessionID"

    let inference: InferenceService
    let catalog: ModelCatalog
    let installer: ModelInstaller
    let coordinator: ModelRuntimeCoordinator
    var messages: [ChatMessage] = [] {
        didSet {
            scheduleSessionSave()
        }
    }
    var isProcessing = false
    private var didSetup = false
    var config = ModelConfig()
    var sessionSummaries: [ChatSessionSummary] = []
    var currentSessionID = UUID()

    // 文件驱动的 Skill 系统
    let skillRegistry = SkillRegistry()
    let toolRegistry = ToolRegistry.shared
    let toolResultCanonicalizer: ToolResultCanonicalizer

    // Skill 条目（给 UI 管理用，可开关）
    var skillEntries: [SkillEntry] = []

    let sessionsDirectoryName = "Sessions"
    let sessionsIndexFileName = "sessions_index.json"
    let plannerRevision = "planner-v3-local-selection"
    var sessionSaveTask: Task<Void, Never>?

    // 暴露给 CLI ScenarioRunner — 它需要知道每轮 Router 实际匹配到了哪些 skill
    // (含 sticky), 才能对 YAML scenario 的 `skills:` 断言. iOS UI 完全不读这个,
    // 所以暴露成普通 var 没有任何运行时影响.
    var lastTurnMatchedSkillIds: [String] = []
    private let legacyContextBudgetPlanner: ContextBudgetPlanner
    private let hotfixContextBudgetPlanner: ContextBudgetPlanner
    private var promptObservationBuffer = HotfixTurnObservationRingBuffer()
    private var previousPromptShape: PromptShape?
    private var previousSessionGroup: SessionGroup?
    private var recentImageFollowUpContexts: [RecentImageFollowUpContext] = []


    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon,
                     type: $0.type, requiresTimeAnchor: $0.requiresTimeAnchor,
                     samplePrompt: $0.samplePrompt,
                     chipPrompt: $0.chipPrompt,
                     chipLabel: $0.chipLabel)
        }
    }

    var availableModels: [ModelDescriptor] {
        catalog.availableModels
    }

    init(
        inference: InferenceService? = nil,
        catalog: ModelCatalog? = nil,
        installer: ModelInstaller? = nil
    ) {
        // LiteRT 是 iOS-only (xcframework 没有 macOS slice)。Mac harness / CLI
        // 编译时 LiteRTLMSwift 不在作用域, 相应的 LiteRTCatalog / LiteRTBackend /
        // LiteRTModelStore 也被 SwiftPM target 配置 exclude。
        //
        // iOS 分支: 默认 fallback 创建 LiteRT 实例 (历史行为不变)。
        // 非 iOS 分支: 要求调用方必须显式注入 catalog/installer/inference,
        //              CLI 本来就总是注入, 不受影响。
        #if canImport(PhoneClawEngine)
        let resolvedCatalog: ModelCatalog = catalog ?? LiteRTCatalog()
        let resolvedInstaller: ModelInstaller = installer ?? LiteRTModelStore()
        #else
        guard let resolvedCatalog = catalog,
              let resolvedInstaller = installer else {
            fatalError("AgentEngine: non-LiteRT build requires explicit catalog + installer injection")
        }
        #endif
        self.catalog = resolvedCatalog
        self.installer = resolvedInstaller
        self.legacyContextBudgetPlanner = LegacyBudgetPlanner()
        self.hotfixContextBudgetPlanner = HotfixBudgetPlanner()
        self.toolResultCanonicalizer = LegacyToolCanonicalizer()

        if let inference {
            self.inference = inference
        } else {
            #if canImport(PhoneClawEngine)
            // callbacks 闭包捕获 resolvedCatalog — 和 self.catalog 是同一个对象,
            // 无论调用方注入哪种 ModelCatalog 实现都能正确同步 loadedModel.
            let liteRT = LiteRTBackend(
                modelPathResolver: { modelID in
                    guard let desc = resolvedCatalog.availableModels.first(where: { $0.id == modelID }) else { return nil }
                    return resolvedInstaller.artifactPath(for: desc)
                },
                onModelLoaded: { [weak resolvedCatalog] modelID in
                    if let cat = resolvedCatalog,
                       let desc = cat.availableModels.first(where: { $0.id == modelID }) {
                        cat.markLoaded(desc)
                    }
                },
                onModelUnloaded: { [weak resolvedCatalog] in
                    resolvedCatalog?.markUnloaded()
                }
            )

            // MiniCPM-V backend: bundleResolver 从 descriptor.companionFiles 找
            // 真实文件名 (按 CompanionRole 查), 不再硬编码命名约定。这样下载链路
            // 跟加载链路的真相源都在 PredefinedModels.swift, 改一处即两端同步。
            //
            // 历史 (这里特别说一下, 不踩同样的坑): 上一版按 OpenBMB demo 的命名
            // 约定硬编码 `MiniCPM-V-4_6-mmproj-f16.gguf`, 但 OBS bucket 上的真
            // 名字是 `mmproj-model-f16.gguf`。手 sideload 时能跑 (因为按硬编码名
            // 放), UI 下载链路就炸 (下载到 OBS 真名字, resolver 找硬编码名找不到)。
            // 现在按 role + descriptor.fileName 来, 哪边变了改一行就行。
            let miniCPMV = MiniCPMVBackend(bundleResolver: { modelID in
                guard let desc = resolvedCatalog.availableModels.first(where: { $0.id == modelID }),
                      desc.artifactKind == .ggufBundle,
                      let llmPath = resolvedInstaller.artifactPath(for: desc) else {
                    return nil
                }
                let baseDir = llmPath.deletingLastPathComponent()

                // 必需: mmproj — descriptor 里 role == .multimodalProjector 的 companion。
                // 没声明就直接 nil (load 阶段会给清晰错误信息)。
                guard let mmprojCompanion = desc.companionFiles.first(where: { $0.role == .multimodalProjector }) else {
                    return nil
                }
                let mmprojCanonicalPath = baseDir.appendingPathComponent(mmprojCompanion.localResourceName)

                // Backward compat: 上一版用 hardcoded "MiniCPM-V-4_6-mmproj-f16.gguf"
                // (跟 OpenBMB demo 命名一致), sideload 用户可能本地是这个名字。
                // 新下载链路按 OBS 真名 "mmproj-model-f16.gguf" 落盘。两个都尝试,
                // 哪个先在就用哪个 — 让历史 sideload 用户不需要重命名。
                let mmprojLegacyPath = baseDir.appendingPathComponent("MiniCPM-V-4_6-mmproj-f16.gguf")
                let mmprojPath: URL
                if FileManager.default.fileExists(atPath: mmprojCanonicalPath.path) {
                    mmprojPath = mmprojCanonicalPath
                } else if FileManager.default.fileExists(atPath: mmprojLegacyPath.path) {
                    mmprojPath = mmprojLegacyPath
                } else {
                    return nil
                }

                // 可选: CoreML ANE vision encoder — role == .coreMLVisionEncoder。
                // 缺失或文件不存在都允许, backend 自己 fallback 到 llama.cpp 走 vision
                // (慢, 但单图 chat 至少能跑)。
                let resolvedCoreml: URL? = desc.companionFiles
                    .first(where: { $0.role == .coreMLVisionEncoder })
                    .map { baseDir.appendingPathComponent($0.localResourceName) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

                return MTMDPathBundle(
                    modelPath: llmPath,
                    mmprojPath: mmprojPath,
                    coremlPath: resolvedCoreml
                )
            })

            self.inference = BackendDispatcher(
                liteRT: liteRT,
                miniCPMV: miniCPMV,
                modelLookup: { modelID in
                    resolvedCatalog.availableModels.first(where: { $0.id == modelID })
                }
            )
            #else
            fatalError("AgentEngine: non-LiteRT build requires explicit inference injection")
            #endif
        }

        self.coordinator = ModelRuntimeCoordinator(
            inference: self.inference,
            installer: resolvedInstaller
        )

        loadSkillEntries()
        currentSessionID =
            UUID(uuidString: UserDefaults.standard.string(forKey: Self.currentSessionDefaultsKey) ?? "")
            ?? UUID()
    }

    func loadSkillEntries() {
        let definitions = skillRegistry.discoverSkills()
        self.skillEntries = definitions.map { SkillEntry(from: $0, registry: toolRegistry) }
    }

    func reloadSkills() {
        let enabledState = Dictionary(uniqueKeysWithValues: skillEntries.map { ($0.id, $0.isEnabled) })
        loadSkillEntries()
        for i in skillEntries.indices {
            if let wasEnabled = enabledState[skillEntries[i].id] {
                skillEntries[i].isEnabled = wasEnabled
                skillRegistry.setEnabled(skillEntries[i].id, enabled: wasEnabled)
            }
        }
    }

    // MARK: - Skill 查找（文件驱动）

    func findSkillId(for name: String) -> String? {
        let resolvedName = skillRegistry.canonicalSkillId(for: name)
        if skillRegistry.getDefinition(resolvedName) != nil { return resolvedName }
        return skillRegistry.findSkillId(forTool: name)
    }

    func findDisplayName(for name: String) -> String {
        if let skillId = findSkillId(for: name),
           let def = skillRegistry.getDefinition(skillId) {
            return def.metadata.displayName
        }
        return name
    }

    func requiresTimeAnchor(forSkillId skillId: String) -> Bool {
        skillRegistry.getDefinition(skillId)?.metadata.requiresTimeAnchor == true
    }

    func requiresTimeAnchor(forSkillIds skillIds: [String]) -> Bool {
        skillIds.contains { requiresTimeAnchor(forSkillId: $0) }
    }

    func handleLoadSkill(skillName: String) -> String? {
        let resolvedSkillName = skillRegistry.canonicalSkillId(for: skillName)
        guard let entry = skillEntries.first(where: { $0.id == resolvedSkillName }),
              entry.isEnabled else {
            return nil
        }
        return skillRegistry.loadBody(skillId: resolvedSkillName)
    }

    func handleToolExecution(toolName: String, args: [String: Any]) async throws -> String {
        return try await toolRegistry.execute(name: toolName, args: args)
    }

    func handleToolExecutionCanonical(
        toolName: String,
        args: [String: Any]
    ) async throws -> CanonicalToolResult {
        try await toolRegistry.executeCanonical(name: toolName, args: args)
    }

    // MARK: - 初始化

    /// ConfigurationsView 的"Restore default"按钮使用。
    var defaultSystemPrompt: String { kDefaultSystemPrompt }

    func setup() {
        guard !didSetup else { return }
        didSetup = true

        applyModelSelection()
        installer.refreshInstallStates()
        loadSystemPrompt()       // 从 SYSPROMPT.md 注入 system prompt
        loadPersistedSessions()
        applySamplingConfig()
        // MTP 偏好需要在 coordinator.load() 之前同步 — coordinator 内部不管 MTP,
        // 但 inference.load() 读取这个设置来构造 engine.
        inference.setEnableSpeculativeDecoding(config.enableSpeculativeDecoding)
        Task {
            // Coordinator handles: setPreferredBackend → inference.load
            // 同时维护 RuntimeSessionState: idle → loading → ready | failed
            try? await coordinator.load(
                modelID: config.selectedModelID,
                backend: config.preferredBackend
            )
        }
    }

    // MARK: - SYSPROMPT 注入

    /// 从 ApplicationSupport/PhoneClaw/SYSPROMPT.md 读取 system prompt。
    /// 文件不存在时自动写入 kDefaultSystemPrompt（供用户后续编辑）。
    /// 两种自动迁移:
    /// 1. 缺新占位符且仍有旧 `___SKILLS___` → 备份后覆盖
    /// 2. **Locale 不匹配**: 文件内容**字节相同于** zh/en 的 PromptLocale 默认,
    ///    但跟当前 locale 的默认不一致 → 备份后覆盖成当前 locale 默认. 这样
    ///    zh 设备装过 app 再切到 en, 或反过来, 会自动把未编辑的默认 prompt
    ///    换成当前语言; 用户手动编辑过的内容 (跟两种 default 都不一致)
    ///    不会被碰.
    func loadSystemPrompt() {
        let fm = FileManager.default
        guard let supportDir = fm.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first else { return }
        let dir  = supportDir.appendingPathComponent("PhoneClaw", isDirectory: true)
        let file = dir.appendingPathComponent("SYSPROMPT.md")

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: file.path),
           let content = try? String(contentsOf: file, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            // 旧版模板检测: 缺新占位符且仍然包含旧扁平占位符 → 备份后覆盖
            let hasNewPlaceholders = content.contains("___DEVICE_SKILLS___")
                || content.contains("___CONTENT_SKILLS___")
            let hasOldPlaceholder = content.contains("___SKILLS___")

            // Locale-mismatch 检测: 内容恰好是 zh 或 en 的默认 prompt
            // (用户从未编辑过), 且跟当前 locale default 不一致 → 自动迁移。
            let current = kDefaultSystemPrompt
            let zhDefault = PromptLocale.zhHans.defaultSystemPromptAgent
            let enDefault = PromptLocale.en.defaultSystemPromptAgent
            let isUnmodifiedDefault = (content == zhDefault) || (content == enDefault)
            let localeMismatch = isUnmodifiedDefault && (content != current)

            if !hasNewPlaceholders && hasOldPlaceholder {
                let backup = dir.appendingPathComponent("SYSPROMPT.md.bak")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: file, to: backup)
                try? current.write(to: file, atomically: true, encoding: .utf8)
                config.systemPrompt = current
                print("[Agent] SYSPROMPT migrated: 旧模板已备份到 SYSPROMPT.md.bak, 新默认已写入")
            } else if localeMismatch {
                let backup = dir.appendingPathComponent("SYSPROMPT.md.bak")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: file, to: backup)
                try? current.write(to: file, atomically: true, encoding: .utf8)
                config.systemPrompt = current
                print("[Agent] SYSPROMPT locale migrated to \(LanguageService.shared.current.resolved.rawValue), 旧文件备份到 SYSPROMPT.md.bak")
            } else {
                config.systemPrompt = content
                print("[Agent] SYSPROMPT loaded (\(content.count) chars)")
            }
        } else {
            try? kDefaultSystemPrompt.write(to: file, atomically: true, encoding: .utf8)
            config.systemPrompt = kDefaultSystemPrompt
            print("[Agent] SYSPROMPT not found — default written to \(file.path)")
        }
    }

    func applySamplingConfig() {
        inference.samplingTopK = config.topK
        inference.samplingTopP = Float(config.topP)
        inference.samplingTemperature = Float(config.temperature)
        inference.maxOutputTokens = config.maxTokens
        UserDefaults.standard.set(
            config.enableThinking,
            forKey: ModelConfig.enableThinkingDefaultsKey
        )
    }

    @discardableResult
    func applyModelSelection() -> Bool {
        UserDefaults.standard.set(
            config.selectedModelID,
            forKey: ModelConfig.selectedModelDefaultsKey
        )
        return catalog.select(modelID: config.selectedModelID)
    }

    func reloadModel() {
        let selectedModelID = config.selectedModelID
        let backend = config.preferredBackend
        let speculative = config.enableSpeculativeDecoding
        // 持久化用户选择 — 单一入口, 任何 caller (ConfigurationsView.applySettings,
        // 未来其它切模型路径) 调 reloadModel 后, UserDefaults 自动同步,
        // 下次 app 启动 ModelConfig.selectedModelID 能恢复正确值.
        UserDefaults.standard.set(
            selectedModelID,
            forKey: ModelConfig.selectedModelDefaultsKey
        )
        UserDefaults.standard.set(
            backend,
            forKey: ModelConfig.preferredBackendDefaultsKey
        )
        UserDefaults.standard.set(
            speculative,
            forKey: ModelConfig.enableSpeculativeDecodingDefaultsKey
        )
        Task { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            _ = self.catalog.select(modelID: selectedModelID)
            // MTP 偏好需要在 coordinator.load() 之前同步 — coordinator 内部不管 MTP,
            // 但 inference.load() 读取这个设置来构造 engine.
            self.inference.setEnableSpeculativeDecoding(speculative)
            // Coordinator handles: unload (if needed) → setPreferredBackend → load
            // 同时维护 RuntimeSessionState 状态机转移.
            try? await self.coordinator.load(
                modelID: selectedModelID,
                backend: backend
            )
        }
    }

    private var selectedModelCapabilities: ModelCapabilities {
        catalog.selectedModel.capabilities
    }

    private func promptShape(
        requiresMultimodal: Bool,
        shouldUseFullAgentPrompt: Bool,
        canUseDelta: Bool
    ) -> PromptShape {
        if requiresMultimodal {
            return .multimodal
        }
        if config.enableThinking {
            return .thinking
        }
        if shouldUseFullAgentPrompt {
            return .agentFull
        }
        return canUseDelta ? .lightDelta : .lightFull
    }

    private func sessionGroup(for shape: PromptShape) -> SessionGroup {
        switch shape {
        case .multimodal:
            return .multimodal
        case .live:
            return .live
        case .lightFull, .lightDelta, .agentFull, .toolFollowup, .thinking:
            return .text
        }
    }

    private func reuseDecision(
        for nextShape: PromptShape,
        nextGroup: SessionGroup
    ) -> ReuseDecision {
        guard let previousShape = previousPromptShape,
              let previousSessionGroup else {
            return .reset(.firstTurn)
        }

        guard previousSessionGroup == nextGroup else {
            switch nextGroup {
            case .text:
                return .reset(.enterText)
            case .multimodal:
                return .reset(.enterMultimodal)
            case .live:
                return .reset(.enterLive)
            }
        }

        switch (previousShape, nextShape) {
        case (.lightFull, .lightDelta),
             (.lightDelta, .lightDelta),
             (.toolFollowup, .toolFollowup),
             (.thinking, .thinking):
            return .reuse
        case (.agentFull, .toolFollowup):
            return .reuse
        case (.lightFull, .lightFull),
             (.lightDelta, .lightFull):
            return .reset(.systemChanged)
        case (.agentFull, .agentFull):
            return .reset(.toolSchemaChanged)
        case (.thinking, .lightFull),
             (.thinking, .lightDelta),
             (.lightFull, .thinking),
             (.lightDelta, .thinking):
            return .reset(.thinkingToggle)
        default:
            return .reset(.shapeChanged)
        }
    }

    private func makePromptPlan(
        prompt: String,
        shape: PromptShape,
        history: [ChatMessage],
        historyDepth: Int
    ) -> PromptPlan {
        let sessionGroup = sessionGroup(for: shape)
        let budgetDecision = activeContextBudgetPlanner.makeDecision(
            prompt: prompt,
            capabilities: selectedModelCapabilities,
            history: history,
            historyDepth: historyDepth,
            maxOutputTokens: inference.maxOutputTokens
        )
        let reuseDecision = reuseDecision(for: shape, nextGroup: sessionGroup)
        return PromptPlan(
            shape: shape,
            sessionGroup: sessionGroup,
            prompt: prompt,
            budgetDecision: budgetDecision,
            reuseDecision: reuseDecision
        )
    }

    private var activeContextBudgetPlanner: ContextBudgetPlanner {
        if HotfixFeatureFlags.useHotfixPromptPipeline && HotfixFeatureFlags.enablePreflightBudget {
            return hotfixContextBudgetPlanner
        }
        return legacyContextBudgetPlanner
    }

    private func exceedsSafeContextBudget(_ decision: BudgetDecision) -> Bool {
        decision.estimatedPromptTokens + decision.reservedOutputTokens
            > selectedModelCapabilities.safeContextBudgetTokens
    }

    private func buildTextPromptBundle(
        priorHistory: [ChatMessage],
        normalizedText: String,
        shouldUsePlanner: Bool,
        shouldUseFullAgentPrompt: Bool,
        includeTimeAnchor: Bool,
        includeImageHistoryMarkers: Bool,
        imageFollowUpBridgeSummary: String?,
        activeSkillInfos: [SkillInfo],
        matchedSkillIdsForTurn: [String],
        preloadedSkills: [PromptBuilder.PreloadedSkill],
        currentUserMessage: ChatMessage
    ) -> (
        lightPrompt: String,
        agentPrompt: String?,
        plannerInputPrompt: String,
        streamingPrompt: String,
        canUseDelta: Bool,
        streamingPlanningHistory: [ChatMessage]
    ) {
        let lightHistory = shouldUsePlanner ? [] : priorHistory
        let lightPrompt = PromptBuilder.buildLightweightTextPrompt(
            userMessage: normalizedText,
            history: lightHistory,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: lightHistory.count,
            includeImageHistoryMarkers: includeImageHistoryMarkers,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary
        )
        let agentPrompt: String? = shouldUseFullAgentPrompt ? PromptBuilder.build(
            userMessage: normalizedText,
            currentImageCount: 0,
            tools: activeSkillInfos,
            includeTimeAnchor: includeTimeAnchor,
            includeImageHistoryMarkers: includeImageHistoryMarkers,
            imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
            history: priorHistory,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: priorHistory.count,
            showListSkillsHint: matchedSkillIdsForTurn.isEmpty,
            preloadedSkills: preloadedSkills
        ) : nil

        let canUseDelta = inference.kvSessionActive
            && inference.sessionHasContext
            && agentPrompt == nil

        let streamingPrompt: String
        if canUseDelta {
            streamingPrompt = PromptBuilder.buildDeltaTurnPrompt(
                userMessage: normalizedText,
                currentImageCount: 0,
                enableThinking: config.enableThinking
            )
        } else {
            streamingPrompt = agentPrompt ?? lightPrompt
        }

        let streamingPriorHistory = agentPrompt != nil ? priorHistory : lightHistory
        return (
            lightPrompt: lightPrompt,
            agentPrompt: agentPrompt,
            plannerInputPrompt: lightPrompt,
            streamingPrompt: streamingPrompt,
            canUseDelta: canUseDelta,
            streamingPlanningHistory: ConversationMemoryPolicy.planningHistory(
                from: streamingPriorHistory,
                currentUser: currentUserMessage
            )
        )
    }

    private func clearRecentImageFollowUpContexts() {
        recentImageFollowUpContexts.removeAll()
    }

    private func sameImageAttachments(
        _ lhs: [ChatImageAttachment],
        _ rhs: [ChatImageAttachment]
    ) -> Bool {
        lhs.map(\.id) == rhs.map(\.id)
    }

    private func recordRecentImageFollowUpContext(
        attachments: [ChatImageAttachment],
        assistantSummary: String
    ) {
        guard !attachments.isEmpty else { return }
        let normalizedSummary = assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = RecentImageFollowUpContext(
            attachments: attachments,
            assistantSummary: normalizedSummary,
            remainingTextFollowUps: 3
        )

        if let first = recentImageFollowUpContexts.first,
           sameImageAttachments(first.attachments, attachments) {
            recentImageFollowUpContexts[0] = context
        } else {
            recentImageFollowUpContexts.insert(context, at: 0)
            if recentImageFollowUpContexts.count > 3 {
                recentImageFollowUpContexts.removeLast(recentImageFollowUpContexts.count - 3)
            }
        }
    }

    private func latestActiveImageFollowUpContext() -> RecentImageFollowUpContext? {
        guard HotfixFeatureFlags.useHotfixPromptPipeline,
              HotfixFeatureFlags.enableImageFollowUpRegrounding else {
            return nil
        }

        return recentImageFollowUpContexts.first(where: { $0.remainingTextFollowUps > 0 })
    }

    private func consumeActiveImageFollowUpContext() {
        guard !recentImageFollowUpContexts.isEmpty else { return }
        recentImageFollowUpContexts[0].remainingTextFollowUps -= 1
        if recentImageFollowUpContexts[0].remainingTextFollowUps <= 0 {
            recentImageFollowUpContexts.removeFirst()
        }
    }

    private func classifyImageFollowUpRoute(
        assistantSummary: String,
        userQuestion: String
    ) async -> ImageFollowUpRoute {
        let prompt = PromptBuilder.buildImageFollowUpDecisionPrompt(
            assistantSummary: assistantSummary,
            userQuestion: userQuestion
        )

        let savedTopK = inference.samplingTopK
        let savedTopP = inference.samplingTopP
        let savedTemperature = inference.samplingTemperature
        let savedMaxOutputTokens = inference.maxOutputTokens

        inference.samplingTopK = 1
        inference.samplingTopP = 1.0
        inference.samplingTemperature = 0
        inference.maxOutputTokens = min(savedMaxOutputTokens, 8)
        defer {
            inference.samplingTopK = savedTopK
            inference.samplingTopP = savedTopP
            inference.samplingTemperature = savedTemperature
            inference.maxOutputTokens = savedMaxOutputTokens
        }

        let rawDecision = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            inference.generate(
                prompt: prompt,
                onToken: { _ in },
                onComplete: { result in
                    switch result {
                    case .success(let text):
                        continuation.resume(returning: text)
                    case .failure(let error):
                        log("[ImageFollowUp] decision failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            )
        }

        await inference.resetKVSession()

        guard let rawDecision else { return .normalText }
        let normalized = rawDecision.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.contains("RE_MULTIMODAL") {
            return .reMultimodal
        }
        if normalized.contains("IMAGE_TEXT") {
            return .imageText
        }
        if normalized.contains("NORMAL_TEXT") {
            return .normalText
        }
        if normalized.contains("YES") {
            return .reMultimodal
        }
        if normalized.contains("NO") {
            return .imageText
        }

        log("[ImageFollowUp] decision fallback=NORMAL_TEXT raw=\"\(rawDecision)\"")
        return .normalText
    }

    private func needsImageFollowUpTextRepair(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let completedSuffixes = ["。", "！", "？", ".", "!", "?"]
        if completedSuffixes.contains(where: { trimmed.hasSuffix($0) }) {
            return false
        }

        let incompleteSuffixes = ["、", "，", ",", "：", ":", "；", ";", "（", "("]
        if incompleteSuffixes.contains(where: { trimmed.hasSuffix($0) }) {
            return true
        }

        return true
    }

    private func imageFollowUpFallbackReply(
        from draft: String,
        assistantSummary: String
    ) -> String {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedDraft.isEmpty, !needsImageFollowUpTextRepair(trimmedDraft) {
            return trimmedDraft
        }

        if !trimmedSummary.isEmpty {
            return trimmedSummary
        }

        if trimmedDraft.isEmpty {
            return PromptLocale.current.cannotDetermineFromLastImage
        }

        // 结尾补全句号. zh 用 "。", en 用 ".".
        let terminator = tr("。", ".")
        if trimmedDraft.hasSuffix("、")
            || trimmedDraft.hasSuffix("，")
            || trimmedDraft.hasSuffix(",")
            || trimmedDraft.hasSuffix("：")
            || trimmedDraft.hasSuffix(":")
            || trimmedDraft.hasSuffix("；")
            || trimmedDraft.hasSuffix(";") {
            return String(trimmedDraft.dropLast()) + terminator
        }

        return trimmedDraft + terminator
    }

    private func streamImageFollowUpStableReply(
        cleanedDraft: String,
        assistantSummary: String,
        userQuestion: String,
        msgIndex: Int
    ) async -> String {
        let trimmedDraft = cleanedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else {
            return imageFollowUpFallbackReply(from: cleanedDraft, assistantSummary: assistantSummary)
        }

        let repairPrompt = PromptBuilder.buildImageFollowUpRepairPrompt(
            userMessage: userQuestion,
            assistantSummary: assistantSummary,
            partialAnswer: trimmedDraft,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking
        )
        log("[ImageFollowUp] repair=triggered")

        let savedTopK = inference.samplingTopK
        let savedTopP = inference.samplingTopP
        let savedTemperature = inference.samplingTemperature
        let savedMaxOutputTokens = inference.maxOutputTokens

        inference.samplingTopK = 1
        inference.samplingTopP = 1.0
        inference.samplingTemperature = 0
        inference.maxOutputTokens = min(savedMaxOutputTokens, 48)
        defer {
            inference.samplingTopK = savedTopK
            inference.samplingTopP = savedTopP
            inference.samplingTemperature = savedTemperature
            inference.maxOutputTokens = savedMaxOutputTokens
        }

        let repairedRaw = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var buffer = ""
            var toolCallDetected = false
            var bufferFlushed = false

            inference.generate(
                prompt: repairPrompt,
                onToken: { [weak self] token in
                    guard let self = self,
                          self.messages.indices.contains(msgIndex) else { return }

                    if toolCallDetected {
                        buffer += token
                        return
                    }

                    buffer += token

                    if buffer.contains("<tool_call>") {
                        toolCallDetected = true
                        return
                    }

                    if !bufferFlushed {
                        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        bufferFlushed = true
                    }

                    let cleaned = self.cleanOutputStreaming(buffer)
                    if !cleaned.isEmpty {
                        self.messages[msgIndex].update(content: cleaned)
                    }
                },
                onComplete: { result in
                    switch result {
                    case .success(let text):
                        log("[Agent] LLM raw: \(text.prefix(300))")
                        continuation.resume(returning: text)
                    case .failure(let error):
                        log("[ImageFollowUp] repair failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            )
        }
        await inference.resetKVSession()

        guard let repairedRaw else {
            log("[ImageFollowUp] repair failed, using fallback")
            return imageFollowUpFallbackReply(from: trimmedDraft, assistantSummary: assistantSummary)
        }

        if parseToolCall(repairedRaw) != nil {
            log("[ImageFollowUp] repair produced tool_call, using fallback")
            return imageFollowUpFallbackReply(from: trimmedDraft, assistantSummary: assistantSummary)
        }

        let repaired = cleanOutput(repairedRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repaired.isEmpty else {
            return imageFollowUpFallbackReply(from: trimmedDraft, assistantSummary: assistantSummary)
        }

        if needsImageFollowUpTextRepair(repaired) {
            log("[ImageFollowUp] repair still incomplete, using fallback")
            return imageFollowUpFallbackReply(from: repaired, assistantSummary: assistantSummary)
        }

        return repaired
    }

    private func kvPrefillTokensForCurrentTurn() -> Int {
        // 协议默认实现返回 0 (无 KV 能力的后端); LiteRTBackend 覆写成真实值。
        inference.lastKVPrefillTokens
    }

    private func recordCompletedObservation(
        plan: PromptPlan,
        advancePromptPipelineState: Bool = true,
        preflightHardReject: Bool = false,
        tokenCapHit: Bool = false,
        memoryFloorHit: Bool = false
    ) {
        let observation = HotfixTurnObservation(
            prompt_shape: plan.shape.rawValue,
            session_group: plan.sessionGroup.rawValue,
            session_reset_reason: plan.sessionResetReason.rawValue,
            estimated_prompt_tokens: plan.budgetDecision.estimatedPromptTokens,
            reserved_output_tokens: plan.budgetDecision.reservedOutputTokens,
            history_messages_included: plan.budgetDecision.historyMessagesIncluded,
            history_chars_included: plan.budgetDecision.historyCharsIncluded,
            kv_prefill_tokens: kvPrefillTokensForCurrentTurn(),
            preflight_hard_reject: preflightHardReject,
            timestamp_ms: Int64(Date().timeIntervalSince1970 * 1000)
        )
        promptObservationBuffer.append(observation)
        if advancePromptPipelineState {
            previousPromptShape = plan.shape
            previousSessionGroup = plan.sessionGroup
        }

        if tokenCapHit
            || memoryFloorHit
            || plan.sessionResetReason != .normalContinuation
            || preflightHardReject {
            for item in promptObservationBuffer.recent(3) {
                log("[Hotfix] \(item.jsonLine())")
            }
        }
    }

    private func classifyTokenCapHit(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("max number of tokens reached")
    }

    private func classifyMemoryFloorHit(_ error: Error) -> Bool {
        if let backendError = error as? ModelBackendError,
           case .memoryRisk = backendError {
            return true
        }

        let message = error.localizedDescription
        return message.contains("当前剩余内存")
            || message.localizedCaseInsensitiveContains("headroom")
            || message.localizedCaseInsensitiveContains("memory risk")
    }

    func resetPromptPipelineState() {
        previousPromptShape = nil
        previousSessionGroup = nil
    }

    private func prepareSessionGroupTransitionIfNeeded(for plan: PromptPlan) async {
        guard HotfixFeatureFlags.useHotfixPromptPipeline,
              HotfixFeatureFlags.enableMultimodalSessionGroup else {
            return
        }
        await inference.prepareForSessionGroupTransition(
            from: previousSessionGroup,
            to: plan.sessionGroup
        )
    }

    func permissionStatuses() -> [AppPermissionKind: AppPermissionStatus] {
        toolRegistry.allPermissionStatuses()
    }

    func requestPermission(_ kind: AppPermissionKind) async -> AppPermissionStatus {
        do {
            _ = try await toolRegistry.requestAccess(for: kind)
        } catch {
            log("[Permission] \(kind.rawValue) request failed: \(error.localizedDescription)")
        }
        return toolRegistry.authorizationStatus(for: kind)
    }

    // MARK: - 处理用户输入（流式输出）

    func processInput(
        _ text: String,
        images: [PlatformImage] = [],
        audio: AudioCaptureSnapshot? = nil,
        replayImageAttachments: [ChatImageAttachment]? = nil,
        attachReplayImagesToMessage: Bool = true
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmed
        let inputAttachments = images.compactMap(ChatImageAttachment.init(image:))
        let displayAttachments = replayImageAttachments != nil && !attachReplayImagesToMessage
            ? inputAttachments
            : (replayImageAttachments ?? inputAttachments)
        var promptAttachments = replayImageAttachments ?? inputAttachments
        let audioClips = audio.flatMap(ChatAudioAttachment.init(snapshot:)).map { [$0] } ?? []
        let audioInput = audio.map(AudioInput.from(snapshot:))
        let normalizedText: String
        if trimmed.isEmpty, !promptAttachments.isEmpty {
            normalizedText = PromptLocale.current.describeImagePromptFallback
        } else if audio != nil {
            // 有音频就无脑前缀 anchor — E2B/E4B 小模型会把 "这是什么？" 之类短 prompt
            // 当成问它自己, 给出 Gemma 自我介绍模板. 空 text 补一个默认意图作为填充,
            // 不再分两个音频分支。偶尔出现的 "关于这段音频：请转写音频" 式轻微冗余可
            // 接受, 胜过维护一套硬编 anchor 词表。
            let intent = trimmed.isEmpty ? PromptLocale.current.transcribeAudioIntentFallback : trimmed
            normalizedText = String(format: PromptLocale.current.audioContextFormat, intent)
        } else {
            normalizedText = trimmed
        }
        guard !isProcessing else { return }
        guard !normalizedText.isEmpty || !promptAttachments.isEmpty || audioInput != nil else { return }
        isProcessing = true

        let currentUserMessage = ChatMessage(
            role: .user,
            content: displayText,
            images: displayAttachments,
            audios: audioClips
        )
        messages.append(currentUserMessage)

        var requiresMultimodal = !promptAttachments.isEmpty || audioInput != nil
        var imageFollowUpBridgeSummary: String?
        var forceImageFollowUpTextPrompt = false
        let pendingImageFollowUpContext = !requiresMultimodal ? latestActiveImageFollowUpContext() : nil
        var earlyAssistantPlaceholderIndex: Int?
        if pendingImageFollowUpContext != nil {
            messages.append(ChatMessage(role: .assistant, content: "▍"))
            earlyAssistantPlaceholderIndex = messages.count - 1
        }
        if !requiresMultimodal,
           let recentImageContext = pendingImageFollowUpContext {
            let followUpRoute = await classifyImageFollowUpRoute(
                assistantSummary: recentImageContext.assistantSummary,
                userQuestion: normalizedText
            )
            switch followUpRoute {
            case .reMultimodal:
                promptAttachments = recentImageContext.attachments
                requiresMultimodal = true
                log("[ImageFollowUp] route=re_multimodal")
            case .imageText:
                imageFollowUpBridgeSummary = recentImageContext.assistantSummary
                forceImageFollowUpTextPrompt = true
                log("[ImageFollowUp] route=image_text")
            case .normalText:
                log("[ImageFollowUp] route=normal_text")
            }
            consumeActiveImageFollowUpContext()
        }

        applySamplingConfig()

        let matchedSkillIdsForTurn = requiresMultimodal ? [] : matchedSkillIds(for: normalizedText)
        // 暴露给 CLI harness (ScenarioRunner) 做断言. iOS UI 不读, 0 行为影响.
        self.lastTurnMatchedSkillIds = matchedSkillIdsForTurn
        // T2 (2026-04-17): 把 Planner 入口从 matched>=2 降到 matched>=1.
        //
        // 动机: Router 的 substring trigger 命中存在大量边界 fail (e.g. 用户说
        // "评审会"但 trigger 是"会议", 用户说"查王总电话"但 trigger 是"查电话"),
        // 漏掉一个 skill → planner 没被触发 → 多 skill 任务退化成单 skill agent 路径,
        // T2c-revert (2026-04-17): 恢复 matched>=2 门槛.
        //
        // T2c 把门槛从 >=2 改成 >=1, 让 Selection LLM 每轮都跑.
        // 真机验证: Selection 每次 ~1400 tok 全量 prefill (KV hit 4-6%),
        // E4B 稳态 headroom ~1000-1200 MB, 多轮必崩 (jetsam).
        // 且 Selection 实际表现: matched=1 返回同一个 skill (白跑),
        // matched=2 返回子集 (比 Router 更差). 收益 < 0, 风险 = jetsam.
        //
        // 回到 >=2: 单 skill 直接 agent 路径, 不进 Planner, 不跑 Selection.
        let shouldUsePlanner = !requiresMultimodal && matchedSkillIdsForTurn.count >= 2
        let shouldUseFullAgentPrompt =
            !requiresMultimodal
            && shouldUseToolingPrompt(for: normalizedText)
        let activeSkillInfos: [SkillInfo]
        if shouldUseFullAgentPrompt {
            if matchedSkillIdsForTurn.isEmpty {
                activeSkillInfos = enabledSkillInfos
            } else {
                let selectedIds = Set(matchedSkillIdsForTurn)
                let matchedInfos = enabledSkillInfos.filter { selectedIds.contains($0.name) }
                activeSkillInfos = matchedInfos.isEmpty ? enabledSkillInfos : matchedInfos
            }
        } else {
            activeSkillInfos = []
        }
        let policy = catalog.runtimePolicy(for: catalog.selectedModel.id)
        let headroomMB = Double(MemoryStats.headroomMB)
        let historyDepth = requiresMultimodal ? 0 : policy.safeHistoryDepth(headroomMB: headroomMB)
        let plannerHistoryDepth = shouldUsePlanner ? 0 : historyDepth
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: promptAttachments)

        let routedPath = Self.decideRoute(
            requiresMultimodal: requiresMultimodal,
            shouldUsePlanner: shouldUsePlanner,
            shouldUseFullAgentPrompt: shouldUseFullAgentPrompt
        )
        PCLog.turn(
            route: routedPath,
            skillCount: matchedSkillIdsForTurn.count,
            multimodal: requiresMultimodal,
            inputChars: text.count,
            historyDepth: historyDepth,
            headroomMB: MemoryStats.headroomMB
        )

        // Tag 这条 assistant placeholder 的 skillName, 让 sticky routing 在
        // 下一轮追问时能识别上下文 (即使本轮 LLM 没调 tool 只是澄清).
        //
        // 只对 type: device 的 skill 打 tag — content skill (如 translate)
        // 是一问一答的纯变换, 它的 assistant reply 代表"已完成", 不应该让
        // 下一轮闲聊被 sticky 粘回去翻译。框架在这里按 skill metadata 决定,
        // 不硬编具体 skill 名, 也不感知模型。
        let stickyEligibleSkillID: String? = {
            guard let id = matchedSkillIdsForTurn.first,
                  let def = skillRegistry.getDefinition(id) else { return nil }
            return def.metadata.type == .device ? id : nil
        }()

        if requiresMultimodal {
            let msgIndex: Int
            if let existingIndex = earlyAssistantPlaceholderIndex,
               messages.indices.contains(existingIndex) {
                msgIndex = existingIndex
            } else {
                messages.append(ChatMessage(role: .assistant, content: "▍", skillName: stickyEligibleSkillID))
                msgIndex = messages.count - 1
            }
            // Pure-vision path 默认返回空 system prompt (见 PromptBuilder.multimodalSystemPrompt),
            // 空字符串时跳过 .system(...) 注入, 让 Gemma 4 只看 image + user text,
            // 避免任何 system 框架把小模型带进"请提供图片"漂移.
            let systemPrompt = PromptBuilder.multimodalSystemPrompt(
                hasImages: !promptImages.isEmpty,
                hasAudio: audioInput != nil,
                enableThinking: config.enableThinking
            )
            let multimodalPlan = makePromptPlan(
                prompt: systemPrompt.isEmpty ? normalizedText : systemPrompt + "\n" + normalizedText,
                shape: .multimodal,
                history: messages,
                historyDepth: 0
            )
            await prepareSessionGroupTransitionIfNeeded(for: multimodalPlan)
            var multimodalBuffer = ""

            inference.generateMultimodal(
                images: promptImages,
                audios: audioInput.map { [$0] } ?? [],
                prompt: normalizedText,
                systemPrompt: systemPrompt
            ) { [weak self] token in
                guard let self = self,
                      self.messages.indices.contains(msgIndex) else { return }
                multimodalBuffer += token
                let cleaned = self.cleanOutputStreaming(multimodalBuffer)
                self.messages[msgIndex].update(content: (cleaned.isEmpty ? "" : cleaned) + "▍")
            } onComplete: { [weak self] result in
                guard let self = self else { return }
                defer { self.isProcessing = false }
                guard self.messages.indices.contains(msgIndex) else { return }
                switch result {
                case .success(let fullText):
                    #if DEBUG
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    #endif
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned
                    )
                    self.recordRecentImageFollowUpContext(
                        attachments: promptAttachments,
                        assistantSummary: cleaned.isEmpty ? fullText : cleaned
                    )
                    self.recordCompletedObservation(plan: multimodalPlan)
                case .failure(let error):
                    log("[Agent] multimodal failed: \(error.localizedDescription)")
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    self.recordCompletedObservation(
                        plan: multimodalPlan,
                        tokenCapHit: self.classifyTokenCapHit(error),
                        memoryFloorHit: self.classifyMemoryFloorHit(error)
                    )
                }
            }
            return
        }

        // Router 确定性匹配到的 skill: 预加载 tool 调用 schema + 工具白名单,
        // 让模型在 round 1 就看到 schema, 跳过 load_skill 往返。对小模型
        // (E2B/E4B) 效果显著 — 避免它们在"要不要 load_skill"这种主观判断上翻车。
        //
        // Path 1-B (2026-04-17): memory-aware degradation.
        //   - 内存富余 (HARNESS Mac, 真机第一轮): 用完整 SKILL body, 保留所有
        //     行为细则 (追问逻辑, 跨轮合并, 多 tool 内部路由).
        //   - 内存吃紧 (真机第 2/3 轮起, headroom < 1500 MB): 退化到 compactSchema,
        //     ~200 chars/SKILL, 牺牲行为细节换 prefill 内存峰值, 避免 jetsam.
        //
        // 不是规则, 是 memory-pressure-aware degradation —— 跟 jetsam 共生的
        // 工程实践. 阈值 1500 MB 是经验值 (E4B 单次 prefill ~700MB 峰值 + safety).
        let useCompactSchema = MemoryStats.headroomMB < 1500
        if useCompactSchema {
            log("[Agent] preload compact schema (headroom=\(MemoryStats.headroomMB) MB < 1500)")
        }
        let turnRequiresTimeAnchor = requiresTimeAnchor(forSkillIds: matchedSkillIdsForTurn)
        let includeImageHistoryMarkers =
            HotfixFeatureFlags.useHotfixPromptPipeline
            && HotfixFeatureFlags.enableImageFollowUpRegrounding
        let preloadedSkills: [PromptBuilder.PreloadedSkill] = matchedSkillIdsForTurn.compactMap { id in
            guard let body = skillRegistry.loadBody(skillId: id),
                  let def = skillRegistry.getDefinition(id) else { return nil }
            let registered = registeredTools(for: id)
            let toolTuples = registered.map { (name: $0.name, description: $0.description, parameters: $0.parameters, requiredParameters: $0.requiredParameters) }
            let compact = PromptBuilder.PreloadedSkill.makeCompactSchema(
                skillName: def.metadata.name,
                tools: toolTuples
            )
            // 当 headroom 充裕, 把 body 同时塞进 compactSchema 字段, prompt 用的就是 body
            // (零行为变化). 当 headroom 紧, compactSchema 是真紧凑版本, prompt 用紧凑.
            return PromptBuilder.PreloadedSkill(
                id: id,
                displayName: def.metadata.name,
                body: body,
                allowedTools: def.metadata.allowedTools,
                compactSchema: useCompactSchema ? compact : body
            )
        }

        // T2 (2026-04-17): 当 matched>=1, planner 和 agent 路径同时可能跑.
        // - Planner 入参用 LIGHT prompt (它内部只取 system block, 大 agent prompt
        //   会让 plan JSON 翻车 — E4B 在 3.6K char 输入下截断).
        // - 落回单 skill streaming 用 agent prompt (含 preloaded SKILL body, 能调 tool).
        let basePriorHistory = Array(messages.dropLast().suffix(historyDepth))
        var promptBundle: (
            lightPrompt: String,
            agentPrompt: String?,
            plannerInputPrompt: String,
            streamingPrompt: String,
            canUseDelta: Bool,
            streamingPlanningHistory: [ChatMessage]
        )
        if forceImageFollowUpTextPrompt, let imageFollowUpBridgeSummary {
            let imageFollowUpTextPrompt = PromptBuilder.buildImageFollowUpTextPrompt(
                userMessage: normalizedText,
                assistantSummary: imageFollowUpBridgeSummary,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking
            )
            promptBundle = (
                lightPrompt: imageFollowUpTextPrompt,
                agentPrompt: nil,
                plannerInputPrompt: imageFollowUpTextPrompt,
                streamingPrompt: imageFollowUpTextPrompt,
                canUseDelta: false,
                streamingPlanningHistory: []
            )
        } else {
            promptBundle = buildTextPromptBundle(
                priorHistory: basePriorHistory,
                normalizedText: normalizedText,
                shouldUsePlanner: shouldUsePlanner,
                shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
                includeTimeAnchor: turnRequiresTimeAnchor,
                includeImageHistoryMarkers: includeImageHistoryMarkers,
                imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
                activeSkillInfos: activeSkillInfos,
                matchedSkillIdsForTurn: matchedSkillIdsForTurn,
                preloadedSkills: preloadedSkills,
                currentUserMessage: currentUserMessage
            )
        }
        let textPromptShape = promptShape(
            requiresMultimodal: false,
            shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
            canUseDelta: promptBundle.canUseDelta
        )
        var textPromptPlan = makePromptPlan(
            prompt: promptBundle.streamingPrompt,
            shape: textPromptShape,
            history: promptBundle.streamingPlanningHistory,
            historyDepth: promptBundle.streamingPlanningHistory.count
        )
        if HotfixFeatureFlags.useHotfixPromptPipeline
            && HotfixFeatureFlags.enablePreflightBudget
            && !shouldUsePlanner
            && !promptBundle.canUseDelta {
            var trimmedPriorHistory = basePriorHistory
            while exceedsSafeContextBudget(textPromptPlan.budgetDecision) {
                guard HotfixFeatureFlags.enableHistoryTrim,
                      let nextTrimmedHistory = ConversationMemoryPolicy.nextTrimmedPriorHistory(
                        from: trimmedPriorHistory
                      ) else {
                    let hardRejectMessage = PromptLocale.current.hardRejectContextTooLong
                    if let existingIndex = earlyAssistantPlaceholderIndex,
                       messages.indices.contains(existingIndex) {
                        messages[existingIndex].update(role: .system, content: hardRejectMessage)
                    } else {
                        messages.append(ChatMessage(role: .system, content: hardRejectMessage))
                    }
                    recordCompletedObservation(
                        plan: textPromptPlan,
                        advancePromptPipelineState: false,
                        preflightHardReject: true
                    )
                    isProcessing = false
                    return
                }

                trimmedPriorHistory = nextTrimmedHistory
                if forceImageFollowUpTextPrompt, let imageFollowUpBridgeSummary {
                    let imageFollowUpTextPrompt = PromptBuilder.buildImageFollowUpTextPrompt(
                        userMessage: normalizedText,
                        assistantSummary: imageFollowUpBridgeSummary,
                        systemPrompt: config.systemPrompt,
                        enableThinking: config.enableThinking
                    )
                    promptBundle = (
                        lightPrompt: imageFollowUpTextPrompt,
                        agentPrompt: nil,
                        plannerInputPrompt: imageFollowUpTextPrompt,
                        streamingPrompt: imageFollowUpTextPrompt,
                        canUseDelta: false,
                        streamingPlanningHistory: []
                    )
                } else {
                    promptBundle = buildTextPromptBundle(
                        priorHistory: trimmedPriorHistory,
                        normalizedText: normalizedText,
                        shouldUsePlanner: shouldUsePlanner,
                        shouldUseFullAgentPrompt: shouldUseFullAgentPrompt,
                        includeTimeAnchor: turnRequiresTimeAnchor,
                        includeImageHistoryMarkers: includeImageHistoryMarkers,
                        imageFollowUpBridgeSummary: imageFollowUpBridgeSummary,
                        activeSkillInfos: activeSkillInfos,
                        matchedSkillIdsForTurn: matchedSkillIdsForTurn,
                        preloadedSkills: preloadedSkills,
                        currentUserMessage: currentUserMessage
                    )
                }
                textPromptPlan = makePromptPlan(
                    prompt: promptBundle.streamingPrompt,
                    shape: textPromptShape,
                    history: promptBundle.streamingPlanningHistory,
                    historyDepth: promptBundle.streamingPlanningHistory.count
                )
            }
        }
        let agentPrompt = promptBundle.agentPrompt
        let lightPrompt = promptBundle.lightPrompt
        let plannerInputPrompt = promptBundle.plannerInputPrompt
        let streamingPrompt = promptBundle.streamingPrompt
        let canUseDelta = promptBundle.canUseDelta
        if canUseDelta {
            log("[Agent] KV cache delta mode: \(streamingPrompt.count) chars (vs full \(lightPrompt.count) chars)")
        }
        await prepareSessionGroupTransitionIfNeeded(for: textPromptPlan)
        #if DEBUG
        log("[Agent] text prompt mode=\(shouldUseFullAgentPrompt ? "agent" : "light"), planner-input-chars=\(plannerInputPrompt.count), streaming-chars=\(streamingPrompt.count), skills=\(activeSkillInfos.count)")
        #endif

        let msgIndex: Int
        if let existingIndex = earlyAssistantPlaceholderIndex,
           messages.indices.contains(existingIndex) {
            msgIndex = existingIndex
        } else {
            messages.append(ChatMessage(role: .assistant, content: "▍", skillName: stickyEligibleSkillID))
            msgIndex = messages.count - 1
        }

        if shouldUsePlanner {
            log("[Agent] planner path triggered revision=\(plannerRevision)")
            let plannerHandled = await executePlannedSkillChainIfPossible(
                prompt: plannerInputPrompt,
                userQuestion: normalizedText,
                images: promptImages
            )

            if plannerHandled {
                if messages.indices.contains(msgIndex),
                   messages[msgIndex].role == .assistant,
                   messages[msgIndex].content == "▍" {
                    messages.remove(at: msgIndex)
                }
                return
            }

            // T2 (2026-04-17): planner 未处理 (Selection LLM 判定真单 skill) →
            // 不显示错误, 沉默地落回单 skill agent 路径 (placeholder ▍ 还在,
            // 下面 streaming 代码会填充).
            log("[Agent] planner not handled, falling back to single-skill agent path")
        }

        var detectedToolCall = false
        var buffer = ""
        var bufferFlushed = false

        inference.generate(
            prompt: streamingPrompt,
            onToken: { [weak self] token in
                guard let self = self,
                      self.messages.indices.contains(msgIndex) else { return }

                if detectedToolCall {
                    buffer += token
                    return
                }

                buffer += token

                if buffer.contains("<tool_call>") {
                    detectedToolCall = true
                    return
                }

                if forceImageFollowUpTextPrompt {
                    return
                }

                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                    self.messages[msgIndex].update(content: self.cleanOutputStreaming(buffer))
                    return
                }

                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty {
                self.messages[msgIndex].update(content: cleaned)
                }
            },
            onComplete: { [weak self] result in
                guard let self = self else { return }
                guard self.messages.indices.contains(msgIndex) else {
                    self.isProcessing = false
                    return
                }
                switch result {
                case .success(let fullText):
                    #if DEBUG
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    #endif

                    if self.parseToolCall(fullText) != nil {
                        self.messages[msgIndex].update(content: "")
                        self.recordCompletedObservation(plan: textPromptPlan)
                        Task {
                            await self.executeToolChain(
                                prompt: streamingPrompt,
                                fullText: fullText,
                                userQuestion: normalizedText,
                                images: promptImages
                            )
                        }
                        return
                    } else {
                        let cleaned = self.cleanOutput(fullText)
                        self.recordCompletedObservation(plan: textPromptPlan)
                        if forceImageFollowUpTextPrompt,
                           let imageFollowUpBridgeSummary,
                           !cleaned.isEmpty {
                            Task { [weak self] in
                                guard let self else { return }
                                let repaired = await self.streamImageFollowUpStableReply(
                                    cleanedDraft: cleaned,
                                    assistantSummary: imageFollowUpBridgeSummary,
                                    userQuestion: normalizedText,
                                    msgIndex: msgIndex
                                )
                                await MainActor.run {
                                    if self.messages.indices.contains(msgIndex) {
                                        self.messages[msgIndex].update(
                                            content: repaired.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : repaired
                                        )
                                    }
                                    self.isProcessing = false
                                }
                            }
                            return
                        }
                        self.messages[msgIndex].update(
                            content: cleaned.isEmpty ? PromptLocale.current.emptyReplyPlaceholder : cleaned
                        )
                        self.isProcessing = false
                    }
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    self.recordCompletedObservation(
                        plan: textPromptPlan,
                        tokenCapHit: self.classifyTokenCapHit(error),
                        memoryFloorHit: self.classifyMemoryFloorHit(error)
                    )
                    self.isProcessing = false
                }
            }
        )
    }

    // MARK: - Skill 结果后的后续推理（支持多轮工具链）

    func streamLLM(prompt: String, images: [CIImage]) async -> String? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            inference.generate(
                prompt: prompt,
                onToken: { _ in },
                onComplete: { result in
                    switch result {
                    case .success(let text):
                        log("[Agent] LLM raw: \(text.prefix(300))")
                        continuation.resume(returning: text)
                    case .failure(let error):
                        log("[Agent] LLM failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            )
        }
    }

    func streamLLM(prompt: String, msgIndex: Int, images: [CIImage]) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false
            inference.generate(
                prompt: prompt,
                onToken: { [weak self] token in
                    guard let self = self,
                          self.messages.indices.contains(msgIndex) else { return }
                    buffer += token

                if toolCallDetected { return }
                if buffer.contains("<tool_call>") {
                    toolCallDetected = true
                    if bufferFlushed && self.messages[msgIndex].role == .assistant {
                        self.messages[msgIndex].update(content: "")
                    }
                    return
                }

                if !bufferFlushed {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return }
                    if "<tool_call>".hasPrefix(trimmed) { return }
                    bufferFlushed = true
                }

                let cleaned = self.cleanOutputStreaming(buffer)
                if !cleaned.isEmpty && self.messages[msgIndex].role == .assistant {
                    self.messages[msgIndex].update(content: cleaned)
                }
            },
            onComplete: { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    if self.messages.indices.contains(msgIndex) {
                        self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    }
                    continuation.resume(returning: nil)
                }
            }
            )
        }
    }

    // MARK: - 工具

    func clearMessages() {
        startNewSession()
    }

    func cancelActiveGeneration() {
        guard isProcessing || inference.isGenerating else { return }
        inference.cancel()
        isProcessing = false

        if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
            let content = messages[lastAssistant].content.replacingOccurrences(of: "▍", with: "")
            messages[lastAssistant].update(content: content.isEmpty ? PromptLocale.current.cancelledReplyPlaceholder : content)
        }

        log("[Agent] Generation cancelled")
    }

    private func promptImages(
        historyDepth: Int,
        currentImages: [ChatImageAttachment]
    ) -> [CIImage] {
        _ = historyDepth
        return Array(currentImages.prefix(1).compactMap(\.ciImage))
    }

    func startNewSession() {
        flushPendingSessionSave()
        if isProcessing || inference.isGenerating {
            cancelActiveGeneration()
        }
        resetPromptPipelineState()
        clearRecentImageFollowUpContexts()
        currentSessionID = UUID()
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = []
        // Reset KV cache for new conversation.
        // 若 engine 带了多模态 encoder (上一个会话发过图/音频导致 sticky
        // 到 multimodal), 新对话默认回到 text-only — 释放 ~800 MB.
        // 下次发图再走 lazy reload 回来.
        Task { [inference] in
            await inference.revertToTextOnly()
            await inference.resetKVSession()
        }
    }

    func loadSession(id: UUID) {
        guard id != currentSessionID || messages.isEmpty else { return }
        flushPendingSessionSave()
        if isProcessing || inference.isGenerating {
            cancelActiveGeneration()
        }
        guard let record = loadSessionRecord(id: id) else { return }
        resetPromptPipelineState()
        clearRecentImageFollowUpContexts()
        currentSessionID = id
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = record.messages
        // Reset KV cache — loaded session has no cached context.
        // 切到其他会话时也顺便回 text-only — 被切出来的会话之前可能 sticky
        // 在 multimodal, 现在进的会话有没有图待定, 先释放 800 MB, 进来若发图再升级.
        Task { [inference] in
            await inference.revertToTextOnly()
            await inference.resetKVSession()
        }
        updateSessionSummary(
            .init(
                id: record.id,
                title: record.title,
                preview: record.preview,
                updatedAt: record.updatedAt
            )
        )
    }

    func deleteSession(id: UUID) {
        flushPendingSessionSave()
        do {
            try FileManager.default.removeItem(at: sessionFileURL(for: id))
        } catch {
            log("[History] delete failed: \(error.localizedDescription)")
        }
        sessionSummaries.removeAll { $0.id == id }
        persistSessionsIndex()

        if currentSessionID == id {
            sessionSaveTask?.cancel()
            sessionSaveTask = nil

            if let next = sessionSummaries.first,
               let record = loadSessionRecord(id: next.id) {
                resetPromptPipelineState()
                clearRecentImageFollowUpContexts()
                currentSessionID = next.id
                UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
                messages = record.messages
            } else {
                resetPromptPipelineState()
                clearRecentImageFollowUpContexts()
                currentSessionID = UUID()
                UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
                messages = []
            }
        }
    }

    func flushPendingSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        saveCurrentSession()
    }

    func setAllSkills(enabled: Bool) {
        for i in skillEntries.indices {
            skillEntries[i].isEnabled = enabled
        }
    }

    // MARK: - 解析

    private func extractSkillName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"name\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[nameRange])
    }

    // MARK: - 重试

    /// 重试最后一轮用户输入。直接复用已持久化的附件数据，不重新编码。
    func retryLastResponse() async {
        guard !isProcessing, inference.isLoaded else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let userMsg = messages[lastUserIndex]
        // 含音频的轮次不支持重试（AudioCaptureSnapshot 是一次性数据，无法从 WAV 反向构造）
        guard userMsg.audios.isEmpty else { return }

        let text = userMsg.content
        let imageAttachments = userMsg.images
        // 截断：移除该用户消息及之后所有消息
        messages.removeSubrange(lastUserIndex...)
        resetPromptPipelineState()
        // 重试时: 如果要 replay 的消息没有图 (纯文本重试), 先释放多模态 encoder
        // 回 text-only. 有图则保持当前 engine 状态 — 反正下面 processInput 会通过
        // generateMultimodal 走 ensureEngineMode(.multimodal) 升级.
        if imageAttachments.isEmpty {
            await inference.revertToTextOnly()
        }
        await inference.resetKVSession()
        // 重新走 processInput，复用已持久化的 ChatImageAttachment，避免二次 JPEG 编码
        await processInput(text, replayImageAttachments: imageAttachments)
    }
}
