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

/// Runtime statistics for the inference engine.
public struct LLMStats {
    public var loadTimeMs: Double = 0
    public var ttftMs: Double = 0          // time to first token
    public var tokensPerSec: Double = 0
    public var peakMemoryMB: Double = 0
    public var totalTokens: Int = 0
    public var backend: String = "unknown"  // "mlx-gpu"

    public init() {}
}
