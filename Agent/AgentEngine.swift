import CoreImage
import Foundation
import MLXLMCommon
import UIKit

func log(_ message: String) {
    print(message)
}

// MARK: - 模型/推理配置

@Observable
class ModelConfig {
    var maxTokens = 4000
    var topK = 64
    var topP = 0.95
    var temperature = 1.0
    var useGPU = true
    /// System prompt — 由 AgentEngine.loadSystemPrompt() 从 SYSPROMPT.md 注入，不在代码里硬编码。
    var systemPrompt = ""
}

// MARK: - SYSPROMPT 默认内容（仅在文件不存在时写入磁盘）
private let kDefaultSystemPrompt = """
你是 PhoneClaw，一个运行在本地设备上的私人 AI 助手。你完全离线运行，不联网，保护用户隐私。

你拥有以下能力（Skill）：

___SKILLS___

只有当用户明确要求执行某项设备内操作时，才调用 load_skill 加载该能力的详细指令。
像"配置""信息""看看""帮我查一下"这类含糊词，不足以单独触发工具调用。
如果用户只是普通聊天、追问上文、让你解释结果，直接回答，不要调用工具。
如果确实需要某个能力，你必须自己调用 load_skill，不要让用户去"使用某个能力"或"打开某个 skill"。

当且仅当确实需要某个能力时，先调用 load_skill：
<tool_call>
{"name": "load_skill", "arguments": {"skill": "能力名"}}
</tool_call>

在已经拿到工具结果后，优先直接给出最终答案，不要无谓追问。
用中文回答，简洁实用。
"""


// MARK: - 聊天消息

struct ChatImageAttachment: Identifiable {
    let id = UUID()
    let data: Data

    init?(image: UIImage) {
        if let jpeg = image.jpegData(compressionQuality: 0.92) {
            self.data = jpeg
        } else if let png = image.pngData() {
            self.data = png
        } else {
            return nil
        }
    }

    var uiImage: UIImage? {
        UIImage(data: data)
    }

    var ciImage: CIImage? {
        if let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) {
            return image
        }
        guard let uiImage else { return nil }
        if let ciImage = uiImage.ciImage {
            return ciImage
        }
        if let cgImage = uiImage.cgImage {
            return CIImage(cgImage: cgImage)
        }
        return CIImage(image: uiImage)
    }
}

struct ChatMessage: Identifiable {
    let id: UUID
    var role: Role
    var content: String
    var images: [ChatImageAttachment]
    let timestamp = Date()
    var skillName: String? = nil

    init(
        role: Role,
        content: String,
        images: [ChatImageAttachment] = [],
        skillName: String? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.images = images
        self.skillName = skillName
    }

    mutating func update(content: String) {
        guard self.content != content else { return }
        self.content = content
    }

    mutating func update(role: Role, content: String, skillName: String? = nil) {
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    enum Role {
        case user, assistant, system, skillResult
    }
}

// MARK: - Agent Engine

@Observable
class AgentEngine {

    let llm = MLXLocalLLMService()
    var messages: [ChatMessage] = []
    var isProcessing = false
    var config = ModelConfig()

    // 文件驱动的 Skill 系统
    let skillLoader = SkillLoader()
    let toolRegistry = ToolRegistry.shared

    // Skill 条目（给 UI 管理用，可开关）
    var skillEntries: [SkillEntry] = []


    var enabledSkillInfos: [SkillInfo] {
        skillEntries.filter(\.isEnabled).map {
            SkillInfo(name: $0.id, description: $0.description,
                     displayName: $0.name, icon: $0.icon, samplePrompt: $0.samplePrompt)
        }
    }

    init() {
        loadSkillEntries()
    }

    private func loadSkillEntries() {
        let definitions = skillLoader.discoverSkills()
        self.skillEntries = definitions.map { SkillEntry(from: $0, registry: toolRegistry) }
    }

    func reloadSkills() {
        let enabledState = Dictionary(uniqueKeysWithValues: skillEntries.map { ($0.id, $0.isEnabled) })
        loadSkillEntries()
        for i in skillEntries.indices {
            if let wasEnabled = enabledState[skillEntries[i].id] {
                skillEntries[i].isEnabled = wasEnabled
                skillLoader.setEnabled(skillEntries[i].id, enabled: wasEnabled)
            }
        }
    }

    // MARK: - Skill 查找（文件驱动）

    private func findSkillId(for name: String) -> String? {
        if skillLoader.getDefinition(name) != nil { return name }
        return skillLoader.findSkillId(forTool: name)
    }

    private func findDisplayName(for name: String) -> String {
        if let skillId = findSkillId(for: name),
           let def = skillLoader.getDefinition(skillId) {
            return def.metadata.name
        }
        return name
    }

    private func handleLoadSkill(skillName: String) -> String? {
        guard let entry = skillEntries.first(where: { $0.id == skillName }),
              entry.isEnabled else {
            return nil
        }
        return skillLoader.loadBody(skillId: skillName)
    }

    private func handleToolExecution(toolName: String, args: [String: Any]) async throws -> String {
        return try await toolRegistry.execute(name: toolName, args: args)
    }

    private func fallbackReplyForEmptyToolFollowUp(toolName: String, toolResult: String) -> String {
        let trimmed = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = payload["success"] as? Bool,
           !success,
           let error = payload["error"] as? String,
           !error.isEmpty {
            return "工具 \(toolName) 执行失败：\(error)"
        }

        if trimmed.isEmpty {
            return "工具 \(toolName) 已执行，但没有返回内容。"
        }

        return """
        工具 \(toolName) 已执行完成，但模型没有生成最终回答。
        工具返回结果：
        \(trimmed)
        """
    }

    private func fallbackReplyForEmptySkillFollowUp(skillName: String) -> String {
        "Skill \(skillName) 已加载，但模型没有继续生成工具调用或最终回答。请重试，或把问题说得更具体一些。"
    }

    // MARK: - 初始化

    /// ConfigurationsView 的"Restore default"按钮使用。
    var defaultSystemPrompt: String { kDefaultSystemPrompt }

    func setup() {
        loadSystemPrompt()       // 从 SYSPROMPT.md 注入 system prompt
        applySamplingConfig()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.llm.loadModel()
        }
    }

    // MARK: - SYSPROMPT 注入

    /// 从 ApplicationSupport/PhoneClaw/SYSPROMPT.md 读取 system prompt。
    /// 文件不存在时自动写入 kDefaultSystemPrompt（供用户后续编辑）。
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
            config.systemPrompt = content
            print("[Agent] SYSPROMPT loaded (\(content.count) chars)")
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
    }

    func reloadModel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.llm.loadModel()
        }
    }

    // MARK: - 处理用户输入（LiteRT-LM C API 流式输出）

    func processInput(_ text: String, images: [UIImage] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = trimmed.isEmpty && !images.isEmpty ? "请描述这张图片。" : trimmed
        guard !normalizedText.isEmpty, !isProcessing else { return }
        guard llm.isLoaded else {
            messages.append(ChatMessage(role: .system, content: "⏳ 模型还在加载中..."))
            return
        }

        let attachments = images.compactMap(ChatImageAttachment.init(image:))
        messages.append(ChatMessage(role: .user, content: normalizedText, images: attachments))
        isProcessing = true

        applySamplingConfig()

        let activeSkillInfos = attachments.isEmpty ? enabledSkillInfos : []
        let historyDepth = attachments.isEmpty ? llm.safeHistoryDepth : 0
        print("[MEM] safeHistoryDepth=\(historyDepth), headroom=\(llm.availableHeadroomMB) MB")
        let promptImages = promptImages(historyDepth: historyDepth, currentImages: attachments)
        print("[VLM] userAttachments=\(attachments.count), promptImages=\(promptImages.count)")

        messages.append(ChatMessage(role: .assistant, content: "▍"))
        let msgIndex = messages.count - 1

        if !attachments.isEmpty {
            let multimodalChat: [Chat.Message] = [
                .system(PromptBuilder.multimodalSystemPrompt),
                .user(
                    normalizedText,
                    images: promptImages.map { .ciImage($0) }
                ),
            ]

            llm.generateStream(chat: multimodalChat) { [weak self] token in
                guard let self = self else { return }
                let updated = self.messages[msgIndex].content == "▍"
                    ? token
                    : self.messages[msgIndex].content.replacingOccurrences(of: "▍", with: "") + token
                self.messages[msgIndex].update(content: updated + "▍")
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
                    self.messages[msgIndex].update(role: .system, content: "❌ \(error.localizedDescription)")
                }
                self.isProcessing = false
            }
            return
        }

        let prompt = PromptBuilder.build(
            userMessage: normalizedText,
            currentImageCount: attachments.count,
            tools: activeSkillInfos,
            history: messages,
            systemPrompt: config.systemPrompt,
            historyDepth: historyDepth
        )

        var detectedToolCall = false
        var buffer = ""
        var bufferFlushed = false

        llm.generateStream(prompt: prompt, images: promptImages) { [weak self] token in
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

    private func streamLLM(prompt: String, msgIndex: Int, images: [CIImage]) async -> String? {
        var buffer = ""
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var toolCallDetected = false
            var bufferFlushed = false
            llm.generateStream(prompt: prompt, images: images) { [weak self] token in
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

    private func executeToolChain(
        prompt: String,
        fullText: String,
        userQuestion: String,
        images: [CIImage],
        round: Int = 1,
        maxRounds: Int = 10
    ) async {
        guard round <= maxRounds else {
            log("[Agent] 达到最大工具链轮数 \(maxRounds)")
            isProcessing = false
            return
        }

        guard let call = parseToolCall(fullText) else {
            let cleaned = cleanOutput(fullText)
            if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[lastAssistant].update(content: cleaned.isEmpty ? "（无回复）" : cleaned)
            }
            isProcessing = false
            return
        }

        log("[Agent] Round \(round): tool_call name=\(call.name)")

        // ── load_skill ──
        if call.name == "load_skill" {
            let allCalls = parseAllToolCalls(fullText)
            let loadSkillCalls = allCalls.filter { $0.name == "load_skill" }

            var allInstructions = ""
            var loadedDisplayNames: [String] = []
            for lsCall in loadSkillCalls {
                let skillName = (lsCall.arguments["skill"] as? String)
                             ?? (lsCall.arguments["name"] as? String)
                             ?? ""
                log("[Agent] load_skill: \(skillName)")

                let displayName = findDisplayName(for: skillName)
                loadedDisplayNames.append(displayName)
                messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
                let cardIdx = messages.count - 1

                guard let instructions = handleLoadSkill(skillName: skillName) else {
                    messages[cardIdx].update(role: .system, content: "done", skillName: displayName)
                    continue
                }

                try? await Task.sleep(for: .milliseconds(300))
                messages[cardIdx].update(role: .system, content: "loaded", skillName: displayName)
                messages.append(ChatMessage(role: .skillResult, content: instructions, skillName: skillName))
                allInstructions += instructions + "\n\n"
            }

            guard !allInstructions.isEmpty else {
                isProcessing = false
                return
            }

            let followUpPrompt = PromptBuilder.buildFollowUp(
                originalPrompt: prompt,
                modelResponse: fullText,
                skillName: "load_skill",
                skillResult: allInstructions,
                userQuestion: userQuestion,
                currentImageCount: images.count,
                isLoadSkill: true
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if parseToolCall(nextText) != nil {
                log("[Agent] load_skill 后检测到 tool 调用 (round \(round + 1))")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty {
                    let retryPrompt = PromptBuilder.buildForcedSkillContinuation(
                        priorPrompt: followUpPrompt,
                        userQuestion: userQuestion
                    )

                    guard let retryText = await streamLLM(prompt: retryPrompt, msgIndex: followUpIndex, images: images) else {
                        isProcessing = false
                        return
                    }

                    if parseToolCall(retryText) != nil {
                        log("[Agent] load_skill 重试后检测到 tool 调用 (round \(round + 1))")
                        messages[followUpIndex].update(content: "")
                        await executeToolChain(
                            prompt: retryPrompt,
                            fullText: retryText,
                            userQuestion: userQuestion,
                            images: images,
                            round: round + 1,
                            maxRounds: maxRounds
                        )
                    } else {
                        let retryCleaned = cleanOutput(retryText)
                        let loadedSkillName = loadedDisplayNames.joined(separator: ", ").isEmpty
                            ? "已加载的能力"
                            : loadedDisplayNames.joined(separator: ", ")
                        messages[followUpIndex].update(content: retryCleaned.isEmpty
                            ? fallbackReplyForEmptySkillFollowUp(skillName: loadedSkillName)
                            : retryCleaned)
                        isProcessing = false
                    }
                } else {
                    messages[followUpIndex].update(content: cleaned)
                    isProcessing = false
                }
            }
            return
        }

        // ── 具体 Tool 调用 ──

        let ownerSkillId = findSkillId(for: call.name)
        let displayName = findDisplayName(for: call.name)

        let cardIndex: Int
        if let idx = messages.lastIndex(where: {
            $0.role == .system && ($0.skillName == displayName || $0.skillName == call.name)
            && ($0.content == "identified" || $0.content == "loaded")
        }) {
            cardIndex = idx
        } else {
            messages.append(ChatMessage(role: .system, content: "identified", skillName: displayName))
            cardIndex = messages.count - 1
        }

        guard ownerSkillId != nil else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ 未知工具: \(call.name)"))
            isProcessing = false
            return
        }

        let enabledIds = Set(skillEntries.filter(\.isEnabled).map(\.id))
        guard enabledIds.contains(ownerSkillId!) else {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .assistant, content: "⚠️ Skill \(displayName) 未启用"))
            isProcessing = false
            return
        }

        messages[cardIndex].update(role: .system, content: "executing:\(call.name)", skillName: displayName)

        do {
            let toolResult = try await handleToolExecution(toolName: call.name, args: call.arguments)
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .skillResult, content: toolResult, skillName: call.name))
            log("[Agent] Tool \(call.name) round \(round) done")

            let followUpPrompt = PromptBuilder.buildFollowUp(
                originalPrompt: prompt,
                modelResponse: fullText,
                skillName: call.name,
                skillResult: toolResult,
                userQuestion: userQuestion,
                currentImageCount: images.count
            )

            messages.append(ChatMessage(role: .assistant, content: "▍"))
            let followUpIndex = messages.count - 1

            guard let nextText = await streamLLM(prompt: followUpPrompt, msgIndex: followUpIndex, images: images) else {
                isProcessing = false
                return
            }

            if !parseAllToolCalls(nextText).isEmpty {
                log("[Agent] 检测到第 \(round + 1) 轮工具调用")
                messages[followUpIndex].update(content: "")
                await executeToolChain(
                    prompt: followUpPrompt, fullText: nextText,
                    userQuestion: userQuestion, images: images, round: round + 1, maxRounds: maxRounds
                )
            } else {
                let cleaned = cleanOutput(nextText)
                if cleaned.isEmpty {
                    messages[followUpIndex].update(content: fallbackReplyForEmptyToolFollowUp(
                        toolName: call.name,
                        toolResult: toolResult
                    ))
                } else {
                    messages[followUpIndex].update(content: cleaned)
                }
                isProcessing = false
            }
        } catch {
            messages[cardIndex].update(role: .system, content: "done", skillName: displayName)
            messages.append(ChatMessage(role: .system, content: "❌ Tool 执行失败: \(error)"))
            isProcessing = false
        }
    }

    // MARK: - 工具

    func clearMessages() {
        messages.removeAll()
    }

    func cancelActiveGeneration() {
        guard isProcessing || llm.isGenerating else { return }
        llm.cancel()
        isProcessing = false

        if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
            let content = messages[lastAssistant].content.replacingOccurrences(of: "▍", with: "")
            messages[lastAssistant].update(content: content.isEmpty ? "（已中断）" : content)
        }

        log("[Agent] Generation cancelled because the app left foreground")
    }

    private func promptImages(
        historyDepth: Int,
        currentImages: [ChatImageAttachment]
    ) -> [CIImage] {
        _ = historyDepth
        return Array(currentImages.prefix(1).compactMap(\.ciImage))
    }

    func setAllSkills(enabled: Bool) {
        for i in skillEntries.indices {
            skillEntries[i].isEnabled = enabled
        }
    }

    // MARK: - 解析

    private func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        return parseAllToolCalls(text).first
    }

    private func parseAllToolCalls(_ text: String) -> [(name: String, arguments: [String: Any])] {
        var results: [(name: String, arguments: [String: Any])] = []
        let patterns = [
            "<tool_call>\\s*(\\{.*?\\})\\s*</tool_call>",
            "```json\\s*(\\{.*?\\})\\s*```",
            "<function_call>\\s*(\\{.*?\\})\\s*</function_call>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let jsonRange = Range(match.range(at: 1), in: text) {
                    let json = String(text[jsonRange])
                    if let data = json.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = dict["name"] as? String {
                        results.append((name, dict["arguments"] as? [String: Any] ?? [:]))
                    }
                }
            }
            if !results.isEmpty { break }
        }
        return results
    }

    private func extractSkillName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"name\"\\s*:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[nameRange])
    }

    private func cleanOutputStreaming(_ text: String) -> String {
        var result = text

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            return ""
        }

        return String(result.drop(while: { $0.isWhitespace || $0.isNewline }))
    }

    private func cleanOutput(_ text: String) -> String {
        var result = text

        if let regex = try? NSRegularExpression(pattern: "<tool_call>.*?</tool_call>", options: .dotMatchesLineSeparators) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        if let tcRange = result.range(of: "<tool_call>") {
            result = String(result[result.startIndex..<tcRange.lowerBound])
        }

        let endPatterns = ["<turn|>", "<end_of_turn>", "<eos>"]
        for pat in endPatterns {
            if let range = result.range(of: pat) {
                result = String(result[result.startIndex..<range.lowerBound])
                break
            }
        }

        result = result.replacingOccurrences(
            of: "<\\|?[/a-z_]+\\|?>",
            with: "",
            options: .regularExpression
        )

        if let lastOpen = result.lastIndex(of: "<") {
            let tail = String(result[lastOpen...])
            let tailBody = tail.dropFirst()
            if !tailBody.isEmpty && tailBody.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "/" || $0 == "|" }) {
                result = String(result[result.startIndex..<lastOpen])
            }
        }

        if result.hasPrefix("model\n") {
            result = String(result.dropFirst(6))
        } else if result == "model" {
            result = ""
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
