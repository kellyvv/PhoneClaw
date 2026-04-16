import Foundation
import AVFoundation

// MARK: - TTS Service
//
// sherpa-onnx + vits-zh-hf-keqing (中文音色, 116MB)
// 播放通过 LiveAudioIO 的 AVAudioPlayerNode, 与 VAD 共享同一个 AVAudioEngine,
// 使 iOS AEC 能消除 TTS 输出对麦克风的回声。
// 降级: 如果模型不可用, 用系统 AVSpeechSynthesizer。

@Observable
class TTSService {

    enum State: String {
        case idle
        case loading
        case ready
        case speaking
    }

    private(set) var state: State = .idle
    private(set) var isAvailable = false
    private(set) var backend: String = "none"

    /// Shared audio engine — set by LiveModeEngine before use.
    weak var audioIO: LiveAudioIO?

    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var sampleRate: Int = 16000
    private let defaultSid: Int = 200  // keqing speaker 200

    // System TTS fallback (no LiveAudioIO needed)
    @MainActor private var systemSpeechController: SystemSpeechController?

    @MainActor
    private func getSystemSpeechController() -> SystemSpeechController {
        if let c = systemSpeechController { return c }
        let c = SystemSpeechController()
        systemSpeechController = c
        return c
    }

    // MARK: - Initialize

    func initialize() async {
        state = .loading
        print("[TTS] Initializing sherpa-onnx + keqing...")

        if let modelDir = Bundle.main.path(forResource: "vits-zh-hf-keqing", ofType: nil) {
            let modelPath = modelDir + "/keqing.onnx"
            let lexiconPath = modelDir + "/lexicon.txt"
            let tokensPath = modelDir + "/tokens.txt"
            let dictDir = modelDir + "/dict"
            let ruleFsts = [
                modelDir + "/date.fst",
                modelDir + "/number.fst",
                modelDir + "/phone.fst",
                modelDir + "/new_heteronym.fst",
            ].joined(separator: ",")

            var config = sherpaOnnxOfflineTtsConfig(
                model: sherpaOnnxOfflineTtsModelConfig(
                    vits: sherpaOnnxOfflineTtsVitsModelConfig(
                        model: modelPath,
                        lexicon: lexiconPath,
                        tokens: tokensPath,
                        dataDir: "",
                        noiseScale: 0.667,
                        noiseScaleW: 0.8,
                        lengthScale: 1.0,
                        dictDir: dictDir
                    ),
                    numThreads: 2,
                    debug: 0
                ),
                ruleFsts: ruleFsts
            )

            let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
            tts = wrapper
            backend = "sherpa-onnx"
            isAvailable = true
            state = .ready
            print("[TTS] ✅ sherpa-onnx ready (keqing sid=200)")
            return
        }

        // Fallback to system TTS
        print("[TTS] ⚠️ keqing model not found in bundle, using system TTS")
        backend = "system"
        isAvailable = true
        state = .ready
    }

    // MARK: - Synthesize (CPU-heavy, NOT main thread)

    func synthesize(_ text: String) -> Data? {
        guard let tts else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let audio = tts.generate(text: text, sid: defaultSid, speed: 1.0)
        let synthMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let count = audio.n
        let sr = Int(audio.sampleRate)

        guard count > 0 else {
            print("[TTS] ❌ Empty audio output")
            return nil
        }

        let duration = Double(count) / Double(sr)
        print("[TTS] Synth: \(String(format: "%.0f", synthMs))ms, \(String(format: "%.1f", duration))s audio, \(sr)Hz")

        return samplesToWAV(samples: audio.samples, count: Int(count), sampleRate: sr)
    }

    func synthesizeChunk(_ text: String) -> AudioChunk? {
        guard let tts else { return nil }

        let audio = tts.generate(text: text, sid: defaultSid, speed: 1.0)
        let count = Int(audio.n)
        let sr = Int(audio.sampleRate)
        guard count > 0 else { return nil }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sr),
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        ),
        let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            channel[index] = audio.samples[index]
        }

        return AudioChunk(buffer: buffer)
    }

    // MARK: - Playback (through shared AVAudioEngine)

    /// Play WAV through the shared engine's AVAudioPlayerNode.
    /// AEC cancels this output from the mic input.
    func playWAV(_ data: Data) async {
        state = .speaking
        if let audioIO {
            await audioIO.playWAV(data)
        } else {
            print("[TTS] ⚠️ No audioIO, skipping playback")
        }
        state = .ready
    }

    /// System TTS fallback (uses its own audio path).
    func speakSystem(_ text: String) async {
        state = .speaking
        let controller = await getSystemSpeechController()
        await controller.speak(text)
        state = .ready
    }

    /// Stop current playback.
    func stop() async {
        audioIO?.stopPlayback()
        let controller = await getSystemSpeechController()
        await controller.stop()
        state = .ready
    }

    /// Legacy speak for greeting etc.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAvailable else { return }

        state = .speaking
        print("[TTS] 🔊 [\(backend)] \"\(trimmed.prefix(40))\"")

        if backend == "sherpa-onnx", let wavData = synthesize(trimmed) {
            await playWAV(wavData)
        } else {
            await speakSystem(trimmed)
        }
    }

    func cleanup() {
        audioIO?.stopPlayback()
        tts = nil
        isAvailable = false
        state = .idle
    }

    // MARK: - WAV encoding

    private func samplesToWAV(samples: [Float], count: Int, sampleRate: Int) -> Data {
        var data = Data()
        let bitsPerSample: Int16 = 16
        let numChannels: Int16 = 1
        let byteRate = Int32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * bitsPerSample / 8)
        let dataSize = Int32(count * Int(blockAlign))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        var chunkSize = Int32(36 + dataSize)
        data.append(Data(bytes: &chunkSize, count: 4))
        data.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        data.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: Int32 = 16
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: Int16 = 1 // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var channels = numChannels
        data.append(Data(bytes: &channels, count: 2))
        var sr = Int32(sampleRate)
        data.append(Data(bytes: &sr, count: 4))
        var br = byteRate
        data.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        data.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample
        data.append(Data(bytes: &bps, count: 2))

        // data subchunk
        data.append(contentsOf: "data".utf8)
        var ds = dataSize
        data.append(Data(bytes: &ds, count: 4))

        // Convert float samples to int16
        for i in 0..<count {
            let sample = max(-1.0, min(1.0, samples[i]))
            var int16Sample = Int16(sample * 32767)
            data.append(Data(bytes: &int16Sample, count: 2))
        }

        return data
    }
}

// MARK: - SystemSpeechController (@MainActor)
//
// Fallback for system AVSpeechSynthesizer. Separate from LiveAudioIO.

@MainActor
final class SystemSpeechController: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        await withCheckedContinuation { continuation in
            self.speechContinuation = continuation
            let utterance = AVSpeechUtterance(string: text)
            if text.range(of: "\\p{Han}", options: .regularExpression) != nil {
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        let c = speechContinuation
        speechContinuation = nil
        c?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("[TTS] ✅ System TTS done")
        let c = speechContinuation
        speechContinuation = nil
        c?.resume()
    }
}

// MARK: - AudioPlaybackQueue (actor)

actor AudioPlaybackQueue {

    private enum Item {
        case wav(Data)
        case systemSpeak(String)
    }

    private var pending: [Item] = []
    private var isRunning = false
    private var isFlushed = false
    private var generation: UInt64 = 0
    private weak var tts: TTSService?
    private var doneContinuation: CheckedContinuation<Void, Never>?

    init(tts: TTSService) { self.tts = tts }

    func enqueueWAV(_ data: Data) {
        guard !isFlushed else { return }
        pending.append(.wav(data))
        startDrainIfNeeded()
    }

    func enqueueSystemSpeak(_ text: String) {
        guard !isFlushed else { return }
        pending.append(.systemSpeak(text))
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        if !isRunning {
            isRunning = true
            let gen = generation
            Task { await drain(gen: gen) }
        }
    }

    private func drain(gen: UInt64) async {
        while let item = pending.first, !isFlushed, generation == gen {
            pending.removeFirst()
            guard let tts, !isFlushed, generation == gen else { break }
            switch item {
            case .wav(let data):
                await tts.playWAV(data)
            case .systemSpeak(let text):
                await tts.speakSystem(text)
            }
        }
        if generation == gen {
            isRunning = false
            let c = doneContinuation
            doneContinuation = nil
            c?.resume()
        }
    }

    func flush() async {
        isFlushed = true
        pending.removeAll()
        isRunning = false
        let c = doneContinuation
        doneContinuation = nil
        c?.resume()
        await tts?.stop()
    }

    func waitUntilDone() async {
        guard isRunning, !isFlushed else { return }
        await withCheckedContinuation { continuation in
            self.doneContinuation = continuation
        }
    }

    /// Atomic reset: clears pending, increments generation, AND stops current playback.
    /// Called from barge-in. Must be done inside the actor so drain() sees
    /// the generation change immediately when it resumes after playWAV returns.
    /// This prevents the race where drain picks up the next pending item
    /// between stopPlayback() and an externally-dispatched reset().
    func reset() {
        generation &+= 1
        isFlushed = false
        pending.removeAll()
        isRunning = false
        let c = doneContinuation
        doneContinuation = nil
        c?.resume()
        // Stop current playback within the actor — when drain resumes,
        // generation != gen → break. No next item can play.
        tts?.audioIO?.stopPlayback()
    }
}
