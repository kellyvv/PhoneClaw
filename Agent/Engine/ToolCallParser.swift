import Foundation

extension AgentEngine {

    // MARK: - 工具名归一化

    func canonicalToolName(
        _ toolName: String,
        arguments: [String: Any],
        preferredSkillId: String? = nil
    ) -> String {
        let normalizedToolName = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        // 协议级 sentinel tool 的名称归一化。
        // load_skill / list_skills 不是注册在 ToolRegistry 的业务工具，
        // 而是 AgentEngine 与 LLM 之间的协议入口（在 executeToolChain 内被特殊
        // hijack 处理），因此其名称归一化属于 caller 协议范畴而非 per-skill 硬编。
        switch normalizedToolName {
        case "load-skill":
            return "load_skill"
        case "list-skills", "list-skill", "listskills":
            return "list_skills"
        default:
            break
        }

        // 委托 ToolRegistry 别名查询
        if let canonical = toolRegistry.canonicalName(for: normalizedToolName) {
            return canonical
        }

        // 按 preferredSkillId 做 suffix 匹配（通用逻辑，不涉及领域语义）
        if let preferredSkillId {
            let resolvedSkillId = skillRegistry.canonicalSkillId(for: preferredSkillId)
            let allowedTools = registeredTools(for: resolvedSkillId).map(\.name)

            if allowedTools.contains(normalizedToolName) {
                return normalizedToolName
            }

            let suffixMatches = allowedTools.filter { allowedTool in
                let normalizedAllowed = allowedTool.lowercased()
                if normalizedAllowed.hasSuffix("-" + normalizedToolName) {
                    return true
                }
                let strippedPrefix = normalizedAllowed.replacingOccurrences(
                    of: resolvedSkillId.lowercased() + "-",
                    with: ""
                )
                return strippedPrefix == normalizedToolName
            }
            if suffixMatches.count == 1, let match = suffixMatches.first {
                return match
            }

            if allowedTools.count == 1, let onlyTool = allowedTools.first {
                let strippedPrefix = onlyTool
                    .lowercased()
                    .replacingOccurrences(of: resolvedSkillId.lowercased() + "-", with: "")
                if strippedPrefix.contains(normalizedToolName)
                    || normalizedToolName.contains(strippedPrefix) {
                    return onlyTool
                }
            }
        }

        return normalizedToolName
    }

    // MARK: - JSON 解析

    func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidates: [String] = {
            if trimmed.hasPrefix("```json") || trimmed.hasPrefix("```") {
                let stripped = trimmed
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return [stripped]
            }

            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start <= end {
                return [trimmed, String(trimmed[start...end])]
            }

            return [trimmed]
        }()

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }

        return nil
    }

    private func normalizeLoadSkillArguments(_ arguments: [String: Any]) -> [String: Any]? {
        let rawSkillName = ((arguments["skill"] as? String) ?? (arguments["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSkillName.isEmpty else { return nil }

        let directSkillId = skillRegistry.canonicalSkillId(for: rawSkillName)
        let resolvedSkillId: String? = {
            if let def = skillRegistry.getDefinition(directSkillId), def.isEnabled {
                return directSkillId
            }

            return skillRegistry.discoverSkills().first { definition in
                guard definition.isEnabled else { return false }
                let candidates = [
                    definition.id,
                    definition.metadata.name,
                    definition.metadata.localizedNameZh ?? "",
                    definition.metadata.displayName
                ]
                return candidates.contains { candidate in
                    !candidate.isEmpty && candidate.compare(
                        rawSkillName,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: nil,
                        locale: .current
                    ) == .orderedSame
                }
            }?.id
        }()

        guard let resolvedSkillId else { return nil }

        var normalizedArguments = arguments
        normalizedArguments["skill"] = resolvedSkillId
        return normalizedArguments
    }

    // MARK: - tool_call 文本解析
    //
    // Cage: parser 是框架边界, 同时承担"白名单校验"职责。任何不在
    // ToolRegistry (业务工具) 或 protocolTools (load_skill / list_skills 等
    // 框架内置 sentinel) 的名字一律 drop, 防止 LLM 幻觉穿透到 executeToolChain
    // 创建 phantom card / 触发未知 tool 错误。
    //
    // 这是 ToolRegistry 真正成为"白名单"的地方——之前 registry 只在
    // executeToolChain 末梢被消费, 校验缺位导致幻觉的 tool_call 在框架内
    // 多次易手才被丢弃。

    /// 协议级 sentinel tool: 不在 ToolRegistry 注册, 但是框架与 LLM 的
    /// 通信协议入口, 由 executeToolChain 内特殊 hijack 处理。
    private static let protocolTools: Set<String> = ["load_skill", "list_skills"]

    func parseToolCall(_ text: String) -> (name: String, arguments: [String: Any])? {
        return parseAllToolCalls(text).first
    }

    func parseAllToolCalls(_ text: String) -> [(name: String, arguments: [String: Any])] {
        let raw = rawParseToolCalls(text)
        return raw.compactMap { call in
            let canonical = canonicalToolName(call.name, arguments: call.arguments)
            if canonical == "load_skill" {
                guard let normalizedArguments = normalizeLoadSkillArguments(call.arguments) else {
                    log("[Parser] dropped invalid load_skill request: \(call.arguments)")
                    return nil
                }
                return (canonical, normalizedArguments)
            }
            if Self.protocolTools.contains(canonical) {
                return (canonical, call.arguments)
            }
            if toolRegistry.find(name: canonical) != nil {
                return (canonical, call.arguments)
            }
            log("[Parser] dropped invalid tool_call: \(call.name) (canonical: \(canonical))")
            return nil
        }
    }

    /// 原始正则提取, 不做任何 registry 校验。
    /// 仅供 parseAllToolCalls 内部使用; 外部 caller 必须走 parseAllToolCalls
    /// 以确保 cage 校验不被绕过。
    private func rawParseToolCalls(_ text: String) -> [(name: String, arguments: [String: Any])] {
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
}
