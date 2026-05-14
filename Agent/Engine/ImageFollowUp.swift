import CoreImage
import Foundation

// MARK: - Image Follow-Up Types

struct RecentImageFollowUpContext {
    let attachments: [ChatImageAttachment]
    var assistantSummary: String
    var remainingTextFollowUps: Int
}

enum ImageFollowUpRoute {
    case normalText
    case imageText
    case reMultimodal
}

// MARK: - Image Follow-Up Extension
//
// 图片追问路由逻辑: 用户发了一张图后, 后续文字追问可能需要
// re-multimodal (重发图) 或 image-text bridge (用摘要代替图) 或
// 直接文本回复。这里的方法管理追问上下文和路由决策。

extension AgentEngine {

    func clearRecentImageFollowUpContexts() {
        recentImageFollowUpContexts.removeAll()
    }

    func sameImageAttachments(
        _ lhs: [ChatImageAttachment],
        _ rhs: [ChatImageAttachment]
    ) -> Bool {
        lhs.map(\.id) == rhs.map(\.id)
    }

    func recordRecentImageFollowUpContext(
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

    func latestActiveImageFollowUpContext() -> RecentImageFollowUpContext? {
        guard HotfixFeatureFlags.useHotfixPromptPipeline,
              HotfixFeatureFlags.enableImageFollowUpRegrounding else {
            return nil
        }

        return recentImageFollowUpContexts.first(where: { $0.remainingTextFollowUps > 0 })
    }

    func consumeActiveImageFollowUpContext() {
        guard !recentImageFollowUpContexts.isEmpty else { return }
        recentImageFollowUpContexts[0].remainingTextFollowUps -= 1
        if recentImageFollowUpContexts[0].remainingTextFollowUps <= 0 {
            recentImageFollowUpContexts.removeFirst()
        }
    }

    func classifyImageFollowUpRoute(
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

    func needsImageFollowUpTextRepair(_ text: String) -> Bool {
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

    func imageFollowUpFallbackReply(
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

    func streamImageFollowUpStableReply(
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
}
