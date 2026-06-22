import Foundation
import CoreImage

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
@Observable
final class FoundationModelsInferenceService: InferenceService {
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var statusMessage = ""
    private(set) var stats = InferenceStats()

    var samplingTopK: Int = 64
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 0.7
    var maxOutputTokens: Int = 1024

    var activeCapabilities: ModelCapabilities? {
        ModelCapabilities(
            supportsVision: false,
            supportsAudio: false,
            supportsLive: true,
            supportsStructuredPlanning: true,
            supportsThinking: false,
            supportsPersistentSession: true,
            supportsSessionSnapshot: false,
            safeContextBudgetTokens: 4096,
            defaultReservedOutputTokens: 700
        )
    }

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var liveSession: LanguageModelSession?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var loadedModelID: String?
    @ObservationIgnored private var liveSystemPrompt: String?

    init() {
        stats.backend = "foundation-models"
        statusMessage = tr("等待 Apple Foundation Models", "Waiting for Apple Foundation Models", "Apple Foundation Models 待機中")
    }

    func load(modelID: String) async throws {
        guard modelID == FoundationModelsCatalog.systemModelID else {
            throw FoundationModelsInferenceError.unsupportedModel(modelID)
        }

        isLoading = true
        defer { isLoading = false }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FoundationModelsInferenceError.unavailable(Self.availabilityDescription(model.availability))
        }

        statusMessage = tr("正在准备 Apple Foundation Models", "Preparing Apple Foundation Models", "Apple Foundation Models 準備中")
        let start = CFAbsoluteTimeGetCurrent()
        let prepared = LanguageModelSession(
            model: model,
            instructions: Self.defaultInstructions
        )
        prepared.prewarm()

        session = prepared
        loadedModelID = modelID
        isLoaded = true
        stats.loadTimeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        statusMessage = tr("Apple Foundation Models 已就绪", "Apple Foundation Models ready", "Apple Foundation Models 準備完了")
    }

    func unload() {
        streamTask?.cancel()
        streamTask = nil
        session = nil
        liveSession = nil
        loadedModelID = nil
        isLoaded = false
        isGenerating = false
        statusMessage = ""
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
    }

    func enterLiveMode(systemPrompt: String?) async throws {
        guard isLoaded else {
            throw ModelBackendError.modelNotLoaded
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FoundationModelsInferenceError.unavailable(Self.availabilityDescription(model.availability))
        }
        liveSystemPrompt = systemPrompt
        liveSession = LanguageModelSession(
            model: model,
            instructions: Self.liveInstructions(systemPrompt)
        )
        liveSession?.prewarm()
    }

    func exitLiveMode() async {
        liveSession = nil
        liveSystemPrompt = nil
    }

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamText(prompt: Self.normalizedPrompt(fromGemmaPrompt: prompt), using: session)
    }

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        if !images.isEmpty {
            PCLog.debug("[FoundationModels] generateRaw ignores \(images.count) image(s); text-only adapter")
        }
        return streamText(prompt: Self.normalizedPrompt(fromGemmaPrompt: text), using: session)
    }

    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        if !images.isEmpty || !audios.isEmpty {
            PCLog.debug("[FoundationModels] generateMultimodal ignores \(images.count) image(s) / \(audios.count) audio input(s); text-only adapter")
        }
        let mergedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? prompt
            : "System:\n\(systemPrompt)\n\nUser:\n\(prompt)"
        return streamText(prompt: mergedPrompt, using: session)
    }

    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        if !images.isEmpty || !audios.isEmpty {
            PCLog.debug("[FoundationModels] generateLive ignores \(images.count) image(s) / \(audios.count) audio input(s); text-only adapter")
        }
        if liveSession == nil {
            liveSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.liveInstructions(liveSystemPrompt)
            )
            liveSession?.prewarm()
        }
        return streamText(prompt: prompt, using: liveSession)
    }

    private func streamText(
        prompt: String,
        using sourceSession: LanguageModelSession?
    ) -> AsyncThrowingStream<String, Error> {
        guard isLoaded, let sourceSession else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let start = CFAbsoluteTimeGetCurrent()
                var firstChunkTime: Double?
                var chunkCount = 0
                var emitted = ""

                self.isGenerating = true
                do {
                    let stream = sourceSession.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            samplingMode: samplingMode,
                            temperature: Double(self.samplingTemperature),
                            maximumResponseTokens: self.maxOutputTokens,
                            toolCallingMode: .disallowed
                        ),
                        contextOptions: ContextOptions(includeSchemaInPrompt: false),
                        metadata: [
                            "phoneclaw_component": "inference_service",
                            "phoneclaw_backend": "foundation_models"
                        ]
                    )

                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        let next = snapshot.content
                        guard next.hasPrefix(emitted) else {
                            // Consumers expect append-only deltas, so do not replay a revised snapshot.
                            emitted = next
                            continue
                        }
                        let suffix = String(next.dropFirst(emitted.count))
                        emitted = next
                        guard !suffix.isEmpty else { continue }
                        if firstChunkTime == nil {
                            firstChunkTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        }
                        chunkCount += 1
                        continuation.yield(suffix)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - start
                self.isGenerating = false
                self.stats.ttftMs = firstChunkTime ?? 0
                self.stats.totalChunks = chunkCount
                self.stats.chunksPerSec = (elapsed > 0 && chunkCount > 0) ? Double(chunkCount) / elapsed : 0
            }
            streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var samplingMode: GenerationOptions.SamplingMode {
        if samplingTemperature <= 0 {
            return .greedy
        }
        if samplingTopP < 1.0 {
            return .random(probabilityThreshold: Double(samplingTopP))
        }
        return .random(top: samplingTopK)
    }

    private static let defaultInstructions = """
    You are PhoneClaw's on-device assistant runtime.
    Follow the prompt's role labels and emit plain assistant text.
    If the prompt asks for a PhoneClaw tool call, emit the exact textual tool-call protocol requested by the prompt.
    """

    private static func liveInstructions(_ systemPrompt: String?) -> String {
        let trimmed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultInstructions
        }
        return "\(defaultInstructions)\n\nUser system prompt:\n\(trimmed)"
    }

    private static func normalizedPrompt(fromGemmaPrompt prompt: String) -> String {
        let turns = parseGemmaTurns(prompt)
        guard !turns.isEmpty else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return turns.map { turn in
            switch turn.role {
            case "system":
                return "System:\n\(turn.content)"
            case "user":
                return "User:\n\(turn.content)"
            case "model", "assistant":
                return "Assistant:\n\(turn.content)"
            default:
                return "\(turn.role.capitalized):\n\(turn.content)"
            }
        }
        .joined(separator: "\n\n")
    }

    private static func parseGemmaTurns(_ prompt: String) -> [(role: String, content: String)] {
        let open = "<|turn>"
        let close = "<turn|>"
        var remainder = prompt[...]
        var turns: [(role: String, content: String)] = []

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
            guard let rawRole = parts.first else { continue }
            let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let content = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            if role == "model", content.isEmpty {
                continue
            }
            turns.append((role: role, content: content))
        }

        return turns
    }

    private static func availabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable_device_not_eligible"
            case .appleIntelligenceNotEnabled:
                return "unavailable_apple_intelligence_not_enabled"
            case .modelNotReady:
                return "unavailable_model_not_ready"
            @unknown default:
                return "unavailable_unknown"
            }
        @unknown default:
            return "unknown"
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
private enum FoundationModelsInferenceError: LocalizedError {
    case unsupportedModel(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let modelID):
            return tr(
                "Apple Foundation Models 不支持模型 \(modelID)",
                "Apple Foundation Models does not support model \(modelID)"
            )
        case .unavailable(let reason):
            return tr(
                "Apple Foundation Models 当前不可用: \(reason)",
                "Apple Foundation Models unavailable: \(reason)"
            )
        }
    }
}
#endif
