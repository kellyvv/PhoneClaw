import Foundation
import CoreImage

// MARK: - LLM Engine Protocol

/// Thin protocol for LLM inference engines.
/// Both MLX and MediaPipe implementations conform to this.
public protocol LLMEngine {
    func load() async throws
    func warmup() async throws
    func generateStream(prompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error>
    func cancel()
    func unload()
    var stats: LLMStats { get }
    var isLoaded: Bool { get }
    var isGenerating: Bool { get }
}

public extension LLMEngine {
    func generateStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt, images: [])
    }
}

/// Runtime statistics for the inference engine.
public struct LLMStats {
    public var loadTimeMs: Double = 0
    public var ttftMs: Double = 0          // time to first token
    public var tokensPerSec: Double = 0
    public var peakMemoryMB: Double = 0
    public var totalTokens: Int = 0
    public var backend: String = "unknown"  // "mlx-gpu" | "mediapipe-cpu"

    public init() {}
}
