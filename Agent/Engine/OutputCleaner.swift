import Foundation

extension AgentEngine {

    // MARK: - 中间输出/Prompt 回声识别

    func looksLikeStructuredIntermediateOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("```json") || trimmed.hasPrefix("```") {
            return true
        }

        if let regex = try? NSRegularExpression(
            pattern: "\"[A-Za-z_][A-Za-z0-9_]*\"\\s*:",
            options: []
        ) {
            let matchCount = regex.numberOfMatches(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            )
            if matchCount >= 2 && !trimmed.hasPrefix("{") {
                return true
            }
        }

        let suspiciousFragments = [
            "tool_name\":",
            "result_for_user_name\":",
            "text_for_display\":",
            "tool_operation_success\":",
            "arguments_for_tool_no_skill\":",
            "memory_user_power_conversion\":"
        ]
        if suspiciousFragments.filter({ trimmed.contains($0) }).count >= 2 {
            return true
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if let dict = json as? [String: Any] {
            if dict["name"] != nil {
                return false
            }

            let suspiciousKeys = [
                "final_answer", "tool_call", "arguments", "device_call",
                "next_action", "action", "tool"
            ]
            return suspiciousKeys.contains { dict[$0] != nil }
        }

        return false
    }

    func looksLikePromptEcho(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("user\n") || trimmed == "user" {
            return true
        }

        let suspiciousPhrases = [
            "根据已加载的 Skill",
            "不要将任何关于工具、系统或该请求的描述变成 Markdown 代码或 JSON 模板",
            "如果需要，请直接调用",
            "package_name",
            "text_for_user"
        ]

        let hitCount = suspiciousPhrases.reduce(into: 0) { count, phrase in
            if trimmed.contains(phrase) { count += 1 }
        }
        return hitCount >= 2
    }

    // MARK: - 输出清洗

    func cleanOutputStreaming(_ text: String) -> String {
        let (safe, _) = OutputSanitizer.sanitize(text, mode: .chatUI)
        return normalizeSafetyTruncation(in: stripUnexpectedThinkingMarkersIfNeeded(safe))
    }

    func cleanOutput(_ text: String) -> String {
        let cleaned = OutputSanitizer.sanitizeFinal(text, mode: .chatUI)
        return normalizeSafetyTruncation(in: stripUnexpectedThinkingMarkersIfNeeded(cleaned))
    }

    // MARK: - 安全截断保留 / 句子边界

    private func stripUnexpectedThinkingMarkersIfNeeded(_ text: String) -> String {
        guard !config.enableThinking else { return text }

        var result = text
        result = result.replacingOccurrences(of: "[[/PHONECLAW_THINK]]", with: "")
        result = result.replacingOccurrences(of: "[[PHONECLAW_THINK]]", with: "")
        result = result.replacingOccurrences(
            of: #"(?im)^\s*Thinking Process:\s*\n*"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSafetyTruncation(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let warningRange = trimmed.range(of: "> ⚠️ ") else {
            return trimmed
        }

        let body = String(trimmed[..<warningRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let warning = String(trimmed[warningRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return warning }

        let normalizedBody = trimIncompleteTrailingBlock(in: body)
        guard !normalizedBody.isEmpty else { return warning }
        return normalizedBody + "\n\n" + warning
    }

    private func trimIncompleteTrailingBlock(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let paragraphBreak = trimmed.range(of: "\n\n", options: .backwards) {
            let tailLength = trimmed.distance(from: paragraphBreak.upperBound, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 280 {
                return String(trimmed[..<paragraphBreak.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let sentenceBoundary = lastSentenceBoundary(in: trimmed) {
            let tailLength = trimmed.distance(from: sentenceBoundary, to: trimmed.endIndex)
            if tailLength > 0 && tailLength <= 220 {
                return String(trimmed[..<sentenceBoundary])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private func lastSentenceBoundary(in text: String) -> String.Index? {
        let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if sentenceEndings.contains(text[index]) {
                return text.index(after: index)
            }
        }
        return nil
    }

}
