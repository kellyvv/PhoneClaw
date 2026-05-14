import Foundation

// MARK: - Engine Lifecycle
//
// 从 AgentEngine 主文件提取的生命周期管理方法:
// - setup / loadSystemPrompt / config 应用
// - model reload
// - skill 查找与管理
// - session 生命周期 (new / load / delete)
// - cancel / retry / permissions

extension AgentEngine {

    // MARK: - Skill Loading

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
        resetPromptPipelineState()
        messages = sessionStore.loadPersistedSessions()
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
                log("[Agent] SYSPROMPT migrated: 旧模板已备份到 SYSPROMPT.md.bak, 新默认已写入")
            } else if localeMismatch {
                let backup = dir.appendingPathComponent("SYSPROMPT.md.bak")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: file, to: backup)
                try? current.write(to: file, atomically: true, encoding: .utf8)
                config.systemPrompt = current
                log("[Agent] SYSPROMPT locale migrated to \(LanguageService.shared.current.resolved.rawValue), 旧文件备份到 SYSPROMPT.md.bak")
            } else {
                config.systemPrompt = content
                log("[Agent] SYSPROMPT loaded (\(content.count) chars)")
            }
        } else {
            try? kDefaultSystemPrompt.write(to: file, atomically: true, encoding: .utf8)
            config.systemPrompt = kDefaultSystemPrompt
            log("[Agent] SYSPROMPT not found — default written to \(file.path)")
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

    // MARK: - Permissions

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

    // MARK: - Session Lifecycle

    func clearMessages() {
        startNewSession()
    }

    func cancelActiveGeneration() {
        guard isProcessing || inference.isGenerating else { return }

        // 1. Mark transaction as cancelling BEFORE inference.cancel(),
        //    so onComplete → finishTurn() sees .cancelling (not .streaming).
        coordinator.currentTransaction?.cancel()

        // 2. Signal inference to stop producing tokens.
        inference.cancel()

        // 3. Immediate UI cleanup — isProcessing = false is NOT via finishTurn()
        //    because the coordinator's async cancel manages the state transition.
        isProcessing = false

        if let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) {
            let content = messages[lastAssistant].content.replacingOccurrences(of: "▍", with: "")
            messages[lastAssistant].update(content: content.isEmpty ? PromptLocale.current.cancelledReplyPlaceholder : content)
        }

        // 4. Async: wait for stream termination → reset KV safely.
        //    coordinator.cancelCurrentGeneration() handles the full cancel lifecycle:
        //    await txn.termination → resetKVSession() → transition to .ready.
        Task { [weak self] in
            await self?.coordinator.cancelCurrentGeneration()
        }

        log("[Agent] Generation cancelled")
    }

    func startNewSession() {
        sessionStore.flushPendingSave(messages: messages)
        if isProcessing || inference.isGenerating {
            cancelActiveGeneration()
        }
        resetPromptPipelineState()
        clearRecentImageFollowUpContexts()
        _ = sessionStore.newSession()
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
        guard id != sessionStore.currentSessionID || messages.isEmpty else { return }
        sessionStore.flushPendingSave(messages: messages)
        if isProcessing || inference.isGenerating {
            cancelActiveGeneration()
        }
        guard let restoredMessages = sessionStore.switchToSession(id: id) else { return }
        resetPromptPipelineState()
        clearRecentImageFollowUpContexts()
        messages = restoredMessages
        // Reset KV cache — loaded session has no cached context.
        // 切到其他会话时也顺便回 text-only — 被切出来的会话之前可能 sticky
        // 在 multimodal, 现在进的会话有没有图待定, 先释放 800 MB, 进来若发图再升级.
        Task { [inference] in
            await inference.revertToTextOnly()
            await inference.resetKVSession()
        }
    }

    func deleteSession(id: UUID) {
        sessionStore.flushPendingSave(messages: messages)
        if let switchResult = sessionStore.deleteSession(id: id) {
            // Deleted the current session — need to switch
            resetPromptPipelineState()
            clearRecentImageFollowUpContexts()
            messages = switchResult
        }
    }

    func flushPendingSessionSave() {
        sessionStore.flushPendingSave(messages: messages)
    }

    func setAllSkills(enabled: Bool) {
        for i in skillEntries.indices {
            skillEntries[i].isEnabled = enabled
        }
    }

    // MARK: - 解析

    func extractSkillName(from text: String) -> String? {
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
