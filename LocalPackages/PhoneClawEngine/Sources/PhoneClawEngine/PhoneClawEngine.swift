import Foundation
import CoreGraphics
import ImageIO
import os
import CLiteRTLM

// MARK: - Companion dylib preloading
//
// iOS's bare-name `dlopen` does not reliably search @rpath, so any dylibs
// the underlying runtime tries to load by short name may fail even when
// they are bundled alongside the app. The workaround below preloads them
// by absolute path from the app's Frameworks directory before any runtime
// C API call, so that subsequent bare-name dlopens from the runtime
// return the already-registered image.

/// Preload a companion dylib by basename from the app's Frameworks directory.
/// Returns true if dyld registered the image, false otherwise.
@discardableResult
private func _preloadCompanionDylib(_ fileName: String, category: String) -> Bool {
    let log = Logger(subsystem: "PhoneClawEngine", category: category)

    var searchURLs: [URL] = []
    if let frameworksURL = Bundle.main.privateFrameworksURL {
        searchURLs.append(frameworksURL.appendingPathComponent(fileName))
        searchURLs.append(
            frameworksURL
                .appendingPathComponent("CLiteRTLM.framework")
                .appendingPathComponent(fileName)
        )
    }
    if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
        searchURLs.append(main.appendingPathComponent("Frameworks/\(fileName)"))
    }

    for url in searchURLs {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        if dlopen(url.path, RTLD_NOW | RTLD_GLOBAL) != nil {
            log.info("Preloaded \(fileName, privacy: .public) from \(url.path, privacy: .public)")
            return true
        } else if let err = dlerror() {
            log.error("dlopen failed for \(url.path, privacy: .public): \(String(cString: err), privacy: .public)")
        }
    }

    log.warning("\(fileName, privacy: .public) not preloaded — the corresponding backend will fall back. Searched: \(searchURLs.map(\.path).joined(separator: ", "), privacy: .public)")
    return false
}

private let _preloadGpuAcceleratorOnce: Void = {
    _preloadCompanionDylib("libLiteRtMetalAccelerator.dylib",
                           category: "Accelerator")
}()

/// The Metal TopK sampler is optional — its absence only costs ~1 % decode
/// time (factory falls back to CPU sampling). We still try to preload it
/// because the dylib is tiny (~2 MB) and avoids a 500 µs/token logits copy.
private let _preloadMetalSamplerOnce: Void = {
    _preloadCompanionDylib("libLiteRtTopKMetalSampler.dylib",
                           category: "Sampler")
}()

/// Swift wrapper for Google's LiteRT-LM on-device inference engine.
///
/// Supports text generation (Session API) and multimodal inference — vision
/// and audio — (Conversation API) with `.litertlm` model files (e.g. Gemma 4 E2B).
///
/// Thread safety: most C API calls are serialized on an internal dispatch
/// queue. Persistent conversation pointer lifecycle is additionally protected
/// by `conversationLock` so `cancelConversation()` can signal the C engine
/// immediately from another thread without racing `closeConversation()`.
/// The class is `@unchecked Sendable` because raw pointers still require
/// explicit synchronization.
///
/// ## Quick Start
/// ```swift
/// let engine = LiteRTLMEngine(modelPath: modelURL)
/// try await engine.load()
///
/// // Text
/// let response = try await engine.generate(prompt: "Hello!", temperature: 0.7, maxTokens: 256)
///
/// // Vision
/// let caption = try await engine.vision(imageData: jpegData, prompt: "Describe this photo.")
///
/// // Audio
/// let transcript = try await engine.audio(audioData: wavData, prompt: "Transcribe this audio.")
/// ```
@Observable
public final class LiteRTLMEngine: @unchecked Sendable {

    public struct SessionBenchmarkSnapshot: Sendable, Equatable {
        public let prefillTokenCounts: [Int]
        public let decodeTokenCounts: [Int]

        public init(prefillTokenCounts: [Int], decodeTokenCounts: [Int]) {
            self.prefillTokenCounts = prefillTokenCounts
            self.decodeTokenCounts = decodeTokenCounts
        }
    }

    // MARK: - Types

    public enum Status: Sendable, Equatable {
        case notLoaded
        case loading
        case ready
        case error(String)
    }

    // MARK: - Properties

    public private(set) var status: Status = .notLoaded

    /// Whether the engine is ready for inference (text, vision, and audio).
    public var isReady: Bool { status == .ready }

    private let modelPath: URL
    private let backend: String
    /// Vision encoder backend (`"gpu"` / `"cpu"`). `nil` = vision encoder is NOT loaded
    /// — saves ~300-500 MB for text-only chat on Gemma 3n E4B. Matches
    /// Google AI Edge Gallery (Android) behavior: text-only sessions pass
    /// `visionBackend = null` so SigLIP weights + XNNPack cache never enter memory.
    private let visionBackend: String?
    /// Audio encoder backend (`"cpu"` recommended). `nil` = audio encoder is NOT loaded
    /// — saves ~300-600 MB for text-only chat on Gemma 3n E4B. Same rationale as
    /// `visionBackend`.
    private let audioBackend: String?
    /// Max KV-cache slots (tokens). Controls the size of Metal KV buffer pre-allocated
    /// at `openSession()`. Smaller = less pinned GPU memory, smaller context budget.
    ///
    /// Per-model constraints:
    /// - Gemma 3n E2B/E4B: fixed at `ekv4096` in the .litertlm — **only 4096 works**.
    ///   Setting below 2048 fails with DYNAMIC_UPDATE_SLICE.
    /// - Gemma 4 E2B/E4B: compiled with 32K context support — values 2048 / 3072 /
    ///   4096 all load. 2048 is the sweet spot for iPhone memory.
    /// - Qwen/DeepSeek/Phi/Gemma3-1B: check the `ekvNNNN` suffix on the model file
    ///   name for the compile-time ceiling.
    ///
    /// Default 4096 for safety — callers should drop to 2048 for Gemma 4 on mobile.
    private let maxTokens: Int
    /// Enable runtime benchmark mode (prefill/decode token + throughput stats).
    /// Populates `lastSessionBenchmarkSnapshot`. Costs some memory for rolling
    /// stats arrays + log output. Disable in production for small memory savings.
    /// Default `true` preserves original behavior.
    private let enableBenchmark: Bool
    /// Enable speculative decoding using the bundled MTP drafter.
    /// When `true`, a small drafter predicts N tokens per decode step and the
    /// main model verifies them in one forward pass → ~1.5-2x decode throughput
    /// when predictions are mostly correct. Drafter materializes ~300-400 MB
    /// of extra weights into RAM while active — disable on tight-memory paths.
    /// Requires the model file to ship an MTP drafter section (Gemma 4 does;
    /// Gemma 3n does not). Default `false` (conservative).
    private let enableSpeculativeDecoding: Bool

    private var engine: OpaquePointer?  // LiteRtLmEngine*
    // QoS .default matches the background thread that C API callbacks fire on,
    // avoiding priority inversion when semaphore.wait() blocks for streaming.
    private let inferenceQueue = DispatchQueue(label: "com.litertlm.inference", qos: .default)
    private let conversationLock = NSLock()

    private static let log = Logger(subsystem: "PhoneClawEngine", category: "Engine")
    public private(set) var lastSessionBenchmarkSnapshot: SessionBenchmarkSnapshot?

    // MARK: - Init

    /// Create an engine instance.
    /// - Parameters:
    ///   - modelPath: Path to the `.litertlm` model file on disk.
    ///   - backend: Compute backend — `"cpu"` or `"gpu"` (GPU uses Metal on iOS).
    ///   - visionBackend: Vision encoder backend (`"gpu"` / `"cpu"`) or `nil` to skip
    ///     loading the vision encoder entirely. Default `nil` — saves significant memory
    ///     for text-only chat. Set to `"gpu"` for image input (recommended for Gemma 3n).
    ///   - audioBackend: Audio encoder backend (`"cpu"`) or `nil` to skip loading.
    ///     Default `nil`. Set to `"cpu"` for audio input (Gemma 3n audio rejects GPU).
    ///   - maxTokens: Max KV-cache slots (default 4096). Drop to 2048 for Gemma 4 on
    ///     iPhone to save ~500 MB of pinned GPU memory. See `maxTokens` property
    ///     doc for per-model constraints.
    ///   - enableBenchmark: Enable prefill/decode timing stats (default `true`).
    ///     Set `false` for production to save memory + log noise.
    ///   - enableSpeculativeDecoding: Use bundled MTP drafter for ~1.5-2x decode
    ///     throughput (default `false`). Adds ~300-400 MB RAM. Gemma 4 only.
    public init(
        modelPath: URL,
        backend: String = "cpu",
        visionBackend: String? = nil,
        audioBackend: String? = nil,
        maxTokens: Int = 4096,
        enableBenchmark: Bool = true,
        enableSpeculativeDecoding: Bool = false
    ) {
        self.modelPath = modelPath
        self.backend = backend
        self.visionBackend = visionBackend
        self.audioBackend = audioBackend
        self.maxTokens = maxTokens
        self.enableBenchmark = enableBenchmark
        self.enableSpeculativeDecoding = enableSpeculativeDecoding
    }

    deinit {
        let eng = engine
        let ses = chatSession
        let sesCfg = chatSessionConfig
        let convTriplet = detachConversationTriplet()
        let queue = inferenceQueue
        if eng != nil || ses != nil || convTriplet.conversation != nil {
            queue.async {
                if let s = ses { litert_lm_session_delete(s) }
                if let c = sesCfg { litert_lm_session_config_delete(c) }
                if let c = convTriplet.conversation { litert_lm_conversation_delete(c) }
                if let c = convTriplet.config { litert_lm_conversation_config_delete(c) }
                if let c = convTriplet.sessionConfig { litert_lm_session_config_delete(c) }
                if let e = eng { litert_lm_engine_delete(e) }
            }
        }
    }

    // MARK: - Lifecycle

    /// Load the `.litertlm` model. Call once, reuse for multiple inferences.
    /// Vision and audio encoders are embedded in the model file — no separate load step needed.
    @MainActor
    public func load() async throws {
        guard status != .ready && status != .loading else { return }

        status = .loading
        Self.log.debug("Loading model: \(self.modelPath.lastPathComponent), backend: \(self.backend)")

        let path = modelPath.path
        let backendStr = self.backend
        let visionBackendStr = self.visionBackend
        let audioBackendStr = self.audioBackend
        let maxTokensValue = Int32(self.maxTokens)
        let benchmarkEnabled = self.enableBenchmark
        let speculativeEnabled = self.enableSpeculativeDecoding
        let startTime = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: path) else {
            let msg = "Model file not found at \(path)"
            Self.log.error("\(msg)")
            status = .error(msg)
            throw LiteRTLMError.modelNotFound
        }

        // Force companion dylib preloads before any runtime C API call.
        // CPU backend: no-ops. GPU backend: registers the Metal backend and
        // the sampler dylib so subsequent runtime-side dlopens resolve.
        if backendStr == "gpu" {
            _ = _preloadGpuAcceleratorOnce
            _ = _preloadMetalSamplerOnce
        }

        do {
            let createdEngine = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OpaquePointer, any Error>) in
                self.inferenceQueue.async {
                    do {
                        litert_lm_set_min_log_level(0)  // DEBUG: show all GPU/Metal init logs

                        // Pass NULL (not "cpu") when vision/audio encoders are not
                        // needed — mirrors Google AI Edge Gallery (Android)
                        // `EngineConfig(visionBackend = null, audioBackend = null)`
                        // for text-only chat. Loading unused encoders costs
                        // ~800 MB-1.3 GB for Gemma 3n E4B (SigLIP + USM + XNNPack caches).
                        //
                        // C API: `const char*` with NULL semantics per engine.h:
                        //   "The vision backend to use, or NULL if not set."
                        //
                        // `withCString` guarantees the temporary C buffer lives
                        // for the duration of the closure — we make the engine
                        // settings create call inside that scope.
                        let settings_opt = { () -> OpaquePointer? in
                            switch (visionBackendStr, audioBackendStr) {
                            case (nil, nil):
                                return litert_lm_engine_settings_create(path, backendStr, nil, nil)
                            case (let v?, nil):
                                return v.withCString { vPtr in
                                    litert_lm_engine_settings_create(path, backendStr, vPtr, nil)
                                }
                            case (nil, let a?):
                                return a.withCString { aPtr in
                                    litert_lm_engine_settings_create(path, backendStr, nil, aPtr)
                                }
                            case (let v?, let a?):
                                return v.withCString { vPtr in
                                    a.withCString { aPtr in
                                        litert_lm_engine_settings_create(path, backendStr, vPtr, aPtr)
                                    }
                                }
                            }
                        }()
                        guard let settings = settings_opt else {
                            throw LiteRTLMError.engineCreationFailed("Failed to create engine settings")
                        }

                        // KV-cache size. Previously hardcoded at 4096 — the
                        // comment below describes **Gemma 3n** constraints, not
                        // **Gemma 4** (the current production model):
                        //   - Gemma 3n E2B/E4B: .litertlm is compiled with
                        //     ekv4096. <=2048 fails DYNAMIC_UPDATE_SLICE.
                        //   - Gemma 4 E2B/E4B: compiled with 32K max context,
                        //     values 2048 / 3072 / 4096 all load.
                        // Caller passes the right value via `maxTokens:`.
                        litert_lm_engine_settings_set_max_num_tokens(settings, maxTokensValue)

                        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("litertlm_cache").path
                        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
                        litert_lm_engine_settings_set_cache_dir(settings, cacheDir)

                        // Benchmark mode: stores rolling prefill/decode stats in memory.
                        // Useful for dev (populates `lastSessionBenchmarkSnapshot`), but
                        // small memory tax + log noise in production.
                        if benchmarkEnabled {
                            litert_lm_engine_settings_enable_benchmark(settings)
                        }

                        // Speculative decoding (MTP drafter). When on, decode path
                        // pulls the drafter section from the .litertlm into RAM
                        // (~300-400 MB) and runs draft+verify every step. See
                        // `enableSpeculativeDecoding` property doc.
                        litert_lm_engine_settings_set_enable_speculative_decoding(
                            settings, speculativeEnabled
                        )

                        guard let createdEngine = litert_lm_engine_create(settings) else {
                            litert_lm_engine_settings_delete(settings)
                            throw LiteRTLMError.engineCreationFailed("litert_lm_engine_create returned NULL")
                        }
                        litert_lm_engine_settings_delete(settings)

                        continuation.resume(returning: createdEngine)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            inferenceQueue.sync { self.engine = createdEngine }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            Self.log.debug("Model loaded in \(String(format: "%.1f", elapsed))s")
            status = .ready
        } catch {
            let msg = "Load failed: \(error.localizedDescription)"
            Self.log.error("\(msg)")
            status = .error(msg)
            throw error
        }
    }

    /// Unload the model to free memory.
    @MainActor
    public func unload() {
        inferenceQueue.sync {
            if let s = chatSession {
                litert_lm_session_delete(s)
                chatSession = nil
            }
            if let c = chatSessionConfig {
                litert_lm_session_config_delete(c)
                chatSessionConfig = nil
            }
            let triplet = detachConversationTriplet()
            if let c = triplet.conversation {
                litert_lm_conversation_delete(c)
            }
            if let c = triplet.config {
                litert_lm_conversation_config_delete(c)
            }
            if let c = triplet.sessionConfig {
                litert_lm_session_config_delete(c)
            }
            if let eng = engine { litert_lm_engine_delete(eng) }
            engine = nil
        }
        status = .notLoaded
        Self.log.info("Model unloaded")
    }

    // MARK: - Text Generation (Session API)

    /// Generate text from a prompt. Creates a one-shot session per call.
    ///
    /// - Parameters:
    ///   - prompt: The input text. For Gemma 4, use `<|turn>user\n...<turn|>\n<|turn>model\n` format.
    ///   - temperature: Sampling temperature (0.0 = deterministic, 1.0 = creative). Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 512.
    /// - Returns: Generated text.
    public func generate(
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 512
    ) async throws -> String {
        try ensureReady()
        return try await runSessionInference(
            prompt: prompt, temperature: temperature, maxTokens: Int32(maxTokens)
        )
    }

    /// Stream text generation token by token.
    ///
    /// Creates a one-shot session per call. For multi-turn conversations with
    /// KV cache reuse, use the persistent session API instead.
    ///
    /// - Parameters:
    ///   - prompt: The input text.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 512.
    /// - Returns: An `AsyncThrowingStream` yielding text chunks.
    public func generateStreaming(
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        runSessionInferenceStreaming(
            prompt: prompt, temperature: temperature, maxTokens: Int32(maxTokens)
        )
    }

    // MARK: - Vision (Conversation API)

    /// Run vision inference on a single image.
    ///
    /// Uses the Conversation API, which handles image decoding, resizing, and
    /// patchification internally. Input images are auto-converted to JPEG and
    /// resized to fit within `maxImageDimension`.
    ///
    /// - Parameters:
    ///   - imageData: Raw image bytes (JPEG, PNG, HEIC, etc.).
    ///   - prompt: Text prompt for the vision model (e.g., "Describe this photo.").
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 512.
    ///   - maxImageDimension: Resize long edge to this value. Default 1024.
    /// - Returns: Generated text response.
    public func vision(
        imageData: Data,
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 512,
        maxImageDimension: Int = 1024
    ) async throws -> String {
        try ensureReady()

        guard let jpegData = Self.prepareImageForVision(imageData, maxDimension: maxImageDimension) else {
            throw LiteRTLMError.inferenceFailure("Failed to convert image to JPEG")
        }

        let tempURL = Self.makeTempURL(extension: "jpg")
        try jpegData.write(to: tempURL)

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: [], imagePaths: [tempURL.path], text: prompt
        )
        return try await runConversationInference(
            messageJSON: messageJSON,
            tempURLs: [tempURL],
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    /// Run vision inference on multiple images.
    ///
    /// - Parameters:
    ///   - imagesData: Array of raw image bytes.
    ///   - prompt: Text prompt about the images.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 1024.
    ///   - maxImageDimension: Resize long edge to this value. Default 1024.
    /// - Returns: Generated text response.
    public func visionMultiImage(
        imagesData: [Data],
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 1024,
        maxImageDimension: Int = 1024
    ) async throws -> String {
        try ensureReady()
        guard !imagesData.isEmpty else {
            throw LiteRTLMError.inferenceFailure("No images provided")
        }

        var tempURLs: [URL] = []
        do {
            for (i, data) in imagesData.enumerated() {
                guard let jpegData = Self.prepareImageForVision(data, maxDimension: maxImageDimension) else {
                    throw LiteRTLMError.inferenceFailure("Failed to convert image \(i + 1) to JPEG")
                }
                let url = Self.makeTempURL(extension: "jpg")
                try jpegData.write(to: url)
                tempURLs.append(url)
            }
        } catch {
            Self.cleanupTempFiles(tempURLs)
            throw error
        }

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: [], imagePaths: tempURLs.map(\.path), text: prompt
        )
        return try await runConversationInference(
            messageJSON: messageJSON,
            tempURLs: tempURLs,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    // MARK: - Audio (Conversation API)

    /// Supported audio formats for the `audio()` and `multimodal()` methods.
    public enum AudioFormat: String, Sendable {
        case wav, flac, mp3
    }

    /// Run audio inference on a single audio file.
    ///
    /// Uses the Conversation API, which handles audio decoding and preprocessing
    /// (resample to 16 kHz, convert to mel spectrogram) internally.
    ///
    /// - Parameters:
    ///   - audioData: Raw audio bytes (WAV, FLAC, or MP3).
    ///   - prompt: Text prompt (e.g., "Transcribe this audio.", "Summarize what is being said.").
    ///   - format: Audio container format. Default `.wav`.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 512.
    /// - Returns: Generated text response.
    public func audio(
        audioData: Data,
        prompt: String,
        format: AudioFormat = .wav,
        temperature: Float = 0.7,
        maxTokens: Int = 512
    ) async throws -> String {
        try ensureReady()
        guard !audioData.isEmpty else {
            throw LiteRTLMError.inferenceFailure("No audio data provided")
        }

        let tempURL = Self.makeTempURL(extension: format.rawValue)
        try audioData.write(to: tempURL)

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: [tempURL.path], imagePaths: [], text: prompt
        )
        return try await runConversationInference(
            messageJSON: messageJSON,
            tempURLs: [tempURL],
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    /// Stream audio inference token by token.
    ///
    /// Same as `audio()` but returns an `AsyncThrowingStream` yielding text chunks.
    public func audioStreaming(
        audioData: Data,
        prompt: String,
        format: AudioFormat = .wav,
        temperature: Float = 0.7,
        maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        guard status == .ready else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.modelNotLoaded) }
        }
        guard !audioData.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("No audio data provided")) }
        }

        do {
            let tempURL = Self.makeTempURL(extension: format.rawValue)
            try audioData.write(to: tempURL)

            let messageJSON = Self.buildMultimodalMessageJSON(
                audioPaths: [tempURL.path], imagePaths: [], text: prompt
            )
            return runConversationInferenceStreaming(
                messageJSON: messageJSON,
                tempURLs: [tempURL],
                temperature: temperature,
                maxTokens: maxTokens
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// Run multimodal inference combining audio, images, and text in a single query.
    ///
    /// Useful for tasks like "describe what's happening in this video" where you have
    /// both the audio track and keyframes, or "does this photo match what the speaker describes?".
    ///
    /// - Parameters:
    ///   - audioData: Array of raw audio bytes (WAV, FLAC, or MP3). Pass empty array to skip.
    ///   - imagesData: Array of raw image bytes (JPEG, PNG, HEIC). Pass empty array to skip.
    ///   - prompt: Text prompt about the audio and/or images.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 1024.
    ///   - maxImageDimension: Resize image long edge to this value. Default 1024.
    /// - Returns: Generated text response.
    public func multimodal(
        audioData: [Data] = [],
        audioFormat: AudioFormat = .wav,
        imagesData: [Data] = [],
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 1024,
        maxImageDimension: Int = 1024
    ) async throws -> String {
        try ensureReady()
        guard !audioData.isEmpty || !imagesData.isEmpty else {
            throw LiteRTLMError.inferenceFailure("No audio or image data provided")
        }

        var tempURLs: [URL] = []
        var audioPaths: [String] = []
        var imagePaths: [String] = []

        do {
            // Write audio files
            for (i, data) in audioData.enumerated() {
                guard !data.isEmpty else {
                    throw LiteRTLMError.inferenceFailure("Audio data \(i + 1) is empty")
                }
                let url = Self.makeTempURL(extension: audioFormat.rawValue)
                try data.write(to: url)
                tempURLs.append(url)
                audioPaths.append(url.path)
            }

            // Write image files
            for (i, data) in imagesData.enumerated() {
                guard let jpegData = Self.prepareImageForVision(data, maxDimension: maxImageDimension) else {
                    throw LiteRTLMError.inferenceFailure("Failed to convert image \(i + 1) to JPEG")
                }
                let url = Self.makeTempURL(extension: "jpg")
                try jpegData.write(to: url)
                tempURLs.append(url)
                imagePaths.append(url.path)
            }
        } catch {
            Self.cleanupTempFiles(tempURLs)
            throw error
        }

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: audioPaths, imagePaths: imagePaths, text: prompt
        )
        return try await runConversationInference(
            messageJSON: messageJSON,
            tempURLs: tempURLs,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    /// Stream multimodal inference token by token.
    ///
    /// Same as `multimodal()` but returns an `AsyncThrowingStream` yielding text chunks
    /// as they are generated, enabling real-time UI updates.
    ///
    /// - Parameters:
    ///   - audioData: Array of raw audio bytes. Pass empty array to skip.
    ///   - audioFormat: Audio format. Default `.wav`.
    ///   - imagesData: Array of raw image bytes. Pass empty array to skip.
    ///   - prompt: Text prompt.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens to generate. Default 1024.
    ///   - maxImageDimension: Resize image long edge. Default 1024.
    /// - Returns: An `AsyncThrowingStream` yielding text chunks.
    public func multimodalStreaming(
        audioData: [Data] = [],
        audioFormat: AudioFormat = .wav,
        imagesData: [Data] = [],
        prompt: String,
        temperature: Float = 0.7,
        maxTokens: Int = 1024,
        maxImageDimension: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        guard status == .ready else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.modelNotLoaded) }
        }
        guard !audioData.isEmpty || !imagesData.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("No audio or image data provided")) }
        }

        var tempURLs: [URL] = []
        var audioPaths: [String] = []
        var imagePaths: [String] = []

        do {
            for (i, data) in audioData.enumerated() {
                guard !data.isEmpty else {
                    Self.cleanupTempFiles(tempURLs)
                    return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("Audio data \(i + 1) is empty")) }
                }
                let url = Self.makeTempURL(extension: audioFormat.rawValue)
                try data.write(to: url)
                tempURLs.append(url)
                audioPaths.append(url.path)
            }
            for (i, data) in imagesData.enumerated() {
                guard let jpegData = Self.prepareImageForVision(data, maxDimension: maxImageDimension) else {
                    Self.cleanupTempFiles(tempURLs)
                    return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("Failed to convert image \(i + 1) to JPEG")) }
                }
                let url = Self.makeTempURL(extension: "jpg")
                try jpegData.write(to: url)
                tempURLs.append(url)
                imagePaths.append(url.path)
            }
        } catch {
            Self.cleanupTempFiles(tempURLs)
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: audioPaths, imagePaths: imagePaths, text: prompt
        )
        return runConversationInferenceStreaming(
            messageJSON: messageJSON,
            tempURLs: tempURLs,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }

    // MARK: - Persistent Session (KV Cache Reuse)
    //
    // LiteRT-LM's Session maintains a KV cache across multiple generate_content
    // calls. By keeping the session alive across turns, subsequent messages only
    // need to prefill NEW tokens instead of the entire conversation history.
    // This reduces TTFT from ~20s (full prefill) to ~1-2s (incremental).

    private var chatSession: OpaquePointer?
    private var chatSessionConfig: OpaquePointer?

    /// Open a persistent session for multi-turn generation with KV cache reuse.
    ///
    /// Call once when a conversation begins. Subsequent calls to
    /// `sessionGenerateStreaming(input:)` reuse this session's KV cache.
    ///
    /// - Parameters:
    ///   - temperature: Sampling temperature. Default 0.3.
    ///   - maxTokens: Maximum tokens per generation. Default 512.
    public func openSession(temperature: Float = 0.3, maxTokens: Int = 512) async throws {
        try ensureReady()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            inferenceQueue.async { [self] in
                do {
                    if let s = chatSession {
                        litert_lm_session_delete(s)
                        chatSession = nil
                    }
                    if let c = chatSessionConfig {
                        litert_lm_session_config_delete(c)
                        chatSessionConfig = nil
                    }

                    guard let eng = engine else { throw LiteRTLMError.modelNotLoaded }
                    let (session, config) = try createSession(
                        engine: eng, temperature: temperature, maxTokens: Int32(maxTokens)
                    )
                    chatSession = session
                    chatSessionConfig = config
                    Self.log.info("Persistent session opened")
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Close the persistent session, freeing KV cache memory.
    public func closeSession() {
        inferenceQueue.async { [self] in
            guard chatSession != nil else { return }
            if let s = chatSession {
                logSessionBenchmark(s)
                litert_lm_session_delete(s)
                chatSession = nil
            }
            if let c = chatSessionConfig {
                litert_lm_session_config_delete(c)
                chatSessionConfig = nil
            }
            Self.log.info("Persistent session closed")
        }
    }

    // MARK: - Persistent Conversation (Multimodal KV Cache Reuse)
    //
    // Like the text-only persistent session above, but uses the Conversation
    // API — supporting images, audio, and text. The conversation's KV cache
    // persists across turns, so follow-up messages only prefill new tokens.

    private var multimodalConversation: OpaquePointer?
    private var multimodalConvConfig: OpaquePointer?
    private var multimodalSessionConfig: OpaquePointer?
    private var nextConversationStreamID: UInt64 = 0
    private var activeConversationStreamID: UInt64?
    private var activeConversationCancelUptimeNs: UInt64?

    private typealias ConversationTriplet = (
        conversation: OpaquePointer?,
        config: OpaquePointer?,
        sessionConfig: OpaquePointer?
    )

    private func detachConversationTriplet() -> ConversationTriplet {
        conversationLock.lock()
        defer { conversationLock.unlock() }
        let triplet = (
            conversation: multimodalConversation,
            config: multimodalConvConfig,
            sessionConfig: multimodalSessionConfig
        )
        multimodalConversation = nil
        multimodalConvConfig = nil
        multimodalSessionConfig = nil
        activeConversationStreamID = nil
        activeConversationCancelUptimeNs = nil
        return triplet
    }

    nonisolated private static func monotonicNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Open a persistent multimodal conversation with KV cache reuse.
    ///
    /// Call once when a conversation begins. Subsequent calls to
    /// `conversationSend(...)` reuse this conversation's KV cache,
    /// reducing TTFT from ~20s to ~1-2s for follow-up turns.
    ///
    /// - Parameters:
    ///   - systemMessage: Optional system instruction for the conversation.
    ///     The wrapper serializes it into the Conversation API JSON message format.
    ///   - toolsJSON: Optional raw tools schema JSON.
    ///   - messagesJSON: Optional raw initial messages JSON.
    ///   - enableConstrainedDecoding: Whether to enable constrained decoding.
    ///   - temperature: Sampling temperature. Default 0.7.
    ///   - maxTokens: Maximum tokens per generation. Default 1024.
    public func openConversation(
        systemMessage: String? = nil,
        toolsJSON: String? = nil,
        messagesJSON: String? = nil,
        enableConstrainedDecoding: Bool = false,
        temperature: Float = 0.7,
        maxTokens: Int = 1024
    ) async throws {
        try ensureReady()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            inferenceQueue.async { [self] in
                do {
                    // Close existing conversation if any
                    let previousTriplet = detachConversationTriplet()
                    if let c = previousTriplet.conversation {
                        litert_lm_conversation_delete(c)
                    }
                    if let c = previousTriplet.config {
                        litert_lm_conversation_config_delete(c)
                    }
                    if let c = previousTriplet.sessionConfig {
                        litert_lm_session_config_delete(c)
                    }

                    guard let eng = engine else { throw LiteRTLMError.modelNotLoaded }

                    guard let sessionConfig = litert_lm_session_config_create() else {
                        throw LiteRTLMError.inferenceFailure("Failed to create session config")
                    }
                    litert_lm_session_config_set_max_output_tokens(sessionConfig, Int32(maxTokens))
                    var samplerParams = LiteRtLmSamplerParams(
                        type: kTopP, top_k: 40, top_p: 0.95,
                        temperature: temperature, seed: 0
                    )
                    litert_lm_session_config_set_sampler_params(sessionConfig, &samplerParams)

                    let systemMessageJSON = systemMessage.flatMap {
                        Self.buildConversationTextMessageJSON(role: "system", text: $0)
                    }

                    guard let convConfig = Self.withOptionalCString(systemMessageJSON, { systemPtr in
                        Self.withOptionalCString(toolsJSON, { toolsPtr in
                            Self.withOptionalCString(messagesJSON, { messagesPtr in
                                litert_lm_conversation_config_create(
                                    eng,
                                    sessionConfig,
                                    systemPtr,
                                    toolsPtr,
                                    messagesPtr,
                                    enableConstrainedDecoding
                                )
                            })
                        })
                    }) else {
                        litert_lm_session_config_delete(sessionConfig)
                        throw LiteRTLMError.inferenceFailure("Failed to create conversation config")
                    }

                    guard let conversation = litert_lm_conversation_create(eng, convConfig) else {
                        litert_lm_conversation_config_delete(convConfig)
                        litert_lm_session_config_delete(sessionConfig)
                        throw LiteRTLMError.inferenceFailure("Failed to create conversation")
                    }

                    conversationLock.lock()
                    multimodalConversation = conversation
                    multimodalConvConfig = convConfig
                    multimodalSessionConfig = sessionConfig
                    activeConversationStreamID = nil
                    activeConversationCancelUptimeNs = nil
                    conversationLock.unlock()
                    Self.log.info("Persistent multimodal conversation opened")
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Cancel the active generation in the persistent multimodal conversation.
    public func cancelConversation() {
        let nowNs = Self.monotonicNowNs()
        conversationLock.lock()
        guard let conversation = multimodalConversation else {
            conversationLock.unlock()
            return
        }
        let streamID = activeConversationStreamID
        if streamID != nil {
            activeConversationCancelUptimeNs = nowNs
        }
        litert_lm_conversation_cancel_process(conversation)
        conversationLock.unlock()
        if let streamID {
            let tsMs = nowNs / 1_000_000
            Self.log.info("Conversation stream \(streamID, privacy: .public) cancel signal sent at t=\(tsMs, privacy: .public)ms")
        }
    }

    /// Send a message in the persistent multimodal conversation.
    ///
    /// Each call reuses the conversation's KV cache. Pass any combination of
    /// audio, images, and text — or just text for a follow-up question.
    ///
    /// - Parameters:
    ///   - audioData: Array of raw audio bytes. Pass empty array (default) for non-audio turns.
    ///   - audioFormat: Audio container format. Default `.wav`.
    ///   - imagesData: Array of raw image bytes. Pass empty array (default) for non-image turns.
    ///   - prompt: Text prompt for this turn.
    ///   - maxImageDimension: Resize image long edge to this value. Default 1024.
    /// - Returns: Generated text response.
    public func conversationSend(
        audioData: [Data] = [],
        audioFormat: AudioFormat = .wav,
        imagesData: [Data] = [],
        prompt: String,
        maxImageDimension: Int = 1024
    ) async throws -> String {
        try ensureReady()

        // Prepare media files
        var tempURLs: [URL] = []
        var audioPaths: [String] = []
        var imagePaths: [String] = []

        do {
            for (i, data) in audioData.enumerated() {
                guard !data.isEmpty else {
                    throw LiteRTLMError.inferenceFailure("Audio data \(i + 1) is empty")
                }
                let url = Self.makeTempURL(extension: audioFormat.rawValue)
                try data.write(to: url)
                tempURLs.append(url)
                audioPaths.append(url.path)
            }
            for (i, data) in imagesData.enumerated() {
                guard let jpegData = Self.prepareImageForVision(data, maxDimension: maxImageDimension) else {
                    throw LiteRTLMError.inferenceFailure("Failed to convert image \(i + 1) to JPEG")
                }
                let url = Self.makeTempURL(extension: "jpg")
                try jpegData.write(to: url)
                tempURLs.append(url)
                imagePaths.append(url.path)
            }
        } catch {
            Self.cleanupTempFiles(tempURLs)
            throw error
        }

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: audioPaths, imagePaths: imagePaths, text: prompt
        )

        let urlsToCleanup = tempURLs
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            self.inferenceQueue.async { [self, urlsToCleanup] in
                defer { Self.cleanupTempFiles(urlsToCleanup) }
                do {
                    guard let conversation = self.multimodalConversation else {
                        throw LiteRTLMError.inferenceFailure(
                            "No persistent conversation open — call openConversation() first"
                        )
                    }

                    guard let response = messageJSON.withCString({ msgPtr in
                        litert_lm_conversation_send_message(conversation, msgPtr, nil)
                    }) else {
                        throw LiteRTLMError.inferenceFailure("Conversation returned no response")
                    }
                    defer { litert_lm_json_response_delete(response) }

                    guard let responsePtr = litert_lm_json_response_get_string(response) else {
                        throw LiteRTLMError.inferenceFailure("Response string is NULL")
                    }

                    let result = Self.extractTextFromConversationResponse(String(cString: responsePtr))
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stream a message through the persistent multimodal conversation.
    ///
    /// Same as `conversationSend()` but returns an `AsyncThrowingStream`.
    /// The persistent conversation's KV cache is preserved across calls.
    public func conversationSendStreaming(
        audioData: [Data] = [],
        audioFormat: AudioFormat = .wav,
        imagesData: [Data] = [],
        prompt: String,
        maxImageDimension: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        guard status == .ready else {
            return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.modelNotLoaded) }
        }

        var tempURLs: [URL] = []
        var audioPaths: [String] = []
        var imagePaths: [String] = []

        do {
            for (i, data) in audioData.enumerated() {
                guard !data.isEmpty else {
                    Self.cleanupTempFiles(tempURLs)
                    return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("Audio data \(i + 1) is empty")) }
                }
                let url = Self.makeTempURL(extension: audioFormat.rawValue)
                try data.write(to: url)
                tempURLs.append(url)
                audioPaths.append(url.path)
            }
            for (i, data) in imagesData.enumerated() {
                guard let jpegData = Self.prepareImageForVision(data, maxDimension: maxImageDimension) else {
                    Self.cleanupTempFiles(tempURLs)
                    return AsyncThrowingStream { $0.finish(throwing: LiteRTLMError.inferenceFailure("Failed to convert image \(i + 1) to JPEG")) }
                }
                let url = Self.makeTempURL(extension: "jpg")
                try jpegData.write(to: url)
                tempURLs.append(url)
                imagePaths.append(url.path)
            }
        } catch {
            Self.cleanupTempFiles(tempURLs)
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let messageJSON = Self.buildMultimodalMessageJSON(
            audioPaths: audioPaths, imagePaths: imagePaths, text: prompt
        )

        return AsyncThrowingStream { continuation in
            self.inferenceQueue.async { [self] in
                let urlsToCleanup = tempURLs
                defer { Self.cleanupTempFiles(urlsToCleanup) }

                conversationLock.lock()
                guard let conversation = self.multimodalConversation else {
                    conversationLock.unlock()
                    continuation.finish(throwing: LiteRTLMError.inferenceFailure(
                        "No persistent conversation open — call openConversation() first"
                    ))
                    return
                }
                nextConversationStreamID &+= 1
                let streamID = nextConversationStreamID
                activeConversationStreamID = streamID
                activeConversationCancelUptimeNs = nil
                conversationLock.unlock()
                Self.log.info("Conversation stream \(streamID, privacy: .public) started")

                let streamDone = DispatchSemaphore(value: 0)
                let state = StreamCallbackState(
                    continuation: continuation,
                    doneSemaphore: streamDone,
                    onFinish: { [self] in
                        let finalNs = Self.monotonicNowNs()
                        var cancelToFinalMs: UInt64?
                        var shouldLog = false
                        conversationLock.lock()
                        if activeConversationStreamID == streamID {
                            if let cancelNs = activeConversationCancelUptimeNs {
                                cancelToFinalMs = (finalNs - cancelNs) / 1_000_000
                            }
                            activeConversationStreamID = nil
                            activeConversationCancelUptimeNs = nil
                            shouldLog = true
                        }
                        conversationLock.unlock()

                        guard shouldLog else { return }
                        let tsMs = finalNs / 1_000_000
                        if let cancelToFinalMs {
                            Self.log.info("Conversation stream \(streamID, privacy: .public) final callback at t=\(tsMs, privacy: .public)ms cancel_to_final_ms=\(cancelToFinalMs, privacy: .public)")
                        } else {
                            Self.log.info("Conversation stream \(streamID, privacy: .public) final callback at t=\(tsMs, privacy: .public)ms")
                        }
                    }
                )
                let statePtr = Unmanaged.passRetained(state).toOpaque()

                var utf8Bytes = Array(messageJSON.utf8)
                utf8Bytes.append(0)

                let result = utf8Bytes.withUnsafeBufferPointer { buf -> Int32 in
                    litert_lm_conversation_send_message_stream(
                        conversation,
                        buf.baseAddress!,
                        nil,
                        { callbackData, chunk, isFinal, errorMsg in
                            guard let cbData = callbackData else { return }
                            let st = Unmanaged<StreamCallbackState>.fromOpaque(cbData)
                                .takeUnretainedValue()

                            let errorMessage: String? = {
                                guard let errorMsg else { return nil }
                                let msg = String(cString: errorMsg)
                                return msg.isEmpty ? nil : msg
                            }()

                            if let chunk, errorMessage == nil {
                                let raw = String(cString: chunk)
                                let text = LiteRTLMEngine.extractTextFromConversationResponse(raw)
                                if !text.isEmpty { st.continuation.yield(text) }
                            }

                            if isFinal || errorMessage != nil {
                                st.onFinish?()
                                if let error = errorMessage {
                                    st.continuation.finish(throwing: LiteRTLMError.inferenceFailure(error))
                                } else {
                                    st.continuation.finish()
                                }
                                let semaphore = st.doneSemaphore
                                Unmanaged<StreamCallbackState>.fromOpaque(cbData).release()
                                semaphore.signal()
                            }
                        },
                        statePtr
                    )
                }

                if result != 0 {
                    conversationLock.lock()
                    if activeConversationStreamID == streamID {
                        activeConversationStreamID = nil
                        activeConversationCancelUptimeNs = nil
                    }
                    conversationLock.unlock()
                    Unmanaged<StreamCallbackState>.fromOpaque(statePtr).release()
                    continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to start conversation stream"))
                    return
                }

                streamDone.wait()
            }
        }
    }

    /// Close the persistent multimodal conversation, freeing KV cache memory.
    public func closeConversation() {
        let nowNs = Self.monotonicNowNs()
        conversationLock.lock()
        if let conversation = multimodalConversation {
            if activeConversationStreamID != nil {
                activeConversationCancelUptimeNs = nowNs
            }
            litert_lm_conversation_cancel_process(conversation)
        }
        conversationLock.unlock()

        inferenceQueue.async { [self] in
            let triplet = detachConversationTriplet()
            guard triplet.conversation != nil || triplet.config != nil || triplet.sessionConfig != nil else {
                return
            }
            if let c = triplet.conversation {
                litert_lm_conversation_delete(c)
            }
            if let c = triplet.config {
                litert_lm_conversation_config_delete(c)
            }
            if let c = triplet.sessionConfig {
                litert_lm_session_config_delete(c)
            }
            Self.log.info("Persistent multimodal conversation closed")
        }
    }

    /// Stream text using the persistent session.
    ///
    /// `input` should be ONLY the new turn content — the session's KV cache
    /// already holds all previous context.
    ///
    /// - Parameter input: New input text for this turn.
    /// - Returns: An `AsyncThrowingStream` yielding text chunks.
    public func sessionGenerateStreaming(input: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.inferenceQueue.async { [self] in
                guard let session = self.chatSession else {
                    continuation.finish(throwing: LiteRTLMError.inferenceFailure("No persistent session open — call openSession() first"))
                    return
                }

                let streamDone = DispatchSemaphore(value: 0)
                let state = StreamCallbackState(continuation: continuation, doneSemaphore: streamDone)
                let statePtr = Unmanaged.passRetained(state).toOpaque()

                // Copy prompt to heap — C API is non-blocking, callback may fire
                // after withCString's stack buffer is freed.
                var utf8Bytes = Array(input.utf8)
                utf8Bytes.append(0) // null-terminate

                let result = utf8Bytes.withUnsafeBufferPointer { buf -> Int32 in
                    var inputData = InputData(
                        type: kInputText,
                        data: UnsafeRawPointer(buf.baseAddress!),
                        size: utf8Bytes.count - 1 // exclude null terminator
                    )
                    return litert_lm_session_generate_content_stream(
                        session, &inputData, 1,
                        { callbackData, chunk, isFinal, errorMsg in
                            guard let cbData = callbackData else { return }
                            let st = Unmanaged<StreamCallbackState>.fromOpaque(cbData)
                                .takeUnretainedValue()

                            let errorMessage: String? = {
                                guard let errorMsg else { return nil }
                                let msg = String(cString: errorMsg)
                                return msg.isEmpty ? nil : msg
                            }()

                            if let chunk, errorMessage == nil {
                                let text = String(cString: chunk)
                                if !text.isEmpty { st.continuation.yield(text) }
                            }

                            if isFinal || errorMessage != nil {
                                if let error = errorMessage {
                                    st.continuation.finish(throwing: LiteRTLMError.inferenceFailure(error))
                                } else {
                                    st.continuation.finish()
                                }
                                let semaphore = st.doneSemaphore
                                Unmanaged<StreamCallbackState>.fromOpaque(cbData).release()
                                semaphore.signal()
                            }
                        },
                        statePtr
                    )
                }

                if result != 0 {
                    Unmanaged<StreamCallbackState>.fromOpaque(statePtr).release()
                    continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to start stream"))
                    return
                }

                streamDone.wait()
                self.logSessionBenchmark(session)
            }
        }
    }

    // MARK: - Private: Session-based Inference

    private func runSessionInference(
        prompt: String,
        temperature: Float,
        maxTokens: Int32
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            self.inferenceQueue.async { [self] in
                do {
                    guard let eng = self.engine else { throw LiteRTLMError.modelNotLoaded }

                    let (session, sessionConfig) = try self.createSession(
                        engine: eng, temperature: temperature, maxTokens: maxTokens
                    )
                    defer {
                        litert_lm_session_delete(session)
                        litert_lm_session_config_delete(sessionConfig)
                    }

                    let output = prompt.withCString { textPtr -> String? in
                        var input = InputData(
                            type: kInputText,
                            data: UnsafeRawPointer(textPtr),
                            size: strlen(textPtr)
                        )
                        guard let responses = litert_lm_session_generate_content(session, &input, 1) else {
                            return nil
                        }
                        defer { litert_lm_responses_delete(responses) }
                        return self.extractResponseText(responses)
                    }

                    guard let result = output else {
                        throw LiteRTLMError.inferenceFailure("generate_content returned no output")
                    }

                    self.logSessionBenchmark(session)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSessionInferenceStreaming(
        prompt: String,
        temperature: Float,
        maxTokens: Int32
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.inferenceQueue.async { [self] in
                do {
                    try self.ensureReady()
                    guard let eng = self.engine else {
                        continuation.finish(throwing: LiteRTLMError.modelNotLoaded)
                        return
                    }

                    let (session, sessionConfig) = try self.createSession(
                        engine: eng, temperature: temperature, maxTokens: maxTokens
                    )

                    let streamDone = DispatchSemaphore(value: 0)
                    let state = StreamCallbackState(continuation: continuation, doneSemaphore: streamDone)
                    let statePtr = Unmanaged.passRetained(state).toOpaque()

                    // Copy prompt to heap — C API is non-blocking, callback may fire
                    // after withCString's stack buffer is freed.
                    var utf8Bytes = Array(prompt.utf8)
                    utf8Bytes.append(0)

                    let result = utf8Bytes.withUnsafeBufferPointer { buf -> Int32 in
                        var input = InputData(
                            type: kInputText,
                            data: UnsafeRawPointer(buf.baseAddress!),
                            size: utf8Bytes.count - 1
                        )
                        return litert_lm_session_generate_content_stream(
                            session, &input, 1,
                            { callbackData, chunk, isFinal, errorMsg in
                                guard let cbData = callbackData else { return }
                                let st = Unmanaged<StreamCallbackState>.fromOpaque(cbData)
                                    .takeUnretainedValue()

                                let errorMessage: String? = {
                                    guard let errorMsg else { return nil }
                                    let msg = String(cString: errorMsg)
                                    return msg.isEmpty ? nil : msg
                                }()

                                if let chunk, errorMessage == nil {
                                    let text = String(cString: chunk)
                                    if !text.isEmpty { st.continuation.yield(text) }
                                }

                                if isFinal || errorMessage != nil {
                                    if let error = errorMessage {
                                        st.continuation.finish(throwing: LiteRTLMError.inferenceFailure(error))
                                    } else {
                                        st.continuation.finish()
                                    }
                                    let semaphore = st.doneSemaphore
                                    Unmanaged<StreamCallbackState>.fromOpaque(cbData).release()
                                    semaphore.signal()
                                }
                            },
                            statePtr
                        )
                    }

                    if result != 0 {
                        Unmanaged<StreamCallbackState>.fromOpaque(statePtr).release()
                        litert_lm_session_delete(session)
                        litert_lm_session_config_delete(sessionConfig)
                        continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to start stream"))
                        return
                    }

                    streamDone.wait()
                    self.logSessionBenchmark(session)
                    litert_lm_session_delete(session)
                    litert_lm_session_config_delete(sessionConfig)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func ensureReady() throws {
        guard status == .ready else { throw LiteRTLMError.modelNotLoaded }
    }

    private func createSession(
        engine eng: OpaquePointer,
        temperature: Float,
        maxTokens: Int32
    ) throws -> (session: OpaquePointer, config: OpaquePointer) {
        guard let sessionConfig = litert_lm_session_config_create() else {
            throw LiteRTLMError.inferenceFailure("Failed to create session config")
        }

        litert_lm_session_config_set_max_output_tokens(sessionConfig, maxTokens)

        // Use TopK sampling for GPU (Metal sampler supports it natively).
        // CPU uses TopP. Gallery app uses top_k=40 for GPU.
        let isGpu = backend.contains("gpu")
        var samplerParams = LiteRtLmSamplerParams(
            type: isGpu ? kTopK : kTopP,
            top_k: 40,
            top_p: 0.95,
            temperature: temperature,
            seed: 0
        )
        litert_lm_session_config_set_sampler_params(sessionConfig, &samplerParams)

        // Let the runtime auto-select the sampler backend (Metal on Apple).
        // Don't force it - the sampler factory handles fallback internally.

        guard let session = litert_lm_engine_create_session(eng, sessionConfig) else {
            litert_lm_session_config_delete(sessionConfig)
            throw LiteRTLMError.inferenceFailure("Failed to create session")
        }

        return (session, sessionConfig)
    }

    private func extractResponseText(_ responses: OpaquePointer) -> String? {
        let numCandidates = litert_lm_responses_get_num_candidates(responses)
        guard numCandidates > 0,
              let resultPtr = litert_lm_responses_get_response_text_at(responses, 0) else {
            return nil
        }
        return String(cString: resultPtr)
    }

    private func logSessionBenchmark(_ session: OpaquePointer) {
        guard let info = litert_lm_session_get_benchmark_info(session) else { return }
        defer { litert_lm_benchmark_info_delete(info) }

        let numPrefill = litert_lm_benchmark_info_get_num_prefill_turns(info)
        let numDecode = litert_lm_benchmark_info_get_num_decode_turns(info)

        // Compact single-line format: prefill and decode stats
        // TTFT is intentionally omitted — the C benchmark API reports 0.00
        // for streaming mode. Accurate TTFT is measured by LiteRTBackend.
        var parts: [String] = []
        var prefillTokenCounts: [Int] = []
        var decodeTokenCounts: [Int] = []
        for i in 0..<numPrefill {
            let tps = litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(info, Int32(i))
            let count = litert_lm_benchmark_info_get_prefill_token_count_at(info, Int32(i))
            prefillTokenCounts.append(Int(count))
            parts.append("prefill=\(count)tok@\(String(format: "%.1f", tps))tps")
        }
        for i in 0..<numDecode {
            let tps = litert_lm_benchmark_info_get_decode_tokens_per_sec_at(info, Int32(i))
            let count = litert_lm_benchmark_info_get_decode_token_count_at(info, Int32(i))
            decodeTokenCounts.append(Int(count))
            parts.append("decode=\(count)tok@\(String(format: "%.1f", tps))tps")
        }
        lastSessionBenchmarkSnapshot = SessionBenchmarkSnapshot(
            prefillTokenCounts: prefillTokenCounts,
            decodeTokenCounts: decodeTokenCounts
        )
        if !parts.isEmpty {
            Self.log.info("[Engine] \(parts.joined(separator: " "))")
        }
    }

    // MARK: - Private: Conversation-based Inference (Vision / Audio / Multimodal)

    /// Shared helper for all Conversation API calls (vision, audio, multimodal).
    /// Handles session/conversation lifecycle and temp file cleanup.
    private func runConversationInference(
        messageJSON: String,
        tempURLs: [URL],
        temperature: Float,
        maxTokens: Int
    ) async throws -> String {
        let urlsToCleanup = tempURLs
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            self.inferenceQueue.async { [self, urlsToCleanup] in
                defer {
                    for url in urlsToCleanup {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                do {
                    guard let eng = self.engine else { throw LiteRTLMError.modelNotLoaded }

                    guard let sessionConfig = litert_lm_session_config_create() else {
                        throw LiteRTLMError.inferenceFailure("Failed to create session config")
                    }
                    litert_lm_session_config_set_max_output_tokens(sessionConfig, Int32(maxTokens))
                    var samplerParams = LiteRtLmSamplerParams(
                        type: kTopP, top_k: 40, top_p: 0.95,
                        temperature: temperature, seed: 0
                    )
                    litert_lm_session_config_set_sampler_params(sessionConfig, &samplerParams)

                    guard let convConfig = litert_lm_conversation_config_create(
                        eng, sessionConfig, nil, nil, nil, false
                    ) else {
                        litert_lm_session_config_delete(sessionConfig)
                        throw LiteRTLMError.inferenceFailure("Failed to create conversation config")
                    }

                    guard let conversation = litert_lm_conversation_create(eng, convConfig) else {
                        litert_lm_conversation_config_delete(convConfig)
                        litert_lm_session_config_delete(sessionConfig)
                        throw LiteRTLMError.inferenceFailure("Failed to create conversation")
                    }
                    defer {
                        litert_lm_conversation_delete(conversation)
                        litert_lm_conversation_config_delete(convConfig)
                        litert_lm_session_config_delete(sessionConfig)
                    }

                    guard let response = messageJSON.withCString({ msgPtr in
                        litert_lm_conversation_send_message(conversation, msgPtr, nil)
                    }) else {
                        throw LiteRTLMError.inferenceFailure("Conversation returned no response")
                    }
                    defer { litert_lm_json_response_delete(response) }

                    guard let responsePtr = litert_lm_json_response_get_string(response) else {
                        throw LiteRTLMError.inferenceFailure("Response string is NULL")
                    }

                    let result = Self.extractTextFromConversationResponse(String(cString: responsePtr))
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Streaming variant: creates a one-shot conversation, streams via callback.
    private func runConversationInferenceStreaming(
        messageJSON: String,
        tempURLs: [URL],
        temperature: Float,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.inferenceQueue.async { [self] in
                let urlsToCleanup = tempURLs
                do {
                    guard let eng = self.engine else {
                        Self.cleanupTempFiles(urlsToCleanup)
                        continuation.finish(throwing: LiteRTLMError.modelNotLoaded)
                        return
                    }

                    guard let sessionConfig = litert_lm_session_config_create() else {
                        Self.cleanupTempFiles(urlsToCleanup)
                        continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to create session config"))
                        return
                    }
                    litert_lm_session_config_set_max_output_tokens(sessionConfig, Int32(maxTokens))
                    var samplerParams = LiteRtLmSamplerParams(
                        type: kTopP, top_k: 40, top_p: 0.95,
                        temperature: temperature, seed: 0
                    )
                    litert_lm_session_config_set_sampler_params(sessionConfig, &samplerParams)

                    guard let convConfig = litert_lm_conversation_config_create(
                        eng, sessionConfig, nil, nil, nil, false
                    ) else {
                        litert_lm_session_config_delete(sessionConfig)
                        Self.cleanupTempFiles(urlsToCleanup)
                        continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to create conversation config"))
                        return
                    }

                    guard let conversation = litert_lm_conversation_create(eng, convConfig) else {
                        litert_lm_conversation_config_delete(convConfig)
                        litert_lm_session_config_delete(sessionConfig)
                        Self.cleanupTempFiles(urlsToCleanup)
                        continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to create conversation"))
                        return
                    }

                    let streamDone = DispatchSemaphore(value: 0)
                    let state = StreamCallbackState(continuation: continuation, doneSemaphore: streamDone)
                    let statePtr = Unmanaged.passRetained(state).toOpaque()

                    // Copy message JSON to heap — C API is non-blocking
                    var utf8Bytes = Array(messageJSON.utf8)
                    utf8Bytes.append(0)

                    let result = utf8Bytes.withUnsafeBufferPointer { buf -> Int32 in
                        litert_lm_conversation_send_message_stream(
                            conversation,
                            buf.baseAddress!,
                            nil,
                            { callbackData, chunk, isFinal, errorMsg in
                                guard let cbData = callbackData else { return }
                                let st = Unmanaged<StreamCallbackState>.fromOpaque(cbData)
                                    .takeUnretainedValue()

                                let errorMessage: String? = {
                                    guard let errorMsg else { return nil }
                                    let msg = String(cString: errorMsg)
                                    return msg.isEmpty ? nil : msg
                                }()

                                if let chunk, errorMessage == nil {
                                    let raw = String(cString: chunk)
                                    // Conversation API streams JSON chunks, not plain text.
                                    // Extract the text content from the JSON envelope.
                                    let text = LiteRTLMEngine.extractTextFromConversationResponse(raw)
                                    if !text.isEmpty { st.continuation.yield(text) }
                                }

                                if isFinal || errorMessage != nil {
                                    if let error = errorMessage {
                                        st.continuation.finish(throwing: LiteRTLMError.inferenceFailure(error))
                                    } else {
                                        st.continuation.finish()
                                    }
                                    let semaphore = st.doneSemaphore
                                    Unmanaged<StreamCallbackState>.fromOpaque(cbData).release()
                                    semaphore.signal()
                                }
                            },
                            statePtr
                        )
                    }

                    if result != 0 {
                        Unmanaged<StreamCallbackState>.fromOpaque(statePtr).release()
                        litert_lm_conversation_delete(conversation)
                        litert_lm_conversation_config_delete(convConfig)
                        litert_lm_session_config_delete(sessionConfig)
                        Self.cleanupTempFiles(urlsToCleanup)
                        continuation.finish(throwing: LiteRTLMError.inferenceFailure("Failed to start conversation stream"))
                        return
                    }

                    streamDone.wait()
                    litert_lm_conversation_delete(conversation)
                    litert_lm_conversation_config_delete(convConfig)
                    litert_lm_session_config_delete(sessionConfig)
                    Self.cleanupTempFiles(urlsToCleanup)
                } catch {
                    Self.cleanupTempFiles(urlsToCleanup)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Media Helpers

    /// Create a uniquely-named temp file URL.
    nonisolated static func makeTempURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// Remove temp files, ignoring errors (best-effort cleanup).
    nonisolated static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Convert any image format to JPEG and resize for vision inference.
    nonisolated static func prepareImageForVision(_ data: Data, maxDimension: Int = 1024) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        let maxDim = maxDimension
        let scale: Double
        if width > height {
            scale = width > maxDim ? Double(maxDim) / Double(width) : 1.0
        } else {
            scale = height > maxDim ? Double(maxDim) / Double(height) : 1.0
        }

        let targetWidth = Int(Double(width) * scale)
        let targetHeight = Int(Double(height) * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resizedImage = context.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, resizedImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Build a Conversation API JSON message with any combination of audio, images, and text.
    nonisolated static func buildMultimodalMessageJSON(
        audioPaths: [String],
        imagePaths: [String],
        text: String
    ) -> String {
        var contentItems: [[String: Any]] = []
        for path in audioPaths {
            contentItems.append(["type": "audio", "path": path])
        }
        for path in imagePaths {
            contentItems.append(["type": "image", "path": path])
        }
        contentItems.append(["type": "text", "text": text])
        let message: [String: Any] = ["role": "user", "content": contentItems]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            // Fallback: text-only, properly escaped via JSONSerialization
            let fallback: [String: Any] = ["role": "user", "content": [["type": "text", "text": text]]]
            let fallbackData = (try? JSONSerialization.data(withJSONObject: fallback)) ?? Data()
            return String(data: fallbackData, encoding: .utf8) ?? "{}"
        }
        return jsonString
    }

    nonisolated static func buildConversationTextMessageJSON(role: String, text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let message: [String: Any] = [
            "role": role,
            "content": [["type": "text", "text": trimmed]]
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    nonisolated static func withOptionalCString<T>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }

    nonisolated static func extractTextFromConversationResponse(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let content = obj["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }

        if let candidates = obj["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }

        if let text = obj["text"] as? String { return text }

        return json.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Stream Callback State

private final class StreamCallbackState: @unchecked Sendable {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    let doneSemaphore: DispatchSemaphore
    let onFinish: (() -> Void)?

    init(continuation: AsyncThrowingStream<String, Error>.Continuation,
         doneSemaphore: DispatchSemaphore,
         onFinish: (() -> Void)? = nil) {
        self.continuation = continuation
        self.doneSemaphore = doneSemaphore
        self.onFinish = onFinish
    }
}

// MARK: - Errors

public enum LiteRTLMError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case engineCreationFailed(String)
    case inferenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            "LiteRT-LM model file not found"
        case .modelNotLoaded:
            "LiteRT-LM model is not loaded — call load() first"
        case .engineCreationFailed(let detail):
            "Failed to create LiteRT-LM engine: \(detail)"
        case .inferenceFailure(let detail):
            "LiteRT-LM inference failed: \(detail)"
        }
    }
}
