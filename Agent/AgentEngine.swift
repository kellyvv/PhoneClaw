import CoreImage
import Foundation
import MLXLMCommon
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
    var useGPU = true
    var enableThinking = UserDefaults.standard.bool(forKey: enableThinkingDefaultsKey)
    var selectedModelID = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        ?? MLXLocalLLMService.defaultModel.id
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

    let llm = MLXLocalLLMService()
    var messages: [ChatMessage] = [] {
        didSet {
            scheduleSessionSave()
        }
    }
    var isProcessing = false
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


    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon,
                     type: $0.type, samplePrompt: $0.samplePrompt,
                     chipPrompt: $0.chipPrompt,
                     chipLabel: $0.chipLabel)
        }
    }

    var availableModels: [BundledModelOption] {
        MLXLocalLLMService.availableModels
    }

    init() {
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
        applyModelSelection()
        llm.refreshModelInstallStates()
        loadSystemPrompt()       // 从 SYSPROMPT.md 注入 system prompt
        loadPersistedSessions()
        applySamplingConfig()
        llm.loadModel()
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
        llm.samplingTopK = config.topK
        llm.samplingTopP = Float(config.topP)
        llm.samplingTemperature = Float(config.temperature)
        llm.maxOutputTokens = config.maxTokens
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
        return llm.selectModel(id: config.selectedModelID)
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
            _ = self.llm.selectModel(id: selectedModelID)
            await self.llm.prepareForReload()
            self.llm.loadModel()
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

    // MARK: - 处理用户输入（MLX 流式输出）

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
        let audioAttachment = audio.map(UserInput.Audio.from(snapshot:))
        let normalizedText: String
        if trimmed.isEmpty, !attachments.isEmpty {
            normalizedText = "请描述这张图片。"
        } else if trimmed.isEmpty, audio != nil {
            normalizedText = "请直接转写这段音频内容。"
        } else {
            normalizedText = trimmed
        }
        let requiresMultimodal = !attachments.isEmpty || audioAttachment != nil
        guard !isProcessing else { return }
        guard !normalizedText.isEmpty || !attachments.isEmpty || audioAttachment != nil else { return }
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
        // TODO(Step 4): 接入 llm.selectedModel.supportsStructuredPlanning 后 gate Planner 入口
        let shouldUsePlanner = !requiresMultimodal && matchedSkillIdsForTurn.count >= 2
        let shouldUseFullAgentPrompt =
            !requiresMultimodal
            && !shouldUsePlanner
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
        let historyDepth = requiresMultimodal ? 0 : llm.safeHistoryDepth
        let plannerHistoryDepth = shouldUsePlanner ? 0 : historyDepth
        print("[MEM] safeHistoryDepth=\(historyDepth), headroom=\(llm.availableHeadroomMB) MB")
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: attachments)
        print(
            "[VLM] userAttachments=\(attachments.count), promptImages=\(promptImages.count), "
                + "audio=\(audioAttachment == nil ? 0 : 1)"
        )

        // [Metric] PhoneClaw 架构优化数据收集
        // 收集窗口：2026-04-08 ~ 2026-04-22（2 周）
        // 到期后评估 P1-b / P2 是否执行，评估完可移除此埋点
        #warning("[Metric] PhoneClaw 架构优化埋点，2026-04-22 前评估并移除")
        let routedPath = Self.decideRoute(
            requiresMultimodal: requiresMultimodal,
            shouldUsePlanner: shouldUsePlanner,
            shouldUseFullAgentPrompt: shouldUseFullAgentPrompt
        )
        log("[Metric] route=\(routedPath) skills=\(matchedSkillIdsForTurn.count) model=\(llm.selectedModel.id) multimodal=\(requiresMultimodal)")

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
            let multimodalChat: [Chat.Message] = [
                .system(
                    PromptBuilder.multimodalSystemPrompt(
                        hasImages: !promptImages.isEmpty,
                        hasAudio: audioAttachment != nil
                    )
                ),
                .user(
                    normalizedText,
                    images: promptImages.map { .ciImage($0) },
                    audios: audioAttachment.map { [$0] } ?? []
                ),
            ]
            let multimodalContext: [String: any Sendable]? =
                config.enableThinking ? ["enable_thinking": true] : nil
            var multimodalBuffer = ""

            llm.generateStream(chat: multimodalChat, additionalContext: multimodalContext) { [weak self] token in
                guard let self = self else { return }
                multimodalBuffer += token
                let cleaned = self.cleanOutputStreaming(multimodalBuffer)
                self.messages[msgIndex].update(content: (cleaned.isEmpty ? "" : cleaned) + "▍")
            } onComplete: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let fullText):
                    log("[Agent] 1st raw: \(fullText.prefix(300))")
                    let cleaned = self.cleanOutput(fullText)
                    self.messages[msgIndex].update(
                        content: cleaned.isEmpty ? "（无回复）" : cleaned
                    )
                case .failure(let error):
                    log("[Agent] multimodal failed: \(error.localizedDescription)")
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                }
                self.isProcessing = false
            }
            return
        }

        // Router 确定性匹配到的 skill: 直接预加载 body + 工具列表,
        // 让模型在 round 1 就看到 schema, 跳过 load_skill 往返。对小模型
        // (E2B/E4B) 效果显著 — 避免它们在"要不要 load_skill"这种主观判断上翻车。
        let preloadedSkills: [PromptBuilder.PreloadedSkill] = matchedSkillIdsForTurn.compactMap { id in
            guard let body = skillRegistry.loadBody(skillId: id),
                  let def = skillRegistry.getDefinition(id) else { return nil }
            return PromptBuilder.PreloadedSkill(
                id: id,
                displayName: def.metadata.name,
                body: body,
                allowedTools: def.metadata.allowedTools
            )
        }

        let prompt: String
        if shouldUseFullAgentPrompt {
            prompt = PromptBuilder.build(
                userMessage: normalizedText,
                currentImageCount: attachments.count,
                tools: activeSkillInfos,
                history: messages,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking,
                historyDepth: historyDepth,
                showListSkillsHint: matchedSkillIdsForTurn.isEmpty,
                preloadedSkills: preloadedSkills
            )
        } else {
            prompt = PromptBuilder.buildLightweightTextPrompt(
                userMessage: normalizedText,
                history: messages,
                systemPrompt: config.systemPrompt,
                enableThinking: config.enableThinking,
                historyDepth: shouldUsePlanner ? plannerHistoryDepth : historyDepth
            )
        }
        log("[Agent] text prompt mode=\(shouldUseFullAgentPrompt ? "agent" : "light"), chars=\(prompt.count), skills=\(activeSkillInfos.count)")

        if shouldUsePlanner {
            log("[Agent] planner path triggered revision=\(plannerRevision)")
            let plannerHandled = await executePlannedSkillChainIfPossible(
                prompt: prompt,
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

            if messages.indices.contains(msgIndex),
               messages[msgIndex].role == .assistant,
               messages[msgIndex].content == "▍" {
                messages.remove(at: msgIndex)
            }
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: "⚠️ 已识别到多个 Skill，但当前无法完成编排。请补充更具体的信息后重试。"
                )
            )
            isProcessing = false
            return
        }


        var detectedToolCall = false
        var buffer = ""
        var bufferFlushed = false

        llm.generateStream(prompt: prompt, images: promptImages, audios: []) { [weak self] token in
            guard let self = self else { return }

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
        } onComplete: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fullText):
                log("[Agent] 1st raw: \(fullText.prefix(300))")

                if self.parseToolCall(fullText) != nil {
                    self.messages[msgIndex].update(content: "")
                    Task {
                        await self.executeToolChain(
                            prompt: prompt,
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
            self.isProcessing = false
        }
    }

    // MARK: - Skill 结果后的后续推理（支持多轮工具链）

    func streamLLM(prompt: String, images: [CIImage]) async -> String? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            llm.generateStream(prompt: prompt, images: images, audios: []) { _ in
            } onComplete: { result in
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    log("[Agent] LLM failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func streamLLM(prompt: String, msgIndex: Int, images: [CIImage]) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false
            llm.generateStream(prompt: prompt, images: images, audios: []) { [weak self] token in
                guard let self = self else { return }
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
            } onComplete: { [weak self] result in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                switch result {
                case .success(let text):
                    log("[Agent] LLM raw: \(text.prefix(300))")
                    continuation.resume(returning: text)
                case .failure(let error):
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - 工具

    func clearMessages() {
        startNewSession()
    }

    func cancelActiveGeneration() {
        guard isProcessing || llm.isGenerating else { return }
        llm.cancel()
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
        if isProcessing || llm.isGenerating {
            cancelActiveGeneration()
        }
        currentSessionID = UUID()
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = []
    }

    func loadSession(id: UUID) {
        guard id != currentSessionID || messages.isEmpty else { return }
        flushPendingSessionSave()
        if isProcessing || llm.isGenerating {
            cancelActiveGeneration()
        }
        guard let record = loadSessionRecord(id: id) else { return }
        currentSessionID = id
        UserDefaults.standard.set(currentSessionID.uuidString, forKey: Self.currentSessionDefaultsKey)
        messages = record.messages
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
        guard !isProcessing, llm.isLoaded else { return }
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
