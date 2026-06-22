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
    @ObservationIgnored private var profileSessionCache: [String: LanguageModelSession] = [:]

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
        let prepared = makeSession(instructions: Self.defaultInstructions)
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
        profileSessionCache.removeAll(keepingCapacity: false)
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
        liveSession = makeSession(instructions: Self.liveInstructions(systemPrompt))
        liveSession?.prewarm()
    }

    func exitLiveMode() async {
        liveSession = nil
        liveSystemPrompt = nil
    }

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamProfile(Self.runtimeProfile(fromGemmaPrompt: prompt), using: session)
    }

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        if !images.isEmpty {
            PCLog.debug("[FoundationModels] generateRaw ignores \(images.count) image(s); text-only adapter")
        }
        return streamProfile(Self.runtimeProfile(fromGemmaPrompt: text), using: session)
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
        return streamProfile(
            PromptRuntimeProfile(
                instructions: Self.instructions(adding: systemPrompt),
                prompt: "User:\n\(prompt)"
            ),
            using: session
        )
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
            liveSession = makeSession(instructions: Self.liveInstructions(liveSystemPrompt))
            liveSession?.prewarm()
        }
        return streamText(prompt: prompt, using: liveSession)
    }

    private func streamProfile(
        _ profile: PromptRuntimeProfile,
        using sourceSession: LanguageModelSession?
    ) -> AsyncThrowingStream<String, Error> {
        guard isLoaded, sourceSession != nil else {
            return AsyncThrowingStream { $0.finish(throwing: ModelBackendError.modelNotLoaded) }
        }

        let requestSession = profileSession(for: profile, fallback: sourceSession)
        return streamText(prompt: profile.prompt, using: requestSession)
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

    private static func runtimeProfile(fromGemmaPrompt prompt: String) -> PromptRuntimeProfile {
        PromptRuntimeProfile.fromGemmaPrompt(
            prompt,
            baseInstructions: defaultInstructions,
            includeSystemTurnsInPrompt: false
        )
    }

    private static func instructions(adding systemPrompt: String?) -> String {
        let trimmed = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultInstructions }
        return "\(defaultInstructions)\n\n\(trimmed)"
    }

    private func profileSession(
        for profile: PromptRuntimeProfile,
        fallback: LanguageModelSession?
    ) -> LanguageModelSession? {
        let instructions = profile.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instructions.isEmpty, instructions != Self.defaultInstructions else {
            return fallback
        }
        if let cached = profileSessionCache[instructions] {
            return cached
        }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return fallback
        }

        if profileSessionCache.count >= 4 {
            profileSessionCache.removeAll(keepingCapacity: true)
        }
        let dynamicSession = makeSession(instructions: instructions)
        dynamicSession.prewarm()
        profileSessionCache[instructions] = dynamicSession
        return dynamicSession
    }

    private func makeSession(instructions: String) -> LanguageModelSession {
        let normalizedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveInstructions = normalizedInstructions.isEmpty ? Self.defaultInstructions : normalizedInstructions
        let profile = LanguageModelSession.Profile {
            Instructions(effectiveInstructions)
        }
        .model(SystemLanguageModel.default)
        .toolCallingMode(.disallowed)
        .historyTransform { entries in
            Self.trimTranscriptHistory(entries)
        }
        .transcriptErrorHandlingPolicy(.preserveTranscript)
        .onToolCall { call in
            PCLog.debug("[FoundationModels] native tool call observed but execution remains in PhoneClaw tool chain: \(call.toolName)")
        }
        return LanguageModelSession(profile: profile)
    }

    private static let maxTranscriptHistoryEntries = 24

    private static func trimTranscriptHistory(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        guard entries.count > maxTranscriptHistoryEntries else { return entries }
        return Array(entries.suffix(maxTranscriptHistoryEntries))
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
private struct PhoneClawFoundationModelsTool: Tool, @unchecked Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let registeredTool: RegisteredTool

    var name: String { registeredTool.name }

    var description: String {
        let parameters = registeredTool.parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parameters.isEmpty else { return registeredTool.description }
        return "\(registeredTool.description)\nParameters: \(parameters)"
    }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "\(Self.schemaNamePrefix)\(registeredTool.name)",
            description: "Arguments for \(registeredTool.name). \(registeredTool.parameters)",
            properties: []
        )
        return (try? GenerationSchema(root: root, dependencies: [])) ?? GeneratedContent.generationSchema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let args = Self.dictionary(from: arguments)
        let result: CanonicalToolResult
        if let executeCanonical = registeredTool.executeCanonical {
            result = try await executeCanonical(args)
        } else {
            let raw = try await registeredTool.execute(args)
            result = canonicalToolResult(toolName: registeredTool.name, toolResult: raw)
        }
        return Self.jsonPayload(for: result)
    }

    private static let schemaNamePrefix = "PhoneClawToolArguments_"

    private static func dictionary(from content: GeneratedContent) -> [String: Any] {
        if let value = anyValue(from: content) as? [String: Any] {
            return value
        }
        guard let data = content.jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func anyValue(from content: GeneratedContent) -> Any? {
        switch content.kind {
        case .null:
            return nil
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.compactMap { anyValue(from: $0) }
        case .structure(let properties, let orderedKeys):
            var result: [String: Any] = [:]
            let keys = orderedKeys.isEmpty ? Array(properties.keys).sorted() : orderedKeys
            for key in keys {
                guard let value = properties[key],
                      let converted = anyValue(from: value) else {
                    continue
                }
                result[key] = converted
            }
            return result
        @unknown default:
            return nil
        }
    }

    private static func jsonPayload(for result: CanonicalToolResult) -> String {
        var payload: [String: Any] = [
            "success": result.success,
            "summary": result.summary,
            "detail": result.detail
        ]
        if let errorCode = result.errorCode {
            payload["errorCode"] = errorCode
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return result.summary
        }
        return json
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
