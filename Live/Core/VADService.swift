import Foundation
import AVFoundation
import FluidAudio

// MARK: - VAD Service
//
// 封装 FluidAudio 的 Silero VAD, 实时检测语音活动。
// 通过 LiveAudioIO.audioInputHandler 接收 16kHz 采样 (不自建 engine, 不装 tap)。
// startListening: 设置 handler → VAD 开始处理
// stopListening:  清除 handler → VAD 停止处理 (engine 和 tap 不受影响)
//
// Chunk processing is strictly serialized via AsyncStream to guarantee:
// 1. streamState is never read/written concurrently
// 2. Callback ordering (prob → event) is deterministic per-chunk
// 3. Probability values arrive in audio-temporal order

// MARK: - LiveVADConfig

/// Parameterized VAD configuration for Live Mode.
/// Only exposes parameters that are actually passed to VadSegmentationConfig
/// in the streaming path. Note:
/// - `threshold`: set at VadManager init time, not changeable per-chunk.
/// - `minSpeechDuration`: only used by offline segmentation, not streaming.
struct LiveVADConfig {
    // Updated from 0.75 → 0.2 to match VAD_STOP_SECS (vad_analyzer.py).
    // This change is valid only after VADAnalyzerProtocol/VADController boundary
    // is established (Stage C). stopSecs is now owned at the protocol level.
    var minSilenceDuration: TimeInterval = 0.2
    var speechPadding: TimeInterval = 0.1
}

@Observable
class VADService {

    enum State: String, Equatable {
        case idle
        case listening
        case speaking
    }

    private(set) var state: State = .idle
    private(set) var isAvailable = false

    // MARK: - Callbacks

    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (([Float]) -> Void)?

    /// Per-chunk probability callback. Fires for every processed chunk.
    /// Used by LiveModeEngine for barge-in confirmation.
    var onProbabilityUpdate: ((Float) -> Void)?

    /// Delivers every speech chunk in order, including the trigger chunk.
    /// Used by LiveModeEngine to feed streaming ASR while deciding whether
    /// a new user turn has enough semantic content to interrupt the bot.
    var onSpeechChunk: (([Float]) -> Void)?

    // MARK: - Configuration

    var liveConfig = LiveVADConfig()

    // MARK: - Dependencies

    private var vadManager: VadManager?
    private var streamState: VadStreamState?
    private weak var audioIO: LiveAudioIO?
    private var recordedSamples: [Float] = []
    private var pendingSamples: [Float] = []

    private let sampleRate = VadManager.sampleRate
    private let chunkSize = VadManager.chunkSize

    /// 串行队列保护 pendingSamples, 避免 audio tap 并发竞争
    private let processingQueue = DispatchQueue(label: "com.phoneclaw.vad.processing")

    /// Serial chunk pipeline — replaces per-chunk Task spawning
    private var chunkContinuation: AsyncStream<[Float]>.Continuation?
    private var chunkProcessingTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func initialize() async {
        do {
            let manager = try await VadManager()
            vadManager = manager
            streamState = await manager.makeStreamState()
            isAvailable = await manager.isAvailable
            print("[VAD] Initialized, available: \(isAvailable)")
        } catch {
            print("[VAD] ❌ Init failed: \(error)")
            isAvailable = false
        }
    }

    /// Start listening by setting the audioInputHandler on the shared engine.
    /// The engine's permanent tap delivers 16kHz samples; we just start processing them.
    func startListening(audioIO: LiveAudioIO) async {
        guard isAvailable, let vadManager else {
            print("[VAD] Not available")
            return
        }

        self.audioIO = audioIO
        streamState = await vadManager.makeStreamState()
        recordedSamples = []
        processingQueue.sync { pendingSamples = [] }
        state = .listening

        // Create serial chunk processing pipeline
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        chunkContinuation = continuation
        chunkProcessingTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { break }
                await self.processChunk(chunk)
            }
        }

        // Set the handler — audio starts flowing to VAD immediately
        audioIO.audioInputHandler = { [weak self] samples in
            guard let self else { return }
            self.handleAudioInput(samples)
        }
        print("[VAD] Listening...")
    }

    /// Stop listening by clearing the handler. Engine and tap keep running.
    func stopListening() {
        audioIO?.audioInputHandler = nil
        chunkContinuation?.finish()
        chunkProcessingTask?.cancel()
        chunkContinuation = nil
        chunkProcessingTask = nil
        state = .idle
        print("[VAD] Stopped")
    }

    // MARK: - Test Seam

    /// Inject dependencies for testing. Allows calling processChunk directly
    /// with both vadManager and streamState initialized.
    internal func injectForTesting(vadManager: VadManager, initialStreamState: VadStreamState) {
        self.vadManager = vadManager
        self.streamState = initialStreamState
    }

    // MARK: - Audio Input (called from LiveAudioIO tap, on audio thread)

    private func handleAudioInput(_ samples: [Float]) {
        // Extract complete chunks on serial queue
        let chunks: [[Float]] = processingQueue.sync {
            pendingSamples.append(contentsOf: samples)
            var result: [[Float]] = []
            while pendingSamples.count >= chunkSize {
                result.append(Array(pendingSamples.prefix(chunkSize)))
                pendingSamples.removeFirst(chunkSize)
            }
            return result
        }

        // Enqueue to serial pipeline, don't spawn separate Tasks
        for chunk in chunks {
            chunkContinuation?.yield(chunk)
        }
    }

    // MARK: - VAD Processing

    /// CALLBACK ORDER CONTRACT:
    /// For each chunk, onProbabilityUpdate fires BEFORE onSpeechStart/onSpeechEnd.
    /// If the chunk belongs to speech, onSpeechChunk fires AFTER the speech event.
    /// This ordering is required by the barge-in logic in LiveModeEngine,
    /// which depends on turn-start setup happening before the trigger chunk
    /// is fed into streaming ASR. DO NOT reorder these callbacks without
    /// updating the corresponding tests.
    /// See testCallbackOrdering in VADServiceTests.
    internal func processChunk(_ chunk: [Float]) async {
        guard let vadManager, let currentState = streamState else { return }

        do {
            let segConfig = VadSegmentationConfig(
                minSilenceDuration: liveConfig.minSilenceDuration,
                speechPadding: liveConfig.speechPadding
            )
            let result = try await vadManager.processStreamingChunk(
                chunk, state: currentState, config: segConfig
            )
            handleStreamingResult(result, chunk: chunk)
        } catch {
            print("[VAD] ❌ Process error: \(error)")
        }
    }

    /// Shared result handler used by runtime processing and unit tests.
    /// Keeps callback ordering and sample accumulation semantics in one place.
    internal func handleStreamingResult(_ result: VadStreamResult, chunk: [Float]) {
        streamState = result.state

        // ① Probability FIRST — barge-in contract requires this ordering
        onProbabilityUpdate?(result.probability)

        // ② Event SECOND
        if let event = result.event {
            switch event.kind {
            case .speechStart:
                state = .speaking
                recordedSamples = []
                recordedSamples.append(contentsOf: chunk)
                print("[VAD] 🎤 Speech start")
                onSpeechStart?()
                onSpeechChunk?(chunk)

            case .speechEnd:
                state = .listening
                let recorded = recordedSamples
                recordedSamples = []
                let duration = Double(recorded.count) / Double(sampleRate)
                print("[VAD] 🔇 Speech end (\(String(format: "%.1f", duration))s)")
                onSpeechEnd?(recorded)
            }
        } else if state == .speaking {
            recordedSamples.append(contentsOf: chunk)
            onSpeechChunk?(chunk)
        }
    }
}
