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

    var maxTokens = 4000
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? ModelDescriptor.defaultModel.id
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
private let kDefaultSystemPrompt = """
你是 PhoneClaw，一个运行在本地设备上的私人 AI 助手。你完全离线运行，不联网，保护用户隐私。

你拥有以下两类能力（Skill）：

【设备操作类】（访问 iPhone 硬件或系统数据）
___DEVICE_SKILLS___

【内容处理类】（对文字做变换：翻译/总结/改写 等）
___CONTENT_SKILLS___

调用规则：

▶ 设备操作类 skill：
  - 只有用户明确要求执行某项设备操作时，才调用 load_skill。
  - "配置""信息""看看""帮我查一下"这类含糊词，不足以触发。
  - 闲聊、追问上文、解释已有结果时不调用。

▶ 内容处理类 skill：
  - 只要用户意图是对文字做该类变换（翻译/总结/改写 等），立即调用 load_skill。
  - 即使用户用了"这段""刚才那段""上面"等指代词且没贴出源文本，也必须先调用 load_skill。
    加载后的指令会告诉你如何从对话历史中定位源文本。**不要**先反问用户。

▶ 普通闲聊、追问设备操作结果、解释已经输出的内容：直接回答，不要调用任何 skill。

调用格式：
<tool_call>
{"name": "load_skill", "arguments": {"skill": "能力名"}}
</tool_call>

加载 skill 之后请按其指令执行；拿到工具结果后优先直接给最终答案，不要无谓追问。
用中文回答，简洁实用。
"""

// MARK: - Agent Engine

@Observable
class AgentEngine {

    static let currentSessionDefaultsKey = "PhoneClaw.currentSessionID"

    let inference: InferenceService
    let catalog: ModelCatalog
    let installer: ModelInstaller
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


    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon,
                     type: $0.type, samplePrompt: $0.samplePrompt,
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
        let resolvedCatalog = catalog ?? LiteRTCatalog()
        let resolvedInstaller = installer ?? LiteRTModelStore()
        self.catalog = resolvedCatalog
        self.installer = resolvedInstaller

        if let inference {
            self.inference = inference
        } else {
            // callbacks 闭包捕获 resolvedCatalog — 和 self.catalog 是同一个对象,
            // 无论调用方注入哪种 ModelCatalog 实现都能正确同步 loadedModel.
            self.inference = LiteRTBackend(
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
        }

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
        Task {
            try? await inference.load(modelID: config.selectedModelID)
        }
    }

    // MARK: - SYSPROMPT 注入

    /// 从 ApplicationSupport/PhoneClaw/SYSPROMPT.md 读取 system prompt。
    /// 文件不存在时自动写入 kDefaultSystemPrompt（供用户后续编辑）。
    /// 如果文件存在但缺少新的 ___DEVICE_SKILLS___ / ___CONTENT_SKILLS___ 占位符,
    /// 视为旧版自动生成的模板, 备份后用新默认覆盖。
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

            if !hasNewPlaceholders && hasOldPlaceholder {
                let backup = dir.appendingPathComponent("SYSPROMPT.md.bak")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: file, to: backup)
                try? kDefaultSystemPrompt.write(to: file, atomically: true, encoding: .utf8)
                config.systemPrompt = kDefaultSystemPrompt
                print("[Agent] SYSPROMPT migrated: 旧模板已备份到 SYSPROMPT.md.bak, 新默认已写入")
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
        // 持久化用户选择 — 单一入口, 任何 caller (ConfigurationsView.applySettings,
        // 未来其它切模型路径) 调 reloadModel 后, UserDefaults 自动同步,
        // 下次 app 启动 ModelConfig.selectedModelID 能恢复正确值.
        UserDefaults.standard.set(
            selectedModelID,
            forKey: ModelConfig.selectedModelDefaultsKey
        )
        Task { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            _ = self.catalog.select(modelID: selectedModelID)
            self.inference.unload()
            try? await self.inference.load(modelID: selectedModelID)
        }
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
        replayImageAttachments: [ChatImageAttachment]? = nil
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = trimmed
        let attachments = replayImageAttachments ?? images.compactMap(ChatImageAttachment.init(image:))
        let audioClips = audio.flatMap(ChatAudioAttachment.init(snapshot:)).map { [$0] } ?? []
        let audioInput = audio.map(AudioInput.from(snapshot:))
        let normalizedText: String
        if trimmed.isEmpty, !attachments.isEmpty {
            normalizedText = "请描述这张图片。"
        } else if audio != nil {
            // 有音频就无脑前缀 anchor — E2B/E4B 小模型会把 "这是什么？" 之类短 prompt
            // 当成问它自己, 给出 Gemma 自我介绍模板. 空 text 补一个默认意图作为填充,
            // 不再分两个音频分支。偶尔出现的 "关于这段音频：请转写音频" 式轻微冗余可
            // 接受, 胜过维护一套硬编 anchor 词表。
            let intent = trimmed.isEmpty ? "请详细转写并描述" : trimmed
            normalizedText = "关于这段音频：\(intent)"
        } else {
            normalizedText = trimmed
        }
        let requiresMultimodal = !attachments.isEmpty || audioInput != nil
        guard !isProcessing else { return }
        guard !normalizedText.isEmpty || !attachments.isEmpty || audioInput != nil else { return }
        messages.append(
            ChatMessage(
                role: .user,
                content: displayText,
                images: attachments,
                audios: audioClips
            )
        )
        isProcessing = true

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
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: attachments)

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
        messages.append(ChatMessage(role: .assistant, content: "▍", skillName: stickyEligibleSkillID))
        let msgIndex = messages.count - 1

        if requiresMultimodal {
            // Pure-vision path 默认返回空 system prompt (见 PromptBuilder.multimodalSystemPrompt),
            // 空字符串时跳过 .system(...) 注入, 让 Gemma 4 只看 image + user text,
            // 避免任何 system 框架把小模型带进"请提供图片"漂移.
            let systemPrompt = PromptBuilder.multimodalSystemPrompt(
                hasImages: !promptImages.isEmpty,
                hasAudio: audioInput != nil,
                enableThinking: config.enableThinking
            )
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
                        content: cleaned.isEmpty ? "（无回复）" : cleaned
                    )
                case .failure(let error):
                    log("[Agent] multimodal failed: \(error.localizedDescription)")
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
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
        let agentPrompt: String? = shouldUseFullAgentPrompt ? PromptBuilder.build(
            userMessage: normalizedText,
            currentImageCount: attachments.count,
            tools: activeSkillInfos,
            history: messages,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: historyDepth,
            showListSkillsHint: matchedSkillIdsForTurn.isEmpty,
            preloadedSkills: preloadedSkills
        ) : nil
        let lightPrompt: String = PromptBuilder.buildLightweightTextPrompt(
            userMessage: normalizedText,
            history: messages,
            systemPrompt: config.systemPrompt,
            enableThinking: config.enableThinking,
            historyDepth: shouldUsePlanner ? plannerHistoryDepth : historyDepth
        )
        let plannerInputPrompt: String = lightPrompt

        // KV Cache delta 路径: 如果 LiteRT session 已激活且不是首轮，
        // 用增量 delta 替代完整 prompt，只 prefill 新增 token。
        // Agent 路径 (tool calling) 暂不走 delta — secondary prompt 会重构 system block。
        let streamingPrompt: String
        if let litert = inference as? LiteRTBackend,
           litert.kvSessionActive,
           !litert.lastModelOutput.isEmpty,
           agentPrompt == nil  // agent 路径暂不走 delta
        {
            streamingPrompt = PromptBuilder.buildDeltaTurnPrompt(
                lastModelOutput: litert.lastModelOutput,
                userMessage: normalizedText,
                currentImageCount: attachments.count,
                enableThinking: config.enableThinking
            )
            log("[Agent] KV cache delta mode: \(streamingPrompt.count) chars (vs full \(lightPrompt.count) chars)")
        } else {
            streamingPrompt = agentPrompt ?? lightPrompt
        }
        #if DEBUG
        log("[Agent] text prompt mode=\(shouldUseFullAgentPrompt ? "agent" : "light"), planner-input-chars=\(plannerInputPrompt.count), streaming-chars=\(streamingPrompt.count), skills=\(activeSkillInfos.count)")
        #endif

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
                defer { self.isProcessing = false }
                guard self.messages.indices.contains(msgIndex) else { return }
                switch result {
                case .success(let fullText):
                    #if DEBUG
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    #endif

                    if self.parseToolCall(fullText) != nil {
                        self.messages[msgIndex].update(content: "")
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
                        self.messages[msgIndex].update(
                            content: cleaned.isEmpty ? "（无回复）" : cleaned
                        )
                    }
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
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
            messages[lastAssistant].update(content: content.isEmpty ? "（已中断）" : content)
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
        currentSessionID = UUID()
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = []
        // Reset KV cache for new conversation
        if let litert = inference as? LiteRTBackend {
            Task { await litert.resetKVSession() }
        }
    }

    func loadSession(id: UUID) {
        guard id != currentSessionID || messages.isEmpty else { return }
        flushPendingSessionSave()
        if isProcessing || inference.isGenerating {
            cancelActiveGeneration()
        }
        guard let record = loadSessionRecord(id: id) else { return }
        currentSessionID = id
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = record.messages
        // Reset KV cache — loaded session has no cached context
        if let litert = inference as? LiteRTBackend {
            Task { await litert.resetKVSession() }
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
                currentSessionID = next.id
                UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
                messages = record.messages
            } else {
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
        // 重新走 processInput，复用已持久化的 ChatImageAttachment，避免二次 JPEG 编码
        await processInput(text, replayImageAttachments: imageAttachments)
    }
}
