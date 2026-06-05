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

    /// 固定 backend (测试 / CLI harness 用); nil = 动态跟随 `Backend.current`。
    private let backendOverride: Backend?
    /// 生效 backend。动态很关键: `Backend.current` 依赖当前语言 (日语 → whisperKitBase),
    /// 用户运行时切语言后, 长生命周期实例 (ContentView.holdToTalkASR / LiveModeEngine.asr) 必须跟着变。
    private var backend: Backend { backendOverride ?? Backend.current }
    /// 当前已加载状态对应的 backend; 与 `backend` 不一致 (切语言) 时先 unload 再按新 backend 重载。
    private var loadedBackend: Backend?
    /// 正在初始化的 backend (warmup 在途)。语言在 warmup 中途切换时, 用它判断在途 task 是否已过期。
    private var initializingBackend: Backend?
    /// 单调代数。每次启动新 init task / unload 时 +1, 让在途 awaiter 据此判断自己是否被取代,
    /// 避免「旧 backend 初始化完成后误把 loadedBackend 提交成旧值 / 留下装错 backend 的窗口」。
    private var initGeneration: UInt64 = 0
    private var initializationTask: Task<Void, Never>?
    private var whisperKit: WhisperKit?
    private var fullTurnRecognizer: SherpaOnnxRecognizer?
    private var streamingRecognizer: SherpaOnnxRecognizer?
    /// 日语离线 ASR (ReazonSpeech)。不参与 online streaming (full/streamingRecognizer)。
    private var offlineRecognizer: SherpaOnnxOfflineRecognizer?
    private(set) var isAvailable = false

    /// 曾经查找过但失败. 避免每次 transcribe 反复尝试 init 浪费时间.
    /// 一旦 ensureInitialized 检测到模型文件存在, 会清零重试.
    private var initAttempted = false

    init(backend: Backend? = nil) {
        self.backendOverride = backend
    }

    func initialize() async {
        let target = backend

        // 已装好且正是目标 backend → 完成。
        if isAvailable, loadedBackend == target { return }

        // 有在途 warmup: backend 一致就等它完成; 不一致 (语言切换打断了 warmup) → 取消并清状态后重启,
        // 不要 await 旧 backend 的 task 然后 return (那会留下「旧 backend 装好、新 backend 没装」的空窗)。
        if let task = initializationTask {
            if initializingBackend == target {
                await task.value
                return
            }
            unload()  // 取消在途旧 task + 清状态 + bump generation
        } else if let loadedBackend, loadedBackend != target {
            // 已装好但 backend 不符 → 卸掉重装。
            unload()
        }

        initAttempted = true
        initializingBackend = target
        initGeneration &+= 1
        let gen = initGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            switch target {
            case .whisperKitBase:
                // init 函数只**构建**, 不写 self。构建期间语言可能切换 (unload bump generation),
                // 此时旧 task 仍会跑完 — 用 generation guard 拦在提交前, 旧 recognizer 不写回。
                let kit = await self.initializeWhisperKit()
                guard gen == self.initGeneration, target == self.backend else { return }
                self.whisperKit = kit
                self.isAvailable = (kit != nil)
            case .sherpaOnnx:
                let r = self.initializeSherpaOnnx()
                guard gen == self.initGeneration, target == self.backend else { return }
                self.fullTurnRecognizer = r.full
                self.streamingRecognizer = r.streaming
                self.isAvailable = r.available
            case .sherpaOfflineJA:
                let rec = self.initializeSherpaOfflineJA()
                guard gen == self.initGeneration, target == self.backend else { return }
                self.offlineRecognizer = rec
                self.isAvailable = (rec != nil)
            }
        }

        initializationTask = task
        await task.value

        // warmup 期间被取消/重启 (新一轮 init 或 unload bump 了 generation) → 本轮结果作废, 不提交。
        guard gen == initGeneration else { return }
        initializationTask = nil
        initializingBackend = nil
        // 只有 target 仍是当前生效 backend 才标记 loaded — 语言若在 warmup 中切走,
        // 不把旧 backend 错置成 loaded (gen 未变但 backend 已变的情况)。
        if isAvailable, target == backend { loadedBackend = target }
    }

    /// 只构建并返回 WhisperKit (不写 self) — 提交由调用方在 generation guard 后统一做。
    private func initializeWhisperKit() async -> WhisperKit? {
        if let whisperKit { return whisperKit }

        do {
            // 模型路径解析: bundle 优先 (向后兼容打包方式), 然后 Documents/models/openai_whisper-base/
            // (用户在配置页通过 LIVE 语音模型按钮下载到的位置).
            // resolve 找不到 → 用户没下载, 不能 init, 让 transcribe 路径上的 UI 报错引导。
            guard let modelFolder = LiveModelDefinition.resolve(for: LiveModelDefinition.whisperBase) else {
                let expected = LiveModelDefinition.downloadedDirectory(for: LiveModelDefinition.whisperBase).path
                print("[ASR] ❌ WhisperKit base model not found. Download via LIVE Voice Models in Configurations. Expected: \(expected)")
                return nil
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
            let kit = try await WhisperKit(config)
            let loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[ASR] ✅ Ready (WhisperKit openai_whisper-base, ~140 MB, \(String(format: "%.0f", loadMs))ms)")
            return kit
        } catch {
            print("[ASR] ❌ WhisperKit base init failed: \(error)")
            return nil
        }
    }

    /// 只构建并返回 recognizer (不写 self) — 提交由调用方在 generation guard 后统一做。
    private func initializeSherpaOnnx() -> (full: SherpaOnnxRecognizer?, streaming: SherpaOnnxRecognizer?, available: Bool) {

        #if targetEnvironment(simulator)
        print("[ASR] Simulator build: sherpa-onnx disabled")
        return (nil, nil, false)
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
            return (nil, nil, false)
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

        let full = SherpaOnnxRecognizer(config: &config)
        let streaming = SherpaOnnxRecognizer(config: &config)
        let available = full != nil && streaming != nil
        let langTag = isChinese ? "zh" : "en"
        let trainingNote = isChinese ? "2025-06-30" : "LibriSpeech+GigaSpeech 2023-06-21"
        print("[ASR] \(available ? "✅ Ready (\(langTag), int8, \(trainingNote))" : "❌ Init failed")")
        return (full, streaming, available)
    }

    /// 只构建并返回 ReazonSpeech 日语离线 recognizer (不写 self) — 提交由调用方在 generation guard 后做。
    private func initializeSherpaOfflineJA() -> SherpaOnnxOfflineRecognizer? {
        // simulator: SherpaOnnxOfflineRecognizer 的 sim stub init? 直接返回 nil (见 SherpaOnnx.swift),
        // 所以这里走完也会得到 nil → isAvailable=false, 不会被误标 ready。无需 #if 早退 (避免 unreachable 警告)。
        let asset = LiveModelDefinition.asrJA
        let modelDir: String
        if let bundled = Bundle.main.path(forResource: asset.directoryName, ofType: nil) {
            modelDir = bundled
        } else if let downloaded = LiveModelDefinition.resolve(for: asset) {
            modelDir = downloaded.path
        } else {
            print("[ASR] ❌ ReazonSpeech model not found (expected: \(LiveModelDefinition.downloadedDirectory(for: asset).path))")
            return nil
        }

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: modelDir + "/encoder-epoch-99-avg-1.int8.onnx",
            decoder: modelDir + "/decoder-epoch-99-avg-1.onnx",
            joiner: modelDir + "/joiner-epoch-99-avg-1.int8.onnx"
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: modelDir + "/tokens.txt",
            transducer: transducer,
            numThreads: 2,
            debug: 0
        )
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        let rec = SherpaOnnxOfflineRecognizer(config: &config)
        print("[ASR] \(rec != nil ? "✅ Ready (ReazonSpeech ja, offline zipformer int8)" : "❌ ReazonSpeech init failed")")
        return rec
    }

    /// ReazonSpeech 离线识别: VAD 端点后整段 PCM → 日语文字 (非流式 partial)。
    /// Reazon model card 建议 ~30s 以内的片段; 超长 turn 切成 ≤28s 块逐块解码再拼接,
    /// 避免一次性丢超长音频导致质量明显下降或失败。
    private func transcribeWithSherpaOfflineJA(samples: [Float], sampleRate: Int) -> String {
        guard let recognizer = offlineRecognizer else {
            print("[ASR] ReazonSpeech offline recognizer unavailable; empty transcript")
            return ""
        }
        let audio = sampleRate == 16000
            ? samples
            : resampleLinear(samples: samples, from: sampleRate, to: 16000)
        let start = CFAbsoluteTimeGetCurrent()

        let maxChunk = 28 * 16000   // 28s @ 16kHz, 留余量 (model card ~30s 上限)
        let text: String
        if audio.count <= maxChunk {
            text = recognizer.decode(samples: audio, sampleRate: 16000).text
        } else {
            // 长 turn: 切 ≤28s 块逐块离线解码再拼 (日语无词间空格, 直接拼接)。
            var parts: [String] = []
            var offset = 0
            while offset < audio.count {
                let end = min(offset + maxChunk, audio.count)
                let piece = recognizer.decode(samples: Array(audio[offset..<end]), sampleRate: 16000)
                    .text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { parts.append(piece) }
                offset = end
            }
            text = parts.joined()
            print("[ASR] ReazonSpeech long turn \(String(format: "%.1f", Double(audio.count) / 16000))s → \(parts.count) chunks")
        }

        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[ASR] ReazonSpeech transcribe done: \(String(format: "%.0f", asrMs))ms, text=\"\(result)\"")
        return result
    }

    /// 识别完整 PCM 音频 → 返回中文文字
    func transcribe(samples: [Float], sampleRate: Int = 16000) async -> String {
        await ensureInitialized()

        switch backend {
        case .whisperKitBase:
            return await transcribeWithWhisperKit(samples: samples, sampleRate: sampleRate)
        case .sherpaOnnx:
            return transcribeWithSherpa(samples: samples, sampleRate: sampleRate)
        case .sherpaOfflineJA:
            return transcribeWithSherpaOfflineJA(samples: samples, sampleRate: sampleRate)
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

            // 按当前生效语言给 WhisperKit 语言提示, 不再纯自动检测。
            // openai_whisper-base 是 multilingual 模型, 但短语音 (1~2s) 的自动语言
            // 检测极不稳 — 实测日语会被误判成法语 (lang=fr, "Aller cadeau."), 转录全错。
            // 这条 WhisperKit 路径目前只在日语 backend 上用 (中/英走 sherpa), 但按
            // resolved 通用地给提示: ja→"ja" / zh→"zh" / en→"en"; 未知才回退自动检测。
            // task=.transcribe 保证转录原语言 (不翻译成英文)。
            let langHint: String? = {
                switch LanguageService.shared.current.resolved {
                case .ja:     return "ja"
                case .zhHans: return "zh"
                case .en:     return "en"
                default:      return nil
                }
            }()
            let options = DecodingOptions(
                task: .transcribe,
                language: langHint,
                detectLanguage: langHint == nil
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
        guard backend == .sherpaOnnx, loadedBackend == .sherpaOnnx else { return }
        streamingRecognizer?.reset()
    }

    /// 当 recognizer 还是 nil 但模型已就位 (e.g. 用户在 app 运行期间下载了 LIVE 模型),
    /// 重新初始化一次. 避免用户被迫重启 app 才能用语音输入.
    private func ensureInitialized() async {
        let target = backend
        // backend 变了 (语言切换) — 已加载的、或 warmup 在途的旧 backend, 都先丢掉再按新 backend 装。
        if (loadedBackend != nil && loadedBackend != target)
            || (initializingBackend != nil && initializingBackend != target) {
            unload()
        }
        switch target {
        case .whisperKitBase:
            guard whisperKit == nil else { return }
            await initialize()
        case .sherpaOnnx:
            ensureSherpaInitialized()
            if isAvailable { loadedBackend = .sherpaOnnx }
        case .sherpaOfflineJA:
            // 离线 recognizer 模型大 (~148MB int8 encoder), 走异步 initialize() task (跟 whisperKitBase 一样)。
            guard offlineRecognizer == nil else { return }
            await initialize()
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
        // 同步重试路径 (无 await / 无并发 task), 直接提交构建结果。
        let r = initializeSherpaOnnx()
        fullTurnRecognizer = r.full
        streamingRecognizer = r.streaming
        isAvailable = r.available
    }

    /// 喂入一段 chunk，返回当前 partial transcript。
    func appendStreaming(samples: [Float], sampleRate: Int = 16000) -> StreamingResult {
        // 仅当生效 + 已加载 backend 都是 sherpa 才喂流式 — 否则 (切到日语 WhisperKit) 旧 recognizer 已失效。
        guard backend == .sherpaOnnx, loadedBackend == .sherpaOnnx,
              let recognizer = streamingRecognizer else { return .empty }

        recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)
        while recognizer.isReady() {
            recognizer.decode()
        }

        return makeStreamingResult(from: recognizer.getResult())
    }

    /// 结束当前流式 session，并返回最终 transcript。
    func endStreaming(sampleRate: Int = 16000) -> StreamingResult {
        guard backend == .sherpaOnnx, loadedBackend == .sherpaOnnx,
              let recognizer = streamingRecognizer else { return .empty }

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
        guard backend == .sherpaOnnx else { return }
        streamingRecognizer?.reset()
    }

    /// 释放 recognizer, 节省约 ~160MB 内存. 典型用法: 用户新建会话时.
    /// 下次 transcribe 会通过 ensureInitialized 再装回来.
    func unload() {
        // 即使没有已加载的 recognizer, 也可能有在途 warmup task 要取消 (语言切换打断时),
        // 所以不能用「无 recognizer 就早退」的 guard 跳过 cancel。
        let hadState = whisperKit != nil || fullTurnRecognizer != nil
            || streamingRecognizer != nil || offlineRecognizer != nil || initializationTask != nil
        initializationTask?.cancel()
        initializationTask = nil
        initializingBackend = nil
        initGeneration &+= 1   // 让在途 awaiter (initialize 里 await task.value 之后) 判定自己已过期
        whisperKit = nil
        fullTurnRecognizer = nil
        streamingRecognizer = nil
        offlineRecognizer = nil
        isAvailable = false
        initAttempted = false
        loadedBackend = nil
        if hadState { print("[ASR] Unloaded") }
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
