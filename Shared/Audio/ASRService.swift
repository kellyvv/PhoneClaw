import Foundation

// MARK: - ASR Service
//
// sherpa-onnx 中文流式 ASR (zipformer-zh, 2025-06-30 训练，~160MB int8)
// 输入 16kHz PCM → 输出中文文字
// 升级日志：
//   2026-04-15: zipformer-multi-zh-hans (2023-12-12, 69MB) → zipformer-zh (2025-06-30, 160MB)
//               新训练数据，标准普通话准确度更高。

class ASRService {

    struct StreamingResult {
        let text: String
        let unitCount: Int

        static let empty = StreamingResult(text: "", unitCount: 0)
    }

    private var fullTurnRecognizer: SherpaOnnxRecognizer?
    private var streamingRecognizer: SherpaOnnxRecognizer?
    private(set) var isAvailable = false

    /// 曾经查找过但失败. 避免每次 transcribe 反复尝试 init 浪费时间.
    /// 一旦 ensureInitialized 检测到模型文件存在, 会清零重试.
    private var initAttempted = false

    func initialize() {
        initAttempted = true

        #if targetEnvironment(simulator)
        isAvailable = false
        print("[ASR] Simulator build: sherpa-onnx disabled")
        return
        #endif

        // 双路径查找: Bundle 优先 (向后兼容打包方式), 其次 Documents (手机端下载)
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: "sherpa-asr-zh", ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: LiveModelDefinition.asr) {
            modelDir = downloaded.path
            print("[ASR] Using downloaded model at: \(downloaded.path)")
        } else {
            let docPath = LiveModelDefinition.downloadedDirectory(for: LiveModelDefinition.asr).path
            print("[ASR] ❌ Model not found in bundle or downloads (expected: \(docPath))")
            return
        }

        let encoder = modelDir + "/encoder.int8.onnx"
        let decoder = modelDir + "/decoder.onnx"          // 注：decoder 不做 int8 量化（受益小）
        let joiner = modelDir + "/joiner.int8.onnx"
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
        print("[ASR] \(isAvailable ? "✅ Ready (zh, int8, ~160MB, 2025-06-30)" : "❌ Init failed")")
    }

    /// 识别完整 PCM 音频 → 返回中文文字
    func transcribe(samples: [Float], sampleRate: Int = 16000) -> String {
        ensureInitialized()
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
        ensureInitialized()
        streamingRecognizer?.reset()
    }

    /// 当 recognizer 还是 nil 但模型已就位 (e.g. 用户在 app 运行期间下载了 LIVE 模型),
    /// 重新初始化一次. 避免用户被迫重启 app 才能用语音输入.
    private func ensureInitialized() {
        guard fullTurnRecognizer == nil else { return }
        // 只有当"以前试过但失败"且"模型现在已就绪"才值得再试一次.
        // hasRequiredFiles 快 (只 stat 4 个文件), 不会让 hot path 变慢太多.
        let asset = LiveModelDefinition.asr
        let downloaded = LiveModelDefinition.downloadedDirectory(for: asset)
        let hasBundle = Bundle.main.path(forResource: "sherpa-asr-zh", ofType: nil) != nil
        let hasDownloaded = LiveModelDefinition.hasRequiredFiles(asset, at: downloaded)
        guard hasBundle || hasDownloaded else { return }
        if initAttempted {
            print("[ASR] Retry initialize: LIVE models now present")
        }
        initialize()
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
        guard fullTurnRecognizer != nil || streamingRecognizer != nil else { return }
        fullTurnRecognizer = nil
        streamingRecognizer = nil
        isAvailable = false
        initAttempted = false
        print("[ASR] Unloaded (free ~160MB)")
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
}
