import Foundation

struct LiveSkillRoute: Sendable {
    let skillID: String
    let displayName: String
    /// SKILL.md 声明的类别 — token 源分流用: network 型(联网检索)的流程在原 LLM
    /// 链路上调教过泛化, 永远不走 FM 旁路。
    let skillType: SkillType
    let allowedToolNames: [String]
    let contractPrompt: String
}

final class LiveSkillRuntime {
    private let skillRegistry: SkillRegistry
    private let toolRegistry: ToolRegistry

    private let liveSupportedSkillIDs: Set<String> = [
        "calendar",
        "reminders",
        "health",
        "web-search"
    ]

    init(skillRegistry: SkillRegistry, toolRegistry: ToolRegistry = .shared) {
        self.skillRegistry = skillRegistry
        self.toolRegistry = toolRegistry
    }

    func route(for transcript: String) async -> LiveSkillRoute? {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let enabled = enabledLiveSkillIDs()
        guard !enabled.isEmpty else { return nil }

        if let guarded = GuardedSkillRouter.route(
            for: normalized,
            enabledSkillIDs: enabled,
            canonicalSkillID: { [skillRegistry] in skillRegistry.canonicalSkillId(for: $0) }
        ) {
            switch guarded.action {
            case .answerDirectly:
                print("[LiveSkillRouter] source=guarded action=answerDirectly reason=\(guarded.reason)")
                return nil
            case .useSkill:
                if let skillID = guarded.skillID, let route = makeRoute(skillID: skillID) {
                    print("[LiveSkillRouter] source=guarded action=useSkill selected=\(skillID) reason=\(guarded.reason)")
                    return route
                }
            }
        }

        if let metadataSkillID = metadataMatchedSkillID(for: normalized, enabledSkillIDs: enabled),
           let route = makeRoute(skillID: metadataSkillID) {
            print("[LiveSkillRouter] source=metadata action=useSkill selected=\(metadataSkillID)")
            return route
        }

        if shouldTryFoundationRouter(for: normalized),
           let result = await IOS27FoundationSkillRouter.route(
                for: normalized,
                enabledSkillIDs: enabled
           ) {
            let d = result.diagnostics
            print(
                "[LiveSkillRouter] source=foundation_probe action=\(result.decision?.action.rawValue ?? "none") " +
                "selected=\(result.decision?.skillID ?? "none") availability=\(d.availability) " +
                "confidence=\(d.confidence.map { String($0) } ?? "na") reason=\(d.reason)"
            )
            if let decision = result.decision,
               decision.action == .useSkill,
               let skillID = decision.skillID,
               let route = makeRoute(skillID: skillID) {
                return route
            }
        }

        return nil
    }

    func normalize(call: LiveSkillCall, route: LiveSkillRoute) -> LiveSkillCall? {
        let rawName = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = toolRegistry.canonicalName(for: rawName) ?? rawName.replacingOccurrences(of: "_", with: "-").lowercased()
        guard route.allowedToolNames.contains(canonical) else {
            print("[LiveSkill] blocked tool outside route allowlist: \(rawName) route=\(route.skillID)")
            return nil
        }
        return LiveSkillCall(name: canonical, arguments: call.arguments)
    }

    func validate(call: LiveSkillCall) -> String? {
        guard toolRegistry.find(name: call.name) != nil else {
            return tr(
                "这个操作我现在还不能在语音里完成。",
                "I can't complete that action in voice mode yet.",
                "その操作は、今の音声モードではまだ実行できません。"
            )
        }
        guard toolRegistry.validatesArguments(call.arguments, for: call.name) else {
            return missingArgumentUtterance(for: call.name)
        }
        return nil
    }

    func execute(call: LiveSkillCall) async -> CanonicalToolResult {
        do {
            return try await toolRegistry.executeCanonical(name: call.name, args: call.arguments)
        } catch {
            return CanonicalToolResult(
                success: false,
                summary: tr(
                    "操作没有完成：\(error.localizedDescription)",
                    "The action did not complete: \(error.localizedDescription)",
                    "操作は完了しませんでした: \(error.localizedDescription)"
                ),
                detail: String(describing: error)
            )
        }
    }

    func infoOutput(route: LiveSkillRoute, call: LiveSkillCall, result: CanonicalToolResult) -> LiveSkillInfoOutput {
        LiveSkillInfoOutput(
            skillID: route.skillID,
            displayName: route.displayName,
            toolName: call.name,
            success: result.success,
            summary: result.summary,
            detail: result.detail
        )
    }

    func infoOutput(route: LiveSkillRoute, message: String, success: Bool = false) -> LiveSkillInfoOutput {
        LiveSkillInfoOutput(
            skillID: route.skillID,
            displayName: route.displayName,
            toolName: nil,
            success: success,
            summary: message.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: ""
        )
    }

    // MARK: - Routing

    private func enabledLiveSkillIDs() -> Set<String> {
        Set(
            skillRegistry.discoverSkills().compactMap { definition in
                guard definition.isEnabled,
                      liveSupportedSkillIDs.contains(definition.id),
                      !definition.metadata.allowedTools.isEmpty else {
                    return nil
                }
                return definition.id
            }
        )
    }

    private func makeRoute(skillID rawSkillID: String) -> LiveSkillRoute? {
        let skillID = skillRegistry.canonicalSkillId(for: rawSkillID)
        guard liveSupportedSkillIDs.contains(skillID),
              let definition = skillRegistry.getDefinition(skillID),
              definition.isEnabled,
              !definition.metadata.allowedTools.isEmpty else {
            return nil
        }

        let registeredTools = toolRegistry.toolsFor(names: definition.metadata.allowedTools)
        guard !registeredTools.isEmpty else { return nil }

        let tuples = registeredTools.map {
            (
                name: $0.name,
                description: $0.description,
                parameters: $0.parameters,
                requiredParameters: $0.requiredParameters
            )
        }
        let compact = PromptBuilder.PreloadedSkill.makeCompactSchema(
            skillName: definition.metadata.name,
            tools: tuples
        )
        let body = skillRegistry.loadBody(skillId: skillID) ?? compact
        let instructionBody = MemoryStats.headroomMB < 1500 ? compact : body
        let contract = makeContractPrompt(
            definition: definition,
            toolSummary: compact,
            instructionBody: instructionBody,
            allowedToolNames: registeredTools.map(\.name)
        )

        return LiveSkillRoute(
            skillID: skillID,
            displayName: definition.metadata.displayName,
            skillType: definition.metadata.type,
            allowedToolNames: registeredTools.map(\.name),
            contractPrompt: contract
        )
    }

    private func metadataMatchedSkillID(for transcript: String, enabledSkillIDs: Set<String>) -> String? {
        let normalized = transcript.lowercased()
        for definition in skillRegistry.discoverSkills() where enabledSkillIDs.contains(definition.id) {
            let names = [definition.id, definition.metadata.name, definition.metadata.displayName]
            if names.contains(where: { containsAsWord($0.lowercased(), in: normalized) }) {
                return definition.id
            }
            if definition.metadata.triggers.contains(where: {
                containsAsWord($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), in: normalized)
            }) {
                return definition.id
            }
            if definition.metadata.allowedTools.contains(where: {
                containsAsWord($0.lowercased(), in: normalized)
            }) {
                return definition.id
            }
        }
        return nil
    }

    private func shouldTryFoundationRouter(for transcript: String) -> Bool {
        let text = transcript.lowercased()
        return containsAny(text, [
            "安排", "创建", "添加", "新建", "预约", "约会", "日程", "会议",
            "提醒", "待办", "记得", "翻译",
            "schedule", "book", "meeting", "remind", "reminder", "translate"
        ])
    }

    // MARK: - Prompt contracts

    private func makeContractPrompt(
        definition: SkillDefinition,
        toolSummary: String,
        instructionBody: String,
        allowedToolNames: [String]
    ) -> String {
        let timeAnchor = definition.metadata.requiresTimeAnchor ? "\n\(currentTimeAnchor())\n" : ""
        let clippedInstructions = clipped(instructionBody, maxLength: 5200)
        return tr(
            """

            【LIVE_SKILL_CONTRACT】
            本轮用户请求已锁定 Skill：\(definition.metadata.displayName)（\(definition.id)）。
            你现在只允许两种输出：
            1. 如果参数足够，直接输出一个完整的 <tool_call>{"name":"...","arguments":{...}}</tool_call>，不要在 tool_call 前后说话。
            2. 如果缺少必填信息，以 ✓ 开头问一个很短的补充问题，不要输出 tool_call。
            只允许调用这些工具：\(allowedToolNames.joined(separator: ", "))。
            工具 schema：
            \(toolSummary)
            Skill 指令：
            \(clippedInstructions)
            \(timeAnchor)
            【/LIVE_SKILL_CONTRACT】
            """,
            """

            [LIVE_SKILL_CONTRACT]
            This user turn is locked to Skill: \(definition.metadata.displayName) (\(definition.id)).
            You may output only one of two things:
            1. If required arguments are available, output exactly one complete <tool_call>{"name":"...","arguments":{...}}</tool_call>, with no spoken text before or after it.
            2. If required information is missing, start with ✓ and ask one short follow-up question. Do not output a tool call.
            Allowed tools only: \(allowedToolNames.joined(separator: ", ")).
            Tool schema:
            \(toolSummary)
            Skill instructions:
            \(clippedInstructions)
            \(timeAnchor)
            [/LIVE_SKILL_CONTRACT]
            """,
            """

            【LIVE_SKILL_CONTRACT】
            今回の発話は Skill「\(definition.metadata.displayName)」（\(definition.id)）にロックされています。
            出力は次のどちらか一つだけです：
            1. 必須情報がそろっている場合、完全な <tool_call>{"name":"...","arguments":{...}}</tool_call> だけを出力し、その前後に話し言葉を入れない。
            2. 必須情報が足りない場合、✓ で始めて短い確認質問を一つだけ出し、tool_call は出力しない。
            使用できるツール：\(allowedToolNames.joined(separator: ", "))。
            ツール schema：
            \(toolSummary)
            Skill 指示：
            \(clippedInstructions)
            \(timeAnchor)
            【/LIVE_SKILL_CONTRACT】
            """
        )
    }

    private func currentTimeAnchor() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: PromptLocale.current.dateFormatterLocaleIdentifier)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        return tr(
            "当前时间锚点：\(formatter.string(from: Date()))",
            "Current time anchor: \(formatter.string(from: Date()))",
            "現在時刻の基準：\(formatter.string(from: Date()))"
        )
    }

    // MARK: - Helpers

    private func missingArgumentUtterance(for toolName: String) -> String {
        let required = toolRegistry.requiredParams(for: toolName)
        let anyOf = toolRegistry.requiredAnyOfParams(for: toolName)
        let fields = !required.isEmpty ? required : anyOf
        guard !fields.isEmpty else {
            return tr(
                "还差一点必要信息，麻烦再补充一下。",
                "I still need one required detail. Could you add it?",
                "必要な情報が少し足りません。もう少し補足してください。"
            )
        }
        return tr(
            "还缺\(fields.joined(separator: "、"))，麻烦补充一下。",
            "I still need \(fields.joined(separator: ", ")). Could you add that?",
            "\(fields.joined(separator: "、")) が足りません。補足してください。"
        )
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { containsAsWord($0.lowercased(), in: text) }
    }

    private func containsAsWord(_ trigger: String, in text: String) -> Bool {
        let needle = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let isAsciiWord = needle.unicodeScalars.allSatisfy { scalar in
            scalar.value < 128 && (
                CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "-" || scalar == "_"
            )
        }
        guard isAsciiWord else {
            return text.contains(needle)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text.contains(needle)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func clipped(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }
}
