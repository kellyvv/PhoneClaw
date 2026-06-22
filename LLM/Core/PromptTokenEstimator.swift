import Foundation

// MARK: - Prompt Token Estimator
//
// 中英文混合 prompt 的 token 估算。基于 SentencePiece (Gemma 4 用) 在中英文
// 混合内容上的统计:
//   - CJK 字符: ~1.5 chars/token (汉字单字常占 1-2 token)
//   - 拉丁/数字/标点: ~4.0 chars/token (BPE 合并后的常见词)
//
// Plan §九 Phase 3 提出"中文 ~1.5 字/token"。这里取折中:
// 把 prompt 按 unicode scalar 类别加权累加。误差 ±15%,够 context budget 预算用。
//
// 独立文件以便 Tests/ 直接 symlink 单元测试,不拖入 ChatMessage 等更大依赖。

public enum PromptTokenEstimator {

    /// 估算 prompt 的 token 数。最小返回 1。
    public static func estimate(_ prompt: String) -> Int {
        guard !prompt.isEmpty else { return 1 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in prompt.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        let cjkTokens = Double(cjkCount) / 1.5
        let otherTokens = Double(otherCount) / 4.0
        return max(1, Int((cjkTokens + otherTokens).rounded(.up)))
    }

    /// 估算 prompt 的结构化 token 分布。`totalTokens` 保持等于旧的整段
    /// `estimate(_:)` 结果，避免引入 transcript 后让 context budget 变松。
    public static func estimateBreakdown(_ prompt: String) -> PromptTokenBreakdown {
        let rawTotal = estimate(prompt)
        let transcript = PromptTranscript(gemmaPrompt: prompt)
        guard !transcript.turns.isEmpty else {
            return PromptTokenBreakdown(
                totalTokens: rawTotal,
                systemTokens: 0,
                userTokens: 0,
                assistantTokens: 0,
                toolTokens: 0,
                otherTokens: rawTotal,
                formatOverheadTokens: 0,
                turnCount: 0
            )
        }
        return estimateTranscript(transcript, rawPromptTokenEstimate: rawTotal)
    }

    public static func estimateTranscript(
        _ transcript: PromptTranscript,
        rawPromptTokenEstimate: Int? = nil
    ) -> PromptTokenBreakdown {
        var systemTokens = 0
        var userTokens = 0
        var assistantTokens = 0
        var toolTokens = 0
        var otherTokens = 0

        for turn in transcript.turns {
            switch turn.role {
            case .system:
                systemTokens += turn.tokenEstimate
            case .user:
                userTokens += turn.tokenEstimate
            case .assistant:
                assistantTokens += turn.tokenEstimate
            case .tool:
                toolTokens += turn.tokenEstimate
            case .unknown:
                otherTokens += turn.tokenEstimate
            }
        }

        let contentTokens = systemTokens + userTokens + assistantTokens + toolTokens + otherTokens
        let totalTokens = max(rawPromptTokenEstimate ?? contentTokens, contentTokens)
        return PromptTokenBreakdown(
            totalTokens: totalTokens,
            systemTokens: systemTokens,
            userTokens: userTokens,
            assistantTokens: assistantTokens,
            toolTokens: toolTokens,
            otherTokens: otherTokens,
            formatOverheadTokens: max(0, totalTokens - contentTokens),
            turnCount: transcript.turns.count
        )
    }

    /// CJK 范围: 主要汉字 + 假名 + 韩文 + 全角标点。
    /// 这些字符在 SentencePiece BPE 中通常 1-2 token,远低于拉丁文的 4 字/token。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3000...0x303F).contains(v)   // CJK Symbols and Punctuation
            || (0x3040...0x309F).contains(v)   // Hiragana
            || (0x30A0...0x30FF).contains(v)   // Katakana
            || (0x3400...0x4DBF).contains(v)   // CJK Unified Ideographs Ext A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs (主)
            || (0xAC00...0xD7AF).contains(v)   // Hangul Syllables
            || (0xF900...0xFAFF).contains(v)   // CJK Compatibility Ideographs
            || (0xFF00...0xFFEF).contains(v)   // Halfwidth and Fullwidth Forms
            || (0x20000...0x2A6DF).contains(v) // CJK Unified Ideographs Ext B
    }
}

public enum PromptTranscriptRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
    case unknown

    init(rawGemmaRole: String) {
        switch rawGemmaRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system":
            self = .system
        case "user":
            self = .user
        case "model", "assistant":
            self = .assistant
        case "tool", "skill", "skill_result":
            self = .tool
        default:
            self = .unknown
        }
    }
}

public struct PromptTranscriptTurn: Sendable, Codable, Equatable {
    public let role: PromptTranscriptRole
    public let rawRole: String
    public let content: String
    public let tokenEstimate: Int

    public init(
        role: PromptTranscriptRole,
        rawRole: String,
        content: String,
        tokenEstimate: Int? = nil
    ) {
        self.role = role
        self.rawRole = rawRole
        self.content = content
        self.tokenEstimate = tokenEstimate ?? PromptTokenEstimator.estimate(content)
    }

    public func truncated(toTokenBudget maxTokens: Int) -> PromptTranscriptTurn? {
        guard maxTokens > 0 else { return nil }
        guard tokenEstimate > maxTokens else { return self }

        var candidate = content
        let ratio = max(0.05, min(1.0, Double(maxTokens) / Double(max(tokenEstimate, 1))))
        let initialCount = max(1, Int(Double(candidate.count) * ratio * 0.9))
        candidate = String(candidate.suffix(initialCount))

        while PromptTokenEstimator.estimate(candidate) > maxTokens, candidate.count > 1 {
            let nextCount = max(1, Int(Double(candidate.count) * 0.85))
            candidate = String(candidate.suffix(nextCount))
        }

        let truncatedContent = "...\n\(candidate)"
        return PromptTranscriptTurn(
            role: role,
            rawRole: rawRole,
            content: truncatedContent,
            tokenEstimate: PromptTokenEstimator.estimate(truncatedContent)
        )
    }
}

public struct PromptTranscript: Sendable, Codable, Equatable {
    public let turns: [PromptTranscriptTurn]

    public init(turns: [PromptTranscriptTurn]) {
        self.turns = turns
    }

    public init(gemmaPrompt prompt: String) {
        turns = Self.parseGemmaPrompt(prompt)
    }

    public static func parseGemmaPrompt(_ prompt: String) -> [PromptTranscriptTurn] {
        let open = "<|turn>"
        let close = "<turn|>"
        var remainder = prompt[...]
        var turns: [PromptTranscriptTurn] = []

        while let openRange = remainder.range(of: open) {
            remainder = remainder[openRange.upperBound...]
            let endRange = remainder.range(of: close)
            let body: Substring
            if let endRange {
                body = remainder[..<endRange.lowerBound]
                remainder = remainder[endRange.upperBound...]
            } else {
                body = remainder
                remainder = prompt[prompt.endIndex...]
            }

            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else { continue }
            let parts = trimmedBody.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rolePart = parts.first else { continue }
            let rawRole = rolePart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let content = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let role = PromptTranscriptRole(rawGemmaRole: rawRole)
            if role == .assistant, content.isEmpty {
                continue
            }
            turns.append(
                PromptTranscriptTurn(
                    role: role,
                    rawRole: rawRole,
                    content: content
                )
            )
        }

        return turns
    }

    public func trimmingToTokenBudget(
        _ maxTokens: Int,
        preserveSystemTurns: Bool = true
    ) -> PromptTranscript {
        guard maxTokens > 0 else { return PromptTranscript(turns: []) }
        let currentTokens = turns.reduce(0) { $0 + $1.tokenEstimate }
        guard currentTokens > maxTokens else { return self }

        let systemTurns = preserveSystemTurns ? turns.filter { $0.role == .system } : []
        let systemTokens = systemTurns.reduce(0) { $0 + $1.tokenEstimate }
        var remaining = max(0, maxTokens - systemTokens)
        var retained: [PromptTranscriptTurn] = []

        for turn in turns.reversed() {
            if preserveSystemTurns, turn.role == .system {
                continue
            }
            if turn.tokenEstimate <= remaining {
                retained.append(turn)
                remaining -= turn.tokenEstimate
                continue
            }
            if retained.isEmpty, let truncated = turn.truncated(toTokenBudget: remaining) {
                retained.append(truncated)
            }
            break
        }

        return PromptTranscript(turns: systemTurns + retained.reversed())
    }
}

public struct PromptRuntimeProfile: Sendable, Codable, Equatable {
    public let instructions: String?
    public let prompt: String
    public let transcript: PromptTranscript
    public let tokenBreakdown: PromptTokenBreakdown

    public init(
        instructions: String?,
        prompt: String,
        transcript: PromptTranscript = PromptTranscript(turns: []),
        tokenBreakdown: PromptTokenBreakdown? = nil
    ) {
        let trimmedInstructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructions = trimmedInstructions?.isEmpty == true ? nil : trimmedInstructions
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = transcript
        self.tokenBreakdown = tokenBreakdown ?? PromptTokenEstimator.estimateBreakdown(prompt)
    }

    public static func fromGemmaPrompt(
        _ prompt: String,
        baseInstructions: String? = nil,
        includeSystemTurnsInPrompt: Bool = false
    ) -> PromptRuntimeProfile {
        let transcript = PromptTranscript(gemmaPrompt: prompt)
        guard !transcript.turns.isEmpty else {
            return PromptRuntimeProfile(
                instructions: baseInstructions,
                prompt: prompt,
                transcript: transcript,
                tokenBreakdown: PromptTokenEstimator.estimateBreakdown(prompt)
            )
        }

        let systemInstructions = transcript.turns
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let instructionParts = ([baseInstructions ?? ""] + systemInstructions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let promptTurns = includeSystemTurnsInPrompt
            ? transcript.turns
            : transcript.turns.filter { $0.role != .system }

        return PromptRuntimeProfile(
            instructions: instructionParts.joined(separator: "\n\n"),
            prompt: renderPromptTurns(promptTurns),
            transcript: transcript,
            tokenBreakdown: PromptTokenEstimator.estimateBreakdown(prompt)
        )
    }

    public func applyingTokenBudget(maxInputTokens: Int) -> PromptRuntimeProfile {
        guard maxInputTokens > 0, tokenBreakdown.totalTokens > maxInputTokens else {
            return self
        }

        if !transcript.turns.isEmpty {
            let trimmedTranscript = transcript.trimmingToTokenBudget(
                maxInputTokens,
                preserveSystemTurns: false
            )
            let promptTurns = trimmedTranscript.turns.filter { $0.role != .system }
            let trimmedPrompt = Self.renderPromptTurns(promptTurns)
            return PromptRuntimeProfile(
                instructions: instructions,
                prompt: trimmedPrompt.isEmpty ? Self.truncatePlainPrompt(prompt, maxInputTokens: maxInputTokens) : trimmedPrompt,
                transcript: trimmedTranscript,
                tokenBreakdown: PromptTokenEstimator.estimateTranscript(trimmedTranscript)
            )
        }

        return PromptRuntimeProfile(
            instructions: instructions,
            prompt: Self.truncatePlainPrompt(prompt, maxInputTokens: maxInputTokens),
            transcript: transcript,
            tokenBreakdown: PromptTokenBreakdown(
                totalTokens: min(tokenBreakdown.totalTokens, maxInputTokens),
                systemTokens: 0,
                userTokens: min(tokenBreakdown.userTokens, maxInputTokens),
                assistantTokens: 0,
                toolTokens: 0,
                otherTokens: 0,
                formatOverheadTokens: 0,
                turnCount: tokenBreakdown.turnCount
            )
        )
    }

    private static func truncatePlainPrompt(_ prompt: String, maxInputTokens: Int) -> String {
        guard maxInputTokens > 0, PromptTokenEstimator.estimate(prompt) > maxInputTokens else {
            return prompt
        }
        var candidate = prompt
        while PromptTokenEstimator.estimate(candidate) > maxInputTokens, candidate.count > 1 {
            let nextCount = max(1, Int(Double(candidate.count) * 0.85))
            candidate = String(candidate.suffix(nextCount))
        }
        return "...\n\(candidate)"
    }

    private static func renderPromptTurns(_ turns: [PromptTranscriptTurn]) -> String {
        turns.map { turn in
            switch turn.role {
            case .system:
                return "System:\n\(turn.content)"
            case .user:
                return "User:\n\(turn.content)"
            case .assistant:
                return "Assistant:\n\(turn.content)"
            case .tool:
                return "Tool:\n\(turn.content)"
            case .unknown:
                return "\(turn.rawRole.capitalized):\n\(turn.content)"
            }
        }
        .joined(separator: "\n\n")
    }

    public func chatCompletionMessages() -> [PromptChatMessage] {
        var messages: [PromptChatMessage] = []
        if let instructions {
            messages.append(PromptChatMessage(role: "system", content: instructions))
        }

        if !transcript.turns.isEmpty {
            for turn in transcript.turns where turn.role != .system {
                let role: String
                switch turn.role {
                case .user:
                    role = "user"
                case .assistant:
                    role = "assistant"
                case .tool, .unknown:
                    // PhoneClaw tools are still represented by the app's text protocol.
                    // OpenAI-compatible gateways may reject native "tool" messages without
                    // tool_call_id, so keep non-user/assistant evidence as plain user context.
                    role = "user"
                case .system:
                    continue
                }
                let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                messages.append(PromptChatMessage(role: role, content: content))
            }
        } else {
            let content = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                messages.append(PromptChatMessage(role: "user", content: content))
            }
        }

        return messages.isEmpty ? [PromptChatMessage(role: "user", content: prompt)] : messages
    }
}

public struct PromptChatMessage: Sendable, Codable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public var dictionary: [String: String] {
        ["role": role, "content": content]
    }
}

public struct PromptTokenBreakdown: Sendable, Codable, Equatable {
    public let totalTokens: Int
    public let systemTokens: Int
    public let userTokens: Int
    public let assistantTokens: Int
    public let toolTokens: Int
    public let otherTokens: Int
    public let formatOverheadTokens: Int
    public let turnCount: Int

    public init(
        totalTokens: Int,
        systemTokens: Int,
        userTokens: Int,
        assistantTokens: Int,
        toolTokens: Int,
        otherTokens: Int,
        formatOverheadTokens: Int,
        turnCount: Int
    ) {
        self.totalTokens = totalTokens
        self.systemTokens = systemTokens
        self.userTokens = userTokens
        self.assistantTokens = assistantTokens
        self.toolTokens = toolTokens
        self.otherTokens = otherTokens
        self.formatOverheadTokens = formatOverheadTokens
        self.turnCount = turnCount
    }
}
