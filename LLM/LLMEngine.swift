import Foundation
import CoreImage
import MLXLMCommon

// MARK: - LLM Engine Protocol

/// Thin protocol for on-device LLM inference engines.
public protocol LLMEngine {
    func load() async throws
    func warmup() async throws
    func generateStream(
        prompt: String,
        images: [CIImage],
        audios: [UserInput.Audio]
    ) -> AsyncThrowingStream<String, Error>
    func cancel()
    func unload()
    var stats: LLMStats { get }
    var isLoaded: Bool { get }
    var isGenerating: Bool { get }
}

public extension LLMEngine {
    func generateStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt, images: [], audios: [])
    }

    func generateStream(prompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt, images: images, audios: [])
    }
}

/// Legacy alias kept so existing MLX code can coexist with the new
/// backend-neutral inference layer during migration.
public typealias LLMStats = InferenceStats
