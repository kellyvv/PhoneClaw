import Foundation
import AVFoundation
#if canImport(PiperPlus)
import PiperPlus
#endif

// MARK: - TTS Service
//
// sherpa-onnx 多语言 TTS:
//   - 中文系统: vits-zh-hf-keqing (lexicon-based, ~136MB, sid=200, 单女声)
//   - 英文系统: vits-piper-en_US-libritts_r-medium (espeak-based, ~76MB, 904 speakers, 默认 sid=0)
// 切换发生在 initialize() 阶段, 根据 LanguageService 选择加载哪份配置。
// 加载之后 synthesize / playWAV / 播放队列 三套接口对调用方完全透明。
//
// 播放通过 LiveAudioIO 的 AVAudioPlayerNode, 与 VAD 共享同一个 AVAudioEngine,
// 使 iOS AEC 能消除 TTS 输出对麦克风的回声。
// 降级: 中/英模型不可用时可用系统 AVSpeechSynthesizer; 日语不允许系统 TTS fallback,
// 必须使用端上神经 TTS 后端 (Piper Plus / 修复后的 Supertonic 等)。

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

    var usesSharedAudioEngine: Bool {
        backend == "sherpa-onnx" || backend == "piper-plus"
    }

    var allowsSystemFallback: Bool {
        !LanguageService.shared.current.isJapanese
    }

    /// Shared audio engine — set by LiveModeEngine before use.
    weak var audioIO: LiveAudioIO?

    private var tts: SherpaOnnxOfflineTtsWrapper?
    #if canImport(PiperPlus)
    private var piperPlusJA: PiperPlusJATtsWrapper?
    #endif
    private var sampleRate: Int = 16000

    /// 当前激活的 TTS 模型对应的 speaker id。
    /// keqing 的训练数据按 speaker 切了多个 sid, 200 是默认女声;
    /// Piper libritts_r-medium 是 904 说话人模型, sid=0 是用户挑过的默认音色 (本地试听确认)。
    private var defaultSid: Int = 200

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
        #if targetEnvironment(simulator)
        if LanguageService.shared.current.isJapanese {
            print("[TTS] Simulator build: Japanese neural TTS unavailable (system TTS disabled)")
            backend = "none"
            isAvailable = false
            state = .idle
        } else {
            print("[TTS] Simulator build: using system TTS")
            backend = "system"
            isAvailable = true
            state = .ready
        }
        return
        #endif

        state = .loading

        // 按系统语言加载不同 TTS — 中文 keqing / 英文 Piper libritts_r-medium。
        // 日语不允许系统 TTS fallback; Supertonic-3 当前会被内置 ORT 的 ai.onnx.ml opset
        // 支持边界卡死, Piper Plus 接入前必须保持 unavailable。
        let initialized: Bool
        switch LanguageService.shared.current.resolved {
        case .zhHans: initialized = initializeKeqing()
        case .ja:     initialized = initializePiperPlusJA()
        default:      initialized = initializePiperEN()
        }

        if initialized {
            isAvailable = true
            state = .ready
            return
        }

        if !allowsSystemFallback {
            print("[TTS] ❌ Japanese neural TTS unavailable; system TTS fallback is disabled")
            backend = "none"
            isAvailable = false
            state = .idle
            return
        }

        // Fallback to system TTS for non-Japanese locales only.
        print("[TTS] ⚠️ TTS model not found, using system TTS")
        backend = "system"
        isAvailable = true
        state = .ready
    }

    /// 中文 keqing TTS 初始化。
    /// keqing 用 lexicon-based phonemization (中文 → 拼音 → 音素),
    /// 配套需要 lexicon.txt + tokens.txt + dict/ + 4 个 ruleFsts (date/number/phone/heteronym)。
    private func initializeKeqing() -> Bool {
        print("[TTS] Initializing sherpa-onnx + keqing (zh)...")

        let asset = LiveModelDefinition.tts
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
        } else {
            return false
        }

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

        // numThreads: 4 — iPhone 17 Pro Max 有 6 个 P-core, VITS 合成是 CPU 瓶颈,
        //   从 2 → 4 稳定提速 30-50%, 不占额外内存 (只是多出几个线程栈).
        // lengthScale: 0.9 — keqing 原生语速偏慢 (接近朗读味), 0.9 倍语速更接近
        //   日常口语, 同时输出音频更短 → 总合成时间也缩短.
        var config = sherpaOnnxOfflineTtsConfig(
            model: sherpaOnnxOfflineTtsModelConfig(
                vits: sherpaOnnxOfflineTtsVitsModelConfig(
                    model: modelPath,
                    lexicon: lexiconPath,
                    tokens: tokensPath,
                    dataDir: "",
                    noiseScale: 0.667,
                    noiseScaleW: 0.8,
                    lengthScale: 0.9,
                    dictDir: dictDir
                ),
                numThreads: 4,
                debug: 0
            ),
            ruleFsts: ruleFsts
        )

        tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        defaultSid = 200  // keqing speaker 200
        print("[TTS] ✅ sherpa-onnx ready (keqing zh, sid=200)")
        backend = "sherpa-onnx"
        return true
    }

    /// 英文 Piper libritts_r-medium TTS 初始化。
    /// Piper 用 espeak-ng-based phonemization (英文 → IPA 音素),
    /// 配套需要 espeak-ng-data/ 目录 (en_dict + 共享 phondata 等)。
    /// 不需要 lexicon / dict / ruleFsts — 这些是中文管线特有。
    /// tokens 必须传: sherpa-onnx 的 OfflineTtsVitsModelConfig.Validate() 要求非空。
    private func initializePiperEN() -> Bool {
        print("[TTS] Initializing sherpa-onnx + Piper libritts_r-medium (en)...")

        let asset = LiveModelDefinition.ttsEN
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
        } else {
            return false
        }

        let modelPath = modelDir + "/en_US-libritts_r-medium.onnx"
        let tokensPath = modelDir + "/tokens.txt"
        let dataDir = modelDir + "/espeak-ng-data"

        // Piper VITS 跟 keqing 用同一个 sherpa-onnx OfflineTts 管线, 但配置项不同:
        //   - lexicon = "" (Piper 不用 lexicon, espeak 直接出音素)
        //   - tokens = tokens.txt (sherpa 项目针对 Piper 模型生成的词表 — 必须传, 否则
        //     OfflineTtsVitsModelConfig.Validate 报 "Please provide --vits-tokens" 拒绝创建)
        //   - dataDir = espeak-ng-data 路径 (告诉 espeak 字典在哪)
        //   - dictDir = "" (中文 keqing 专用)
        //   - ruleFsts = "" (Piper 没有 number/date FST 规则)
        // lengthScale: 1.0 — libritts_r 原生语速即日常口语, 不需调整。
        var config = sherpaOnnxOfflineTtsConfig(
            model: sherpaOnnxOfflineTtsModelConfig(
                vits: sherpaOnnxOfflineTtsVitsModelConfig(
                    model: modelPath,
                    lexicon: "",
                    tokens: tokensPath,
                    dataDir: dataDir,
                    noiseScale: 0.667,
                    noiseScaleW: 0.8,
                    lengthScale: 1.0,
                    dictDir: ""
                ),
                numThreads: 4,
                debug: 0
            ),
            ruleFsts: ""
        )

        tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        // libritts_r-medium 是 904 speaker 多说话人模型, sid=0 是 Mac 本地试听确认的默认音色。
        // 改换音色: 修改这一行的数字 (0..903), 不需要重新下载模型。
        defaultSid = 0
        print("[TTS] ✅ sherpa-onnx ready (Piper libritts_r-medium en, sid=0)")
        backend = "sherpa-onnx"
        return true
    }

    /// 日语 Piper Plus TTS 初始化。
    /// Piper Plus 走 OpenJTalk 前端, 解决日语汉字读音/韵律/G2P。它是独立 runtime,
    /// 不复用 sherpa-onnx 的 VITS/Supertonic config。
    private func initializePiperPlusJA() -> Bool {
        #if canImport(PiperPlus)
        print("[TTS] Initializing Piper Plus + OpenJTalk (ja)...")

        let asset = LiveModelDefinition.ttsPiperPlusJA
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
        } else {
            print("[TTS] Piper Plus JA model not found")
            return false
        }

        guard let dictDir = LiveModelDefinition.openJTalkDictionaryDirectory?.path else {
            print("[TTS] OpenJTalk dictionary not found in Bundle or Documents/models")
            return false
        }

        let modelPath = modelDir + "/tsukuyomi-chan-6lang-fp16.onnx"
        let configPath = modelDir + "/config.json"
        let runtimeConfigPath = Self.piperPlusRuntimeConfigPath(for: configPath) ?? configPath
        guard let wrapper = PiperPlusJATtsWrapper(
            modelPath: modelPath,
            configPath: runtimeConfigPath,
            dictDir: dictDir
        ) else {
            return false
        }

        piperPlusJA = wrapper
        backend = "piper-plus"
        sampleRate = wrapper.sampleRate
        defaultSid = 0
        print("[TTS] ✅ Piper Plus ready (ja, OpenJTalk)")
        return true
        #else
        print("[TTS] Piper Plus runtime not linked")
        return false
        #endif
    }

    /// Piper Plus v1.12 runtime requires every `phoneme_id_map` key to be a
    /// single Unicode codepoint. The current tsukuyomi config still ships three
    /// legacy multi-codepoint keys, so rewrite them to the canonical PUA slots
    /// before handing the config to the C runtime.
    private static func piperPlusRuntimeConfigPath(for configPath: String) -> String? {
        let sourceURL = URL(fileURLWithPath: configPath)
        let fm = FileManager.default

        do {
            let data = try Data(contentsOf: sourceURL)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var phonemeIDMap = root["phoneme_id_map"] as? [String: Any] else {
                print("[TTS] Piper Plus config patch skipped: invalid config.json")
                return nil
            }

            let replacements = [
                "\u{0254}\u{026A}": "\u{E062}", // "ɔɪ"
                "\u{0153}\u{0303}": "\u{E063}", // "œ̃"
                "\u{0250}\u{0303}": "\u{E064}", // "ɐ̃"
            ]
            var patchedCount = 0
            for (legacyKey, puaKey) in replacements {
                guard let value = phonemeIDMap.removeValue(forKey: legacyKey) else { continue }
                phonemeIDMap[puaKey] = value
                patchedCount += 1
            }

            guard patchedCount > 0 else { return configPath }

            root["phoneme_id_map"] = phonemeIDMap
            root["pua_compat_version"] = 2

            guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let outputDirectory = caches.appendingPathComponent("piper-plus", isDirectory: true)
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let outputURL = outputDirectory.appendingPathComponent("tsukuyomi-runtime-config.json")
            let patchedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try patchedData.write(to: outputURL, options: .atomic)
            print("[TTS] Piper Plus config patched for PUA compatibility (\(patchedCount) keys)")
            return outputURL.path
        } catch {
            print("[TTS] Piper Plus config patch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 日语 Supertonic-3 TTS 初始化 (sherpa-onnx Supertonic 后端)。
    /// Supertonic 是 char/unicode-based 多语模型 (tts.json: n_langs=0, lang_emb_dim=0):
    /// 语言完全由输入文本字符 + unicode_indexer.bin 决定 — 喂日语文本即读日语, 无需 lang 参数,
    /// 也不依赖 espeak/OpenJTalk g2p。核心 7 文件: 4 个 int8 onnx
    /// (duration_predictor/text_encoder/vector_estimator/vocoder) + tts.json
    /// + unicode_indexer.bin + voice.bin (单一内置音色)。
    /// 跟 keqing/Piper 一样走 SherpaOnnxOfflineTtsWrapper → playWAV → 共享 AVAudioEngine → AEC,
    /// 这样日语回声能被消掉 (旧的系统 ja-JP TTS 走独立通路绕开 AEC, 会自打断)。
    private func initializeSupertonicJA() -> Bool {
        guard LiveModelDefinition.supertonicJAReady else { return false }
        #if targetEnvironment(simulator)
        // 模拟器无 Supertonic 的 sherpa C 符号 (sim stub 只覆盖 vits);
        // 且 initialize() 在 simulator 已 early-return 系统 TTS, 这里不会被调用。
        return false
        #else
        print("[TTS] Initializing sherpa-onnx + Supertonic-3 (ja)...")

        let asset = LiveModelDefinition.ttsJA
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
        } else {
            return false
        }

        // numThreads: 4 — Supertonic 的 flow-matching vocoder 是 CPU 瓶颈, 跟 keqing/Piper 一致开 4 线程。
        var config = sherpaOnnxOfflineTtsConfig(
            model: sherpaOnnxOfflineTtsModelConfig(
                numThreads: 4,
                debug: 0,
                supertonic: sherpaOnnxOfflineTtsSupertonicModelConfig(
                    durationPredictor: modelDir + "/duration_predictor.int8.onnx",
                    textEncoder: modelDir + "/text_encoder.int8.onnx",
                    vectorEstimator: modelDir + "/vector_estimator.int8.onnx",
                    vocoder: modelDir + "/vocoder.int8.onnx",
                    ttsJson: modelDir + "/tts.json",
                    unicodeIndexer: modelDir + "/unicode_indexer.bin",
                    voiceStyle: modelDir + "/voice.bin"
                )
            )
        )

        tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        // Supertonic-3 单一内置音色 (voice.bin), sid 固定 0。
        defaultSid = 0
        print("[TTS] ✅ sherpa-onnx ready (Supertonic-3 ja, unicode-based)")
        return true
        #endif
    }

    // MARK: - Synthesize (CPU-heavy, NOT main thread)

    func synthesize(_ text: String) -> Data? {
        #if canImport(PiperPlus)
        if backend == "piper-plus" {
            guard let wav = piperPlusJA?.synthesize(text) else { return nil }
            return wav
        }
        #endif

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

    /// System TTS fallback (uses its own audio path). Disabled for Japanese LIVE.
    func speakSystem(_ text: String) async {
        guard allowsSystemFallback else {
            print("[TTS] ❌ System TTS fallback disabled for Japanese")
            return
        }
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

        if usesSharedAudioEngine, let wavData = synthesize(trimmed) {
            await playWAV(wavData)
        } else if allowsSystemFallback {
            await speakSystem(trimmed)
        } else {
            print("[TTS] ❌ No non-system TTS available for Japanese")
        }
    }

    func cleanup() {
        audioIO?.stopPlayback()
        tts = nil
        #if canImport(PiperPlus)
        piperPlusJA = nil
        #endif
        isAvailable = false
        state = .idle
    }

    // MARK: - WAV encoding

    private func samplesToWAV(samples: [Float], count: Int, sampleRate: Int) -> Data {
        Self.encodeWAV(samples: Array(samples.prefix(count)), sampleRate: sampleRate)
    }

    fileprivate static func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let bitsPerSample: Int16 = 16
        let numChannels: Int16 = 1
        let byteRate = Int32(sampleRate * Int(numChannels) * Int(bitsPerSample / 8))
        let blockAlign = Int16(numChannels * bitsPerSample / 8)
        let dataSize = Int32(samples.count * Int(blockAlign))

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
        for sampleValue in samples {
            let sample = max(-1.0, min(1.0, sampleValue))
            var int16Sample = Int16(sample * 32767)
            data.append(Data(bytes: &int16Sample, count: 2))
        }

        return data
    }
}

#if canImport(PiperPlus)
// MARK: - Piper Plus JA Wrapper

private final class PiperPlusJATtsWrapper {
    private var engine: OpaquePointer?
    private let languageId: Int32
    let sampleRate: Int

    init?(modelPath: String, configPath: String, dictDir: String) {
        var createdEngine: OpaquePointer?
        let status: PiperPlusStatus = modelPath.withCString { modelC in
            configPath.withCString { configC in
                dictDir.withCString { dictC in
                    "cpu".withCString { providerC in
                        var config = PiperPlusConfig()
                        config.model_path = modelC
                        config.config_path = configC
                        config.provider = providerC
                        config.num_threads = 4
                        config.dict_dir = dictC
                        return piper_plus_create(&config, &createdEngine)
                    }
                }
            }
        }

        guard status == PIPER_PLUS_OK, let createdEngine else {
            if let error = piper_plus_get_last_error() {
                print("[TTS] ❌ Piper Plus create failed: \(String(cString: error))")
            } else {
                print("[TTS] ❌ Piper Plus create failed: \(status)")
            }
            return nil
        }

        self.engine = createdEngine
        self.sampleRate = Int(piper_plus_sample_rate(createdEngine))

        let resolvedLanguage = "ja".withCString { langC in
            piper_plus_language_id(createdEngine, langC)
        }
        self.languageId = resolvedLanguage >= 0 ? resolvedLanguage : 0
    }

    deinit {
        if let engine {
            piper_plus_free(engine)
        }
    }

    func synthesize(_ text: String) -> Data? {
        guard let engine else { return nil }

        var options = piper_plus_default_options()
        options.speaker_id = 0
        options.language_id = languageId
        options.length_scale = 1.0
        options.sentence_silence_sec = 0.2

        var samplesPointer: UnsafeMutablePointer<Float>?
        var sampleCount: Int32 = 0
        var outputSampleRate: Int32 = 0

        let t0 = CFAbsoluteTimeGetCurrent()
        let status: PiperPlusStatus = text.withCString { textC in
            piper_plus_synthesize(
                engine,
                textC,
                &options,
                &samplesPointer,
                &sampleCount,
                &outputSampleRate
            )
        }
        let synthMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        guard status == PIPER_PLUS_OK,
              let samplesPointer,
              sampleCount > 0,
              outputSampleRate > 0 else {
            if status == PIPER_PLUS_OK {
                let samplesState = samplesPointer == nil ? "nil" : "non-nil"
                print("[TTS] ❌ Piper Plus synth returned empty audio: samples=\(samplesState), count=\(sampleCount), sampleRate=\(outputSampleRate)")
            } else if let error = piper_plus_get_last_error() {
                print("[TTS] ❌ Piper Plus synth failed: \(String(cString: error))")
            } else {
                print("[TTS] ❌ Piper Plus synth failed: \(status)")
            }
            if let samplesPointer {
                piper_plus_free_audio(samplesPointer)
            }
            return nil
        }

        let samples = Array(UnsafeBufferPointer(start: samplesPointer, count: Int(sampleCount)))
        piper_plus_free_audio(samplesPointer)

        let duration = Double(sampleCount) / Double(outputSampleRate)
        print("[TTS] Piper Plus synth: \(String(format: "%.0f", synthMs))ms, \(String(format: "%.1f", duration))s audio, \(outputSampleRate)Hz")
        return TTSService.encodeWAV(samples: samples, sampleRate: Int(outputSampleRate))
    }
}
#endif

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
            // 只有日语强制 ja-JP — 日语整段汉字会被 \p{Han} 误判成中文。
            // 中/英环境保留原来的字形判断, 以支持中英混排朗读 (不要强制按 app 语言)。
            if LanguageService.shared.current.isJapanese {
                utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            } else if text.range(of: "\\p{Han}", options: .regularExpression) != nil {
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
