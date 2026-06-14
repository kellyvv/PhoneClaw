import Foundation

/// LiveTurnProcessor → LiveModeEngine 之间的唯一交流协议.
///
/// 所有 live turn 里可能发生的事情都归纳到这几个 case, engine 侧用一个
/// exhaustive switch 处理干净. 新增输出类型只需在这里扩 case, engine
/// 会被编译器强制补齐分支.
enum LiveOutputEvent: Sendable {

    /// 首个非空白 token 是 marker. engine 根据 marker 决定:
    ///   - `.complete`    → 继续接 `.speechToken`, TTS 朗读
    ///   - `.interrupted` → 停止本轮, 退回 listening, 不朗读
    ///   - `.thinking`    → 停止本轮, 退回 listening, 不朗读
    case marker(LiveMarker)

    /// 要朗读给用户的 token 增量. engine 侧接 sanitizer → ttsQueue.
    case speechToken(String)

    /// LLM 输出的 `<tool_call>...</tool_call>` 被 LiveOutputParser 截获。
    /// 正常 Skill 轮会由 LiveTurnProcessor 内部消费并执行, 不透传给 engine；
    /// engine 收到它时只按异常控制块处理.
    case skillCall(LiveSkillCall)

    /// Skill 链路的信息输出. 这是 ASR → LLM → Skill → 信息展示的结果,
    /// 只更新 LIVE UI / 历史 / 后续外部 surface, 不进入 TTS.
    case skillInfo(LiveSkillInfoOutput)

    /// 流结束. engine 侧要 flush sanitizer 的残余, 转 turnPhase 回 listening.
    case done
}

struct LiveSkillInfoOutput: Sendable {
    let skillID: String
    let displayName: String
    let toolName: String?
    let success: Bool
    let summary: String
    let detail: String

    var displayText: String {
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = success
            ? tr("已完成。", "Done.", "完了しました。")
            : tr("没有完成。", "Not completed.", "完了しませんでした。")

        guard !normalizedSummary.isEmpty else {
            if let structuredText = Self.userVisibleText(fromStructuredDetail: normalizedDetail) {
                return Self.clipped(structuredText, maxLength: 2200)
            }
            guard !normalizedDetail.isEmpty,
                  !Self.looksMachineReadable(normalizedDetail) else {
                return fallback
            }
            return Self.clipped(normalizedDetail, maxLength: 2200)
        }

        guard let appendableDetail = Self.userVisibleDetail(
            normalizedDetail,
            excludingSummary: normalizedSummary
        ) else {
            return Self.clipped(normalizedSummary, maxLength: 2200)
        }

        return Self.clipped(normalizedSummary + "\n\n" + appendableDetail, maxLength: 2200)
    }

    private static func userVisibleDetail(_ detail: String, excludingSummary summary: String) -> String? {
        guard !detail.isEmpty, detail != summary else { return nil }
        guard jsonPayload(from: detail) == nil else { return nil }
        guard !looksMachineReadable(detail) else { return nil }
        return clipped(detail, maxLength: 1200)
    }

    private static func userVisibleText(fromStructuredDetail detail: String) -> String? {
        guard let payload = jsonPayload(from: detail) else { return nil }
        let candidates = ["result", "error", "message", "summary"]
        for key in candidates {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func jsonPayload(from detail: String) -> [String: Any]? {
        guard let data = detail.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private static func looksMachineReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }

        let lowered = trimmed.lowercased()
        let machineTokens = [
            #""eventid""#,
            #""start""#,
            #""end""#,
            #""status""#,
            #""success""#,
            #""error_code""#,
            #""phone_ground""#,
            "://"
        ]
        return machineTokens.contains { lowered.contains($0) }
    }

    private static func clipped(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
