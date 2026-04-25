import Foundation
import WhisperKit

// MARK: - ASR Service
//
// Experimental WhisperKit base path for multilingual on-device ASR.
// Keep sherpa-onnx as the fallback backend while validating WhisperKit on iPhone.

class ASRService {
    /// Backwards-compat 别名 — 内部代码继续用 `Backend` 简短名,
    /// 真正的 enum 定义在 `ASRBackend.swift` (独立出来让 CLI harness 可以引用)。
    typealias Backend = ASRBackend

    struct StreamingResult {
        let text: String
        let unitCount: Int

        static let empty = StreamingResult(text: "", unitCount: 0)
    }

    private let backend: Backend
    private var initializationTask: Task<Void, Never>?
    private var whisperKit: WhisperKit?
    private var fullTurnRecognizer: SherpaOnnxRecognizer?
    private var streamingRecognizer: SherpaOnnxRecognizer?
    private(set) var isAvailable = false

    /// 曾经查找过但失败. 避免每次 transcribe 反复尝试 init 浪费时间.
    /// 一旦 ensureInitialized 检测到模型文件存在, 会清零重试.
    private var initAttempted = false

    init(backend: Backend = Backend.current) {
        self.backend = backend
    }

    func initialize() async {
        if isAvailable { return }
        if let initializationTask {
            await initializationTask.value
            return
        }

        initAttempted = true
        let task = Task { [weak self] in
            guard let self else { return }
            switch backend {
            case .whisperKitBase:
                await initializeWhisperKit()
            case .sherpaOnnx:
                initializeSherpaOnnx()
            }
        }

        initializationTask = task
        await task.value
        initializationTask = nil
    }

    private func initializeWhisperKit() async {
        guard whisperKit == nil else {
            isAvailable = true
            return
        }

        do {
            // 模型路径解析: bundle 优先 (向后兼容打包方式), 然后 Documents/models/openai_whisper-base/
            // (用户在配置页通过 LIVE 语音模型按钮下载到的位置).
            // resolve 找不到 → 用户没下载, 不能 init, 让 transcribe 路径上的 UI 报错引导。
            guard let modelFolder = LiveModelDefinition.resolve(for: LiveModelDefinition.whisperBase) else {
                isAvailable = false
                let expected = LiveModelDefinition.downloadedDirectory(for: LiveModelDefinition.whisperBase).path
                print("[ASR] ❌ WhisperKit base model not found. Download via LIVE Voice Models in Configurations. Expected: \(expected)")
                return
            }
            let start = CFAbsoluteTimeGetCurrent()
            print("[ASR] Loading WhisperKit base from: \(modelFolder.path)")

            // 启动时显式校验模型是不是 multilingual. argmax repo 同时托管
            // openai_whisper-base (multilingual) 和 openai_whisper-base.en (English-only),
            // 配错 prefix 就会拿到只会输出英文的版本. 读 generation_config.json 的
            // is_multilingual 字段直接确认, 不靠路径名猜。
            logModelVariant(modelFolder: modelFolder)

            // download: true — argmax repo (Core ML 大文件, ~140MB) 已经由 LIVE 下载好了,
            // tokenizer 文件 (~3MB, JSON 文本) 不在 argmax repo 里, WhisperKit 会自动从
            // openai/whisper-base 拉. Core ML 文件已在本地, 不会重复下载。
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: false,
                load: true,
                download: true
            )
            whisperKit = try await WhisperKit(config)
            isAvailable = true
            let loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[ASR] ✅ Ready (WhisperKit openai_whisper-base, ~140 MB, \(String(format: "%.0f", loadMs))ms)")
        } catch {
            isAvailable = false
            print("[ASR] ❌ WhisperKit base init failed: \(error)")
        }
    }

    private func initializeSherpaOnnx() {

        #if targetEnvironment(simulator)
        isAvailable = false
        print("[ASR] Simulator build: sherpa-onnx disabled")
        return
        #endif

        // 按系统语言选择 ASR 资产 — 中文用 zh-only sherpa, 英文用 en-only sherpa。
        // 两个仓库的文件命名不一样: zh 是 encoder.int8.onnx 等短名,
        // en 是 encoder-epoch-99-avg-1.int8.onnx 等带 epoch 后缀的长名。
        let asset = LiveModelDefinition.activeASR
        let isChinese = LanguageService.shared.current.isChinese

        // 双路径查找: Bundle 优先 (向后兼容打包方式), 其次 Documents (手机端下载)
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
            print("[ASR] Using downloaded model at: \(downloaded.path)")
        } else {
            let docPath = LiveModelDefinition.downloadedDirectory(for: asset).path
            print("[ASR] ❌ Model not found in bundle or downloads (expected: \(docPath))")
            return
        }

        let encoder: String
        let decoder: String
        let joiner: String
        if isChinese {
            encoder = modelDir + "/encoder.int8.onnx"
            decoder = modelDir + "/decoder.onnx"          // 注：decoder 不做 int8 量化（受益小）
            joiner = modelDir + "/joiner.int8.onnx"
        } else {
            encoder = modelDir + "/encoder-epoch-99-avg-1.int8.onnx"
            decoder = modelDir + "/decoder-epoch-99-avg-1.onnx"  // 同上, 用 fp32 decoder
            joiner = modelDir + "/joiner-epoch-99-avg-1.int8.onnx"
        }
        let tokens = modelDir + "/tokens.txt"

        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: sherpaOnnxOnlineModelConfig(
                tokens: tokens,
                transducer: sherpaOnnxOnlineTransducerModelConfig(
                    encoder: encoder,
                    decoder: decoder,
                    joiner: joiner
                ),
                numThreads: 2,
                debug: 0
            ),
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.4,
            rule2MinTrailingSilence: 1.2,
            rule3MinUtteranceLength: 20
        )

        fullTurnRecognizer = SherpaOnnxRecognizer(config: &config)
        streamingRecognizer = SherpaOnnxRecognizer(config: &config)
        isAvailable = fullTurnRecognizer != nil && streamingRecognizer != nil
        let langTag = isChinese ? "zh" : "en"
        let trainingNote = isChinese ? "2025-06-30" : "LibriSpeech+GigaSpeech 2023-06-21"
        print("[ASR] \(isAvailable ? "✅ Ready (\(langTag), int8, \(trainingNote))" : "❌ Init failed")")
    }

    /// 识别完整 PCM 音频 → 返回中文文字
    func transcribe(samples: [Float], sampleRate: Int = 16000) async -> String {
        await ensureInitialized()

        switch backend {
        case .whisperKitBase:
            return await transcribeWithWhisperKit(samples: samples, sampleRate: sampleRate)
        case .sherpaOnnx:
            return transcribeWithSherpa(samples: samples, sampleRate: sampleRate)
        }
    }

    private func transcribeWithWhisperKit(samples: [Float], sampleRate: Int) async -> String {
        guard let whisperKit else {
            print("[ASR] WhisperKit unavailable; returning empty transcript")
            return ""
        }

        do {
            let start = CFAbsoluteTimeGetCurrent()
            let audio = sampleRate == 16000
                ? samples
                : resampleLinear(samples: samples, from: sampleRate, to: 16000)
            print("[ASR] WhisperKit transcribe start: \(audio.count) samples @ 16000Hz (\(String(format: "%.2f", Double(audio.count) / 16000.0))s)")

            // 显式开自动语言检测.
            // openai_whisper-base 是 multilingual 模型 (generation_config.json
            // is_multilingual=true, forced_decoder_ids 第 1 位 null 留给语言 token),
            // 但 WhisperKit 默认 DecodingOptions(language: "en", detectLanguage: nil),
            // 不显式开会强制走英文转录, 用户说中文会被翻译成英文文字 (不是 transcribe).
            // 改成 task=.transcribe (转录原语言) + detectLanguage=true (自动识别) +
            // language=nil (不预设).
            let options = DecodingOptions(
                task: .transcribe,
                language: nil,
                detectLanguage: true
            )
            let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
            let transcript = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detectedLang = results.first?.language ?? "?"
            let asrMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[ASR] WhisperKit transcribe done: results=\(results.count), lang=\(detectedLang), \(String(format: "%.0f", asrMs))ms, text=\"\(transcript)\"")
            return transcript
        } catch {
            print("[ASR] ❌ WhisperKit transcription failed: \(error)")
            return ""
        }
    }

    private func transcribeWithSherpa(samples: [Float], sampleRate: Int = 16000) -> String {
        guard let recognizer = fullTurnRecognizer else { return "" }

        // Reset for new utterance
        recognizer.reset()

        // Feed audio
        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)

        // Add tail padding
        let tailPadding = [Float](repeating: 0, count: Int(0.3 * Float(sampleRate)))
        recognizer.acceptWaveform(samples: tailPadding, sampleRate: sampleRate)

        // Decode
        while recognizer.isReady() {
            recognizer.decode()
        }

        let result = recognizer.getResult()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 开始一个新的流式识别 session。
    /// 用于 Pipecat 风格的 interruption 确认：边说边拿 partial transcript。
    func beginStreaming() {
        guard backend == .sherpaOnnx else { return }
        streamingRecognizer?.reset()
    }

    /// 当 recognizer 还是 nil 但模型已就位 (e.g. 用户在 app 运行期间下载了 LIVE 模型),
    /// 重新初始化一次. 避免用户被迫重启 app 才能用语音输入.
    private func ensureInitialized() async {
        switch backend {
        case .whisperKitBase:
            guard whisperKit == nil else { return }
            await initialize()
        case .sherpaOnnx:
            ensureSherpaInitialized()
        }
    }

    private func ensureSherpaInitialized() {
        guard fullTurnRecognizer == nil else { return }
        // 只有当"以前试过但失败"且"模型现在已就绪"才值得再试一次.
        // hasRequiredFiles 快 (只 stat 4 个文件), 不会让 hot path 变慢太多.
        let asset = LiveModelDefinition.activeASR
        let downloaded = LiveModelDefinition.downloadedDirectory(for: asset)
        let hasBundle = Bundle.main.path(forResource: asset.directoryName, ofType: nil) != nil
        let hasDownloaded = LiveModelDefinition.hasRequiredFiles(asset, at: downloaded)
        guard hasBundle || hasDownloaded else { return }
        if initAttempted {
            print("[ASR] Retry initialize: LIVE models now present")
        }
        initializeSherpaOnnx()
    }

    /// 喂入一段 chunk，返回当前 partial transcript。
    func appendStreaming(samples: [Float], sampleRate: Int = 16000) -> StreamingResult {
        guard let recognizer = streamingRecognizer else { return .empty }

        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)
        while recognizer.isReady() {
            recognizer.decode()
        }

        return makeStreamingResult(from: recognizer.getResult())
    }

    /// 结束当前流式 session，并返回最终 transcript。
    func endStreaming(sampleRate: Int = 16000) -> StreamingResult {
        guard let recognizer = streamingRecognizer else { return .empty }

        let tailPadding = [Float](repeating: 0, count: Int(0.24 * Float(sampleRate)))
        recognizer.acceptWaveform(samples: tailPadding, sampleRate: sampleRate)
        recognizer.inputFinished()

        while recognizer.isReady() {
            recognizer.decode()
        }

        let result = makeStreamingResult(from: recognizer.getResult())
        recognizer.reset()
        return result
    }

    /// 放弃当前流式 session。
    func cancelStreaming() {
        streamingRecognizer?.reset()
    }

    /// 释放 recognizer, 节省约 ~160MB 内存. 典型用法: 用户新建会话时.
    /// 下次 transcribe 会通过 ensureInitialized 再装回来.
    func unload() {
        guard whisperKit != nil || fullTurnRecognizer != nil || streamingRecognizer != nil else { return }
        initializationTask?.cancel()
        initializationTask = nil
        whisperKit = nil
        fullTurnRecognizer = nil
        streamingRecognizer = nil
        isAvailable = false
        initAttempted = false
        print("[ASR] Unloaded")
    }

    private func makeStreamingResult(from result: SherpaOnnxOnlineRecongitionResult) -> StreamingResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitCount = max(result.tokens.count, fallbackUnitCount(from: text))
        return StreamingResult(text: text, unitCount: unitCount)
    }

    private func fallbackUnitCount(from text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let whitespaceUnits = trimmed.split(whereSeparator: \.isWhitespace)
        if whitespaceUnits.count > 1 {
            return whitespaceUnits.count
        }

        let punctuation = CharacterSet(charactersIn: "，。！？；：、,.!?;:")
        return trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) && !punctuation.contains(scalar) {
                count += 1
            }
        }
    }

    /// 读 generation_config.json 的 is_multilingual + vocab_size 等字段, 启动时打印一行
    /// 明确确认本地模型变体. 不会影响加载, 只读 metadata.
    private func logModelVariant(modelFolder: URL) {
        let configURL = modelFolder.appendingPathComponent("generation_config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[ASR] ⚠️ Cannot read generation_config.json at \(configURL.path)")
            return
        }
        let isMultilingual = json["is_multilingual"] as? Bool
        let langCount = (json["lang_to_id"] as? [String: Any])?.count
        let suppressCount = (json["suppress_tokens"] as? [Int])?.count ?? -1
        let multilingualLabel: String = {
            switch isMultilingual {
            case true: return "✅ multilingual"
            case false: return "❌ English-only"
            case nil: return "⚠️ unspecified"
            }
        }()
        print("[ASR] Model variant check: \(multilingualLabel)" +
              (langCount.map { ", \($0) languages" } ?? "") +
              ", suppress_tokens=\(suppressCount)")
    }

    private func resampleLinear(samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else {
            return samples
        }

        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        return (0..<outputCount).map { index in
            let sourcePosition = Double(index) * ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private func bundledWhisperKitBaseFolder() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("openai_whisper-base", isDirectory: true),
            resourceURL
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("openai_whisper-base", isDirectory: true)
        ]

        return candidates.first { url in
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true).path
            )
            && FileManager.default.fileExists(
                atPath: url.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true).path
            )
            && FileManager.default.fileExists(
                atPath: url.appendingPathComponent("MelSpectrogram.mlmodelc", isDirectory: true).path
            )
            && FileManager.default.fileExists(
                atPath: url.appendingPathComponent("config.json").path
            )
            && FileManager.default.fileExists(
                atPath: url.appendingPathComponent("tokenizer.json").path
            )
        }
    }
}
