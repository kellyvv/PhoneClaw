import Foundation

// MARK: - LIVE Model Asset Definitions
//
// ASR (sherpa-onnx-streaming-zipformer-zh) + TTS (vits-zh-hf-keqing) + VAD (Silero) 的元信息。
// 用于手机端按需下载 LIVE 语音模型，与 LLM 下载基础设施并列但独立。
// VAD 也纳入统一下载流程 (hf-mirror → huggingface.co)，不再由 FluidAudio 自行管理。

struct LiveModelAsset: Sendable {
    let id: String
    let displayName: String
    let directoryName: String
    let repositoryID: String
    /// 如果 repo 是多模型仓 (e.g. argmaxinc/whisperkit-coreml 里同时有 tiny/base/small/large),
    /// 用这个 prefix 限定只下载 prefix 子目录, 本地存储时 prefix 自动剥掉.
    /// 例: prefix="openai_whisper-base" → 只取 repo/openai_whisper-base/* 的文件,
    ///     存到 Documents/models/<directoryName>/* (没有重复 prefix).
    /// nil = 整个 repo 都下载, 路径直存。
    let repositoryPathPrefix: String?
    /// 验证完整性用的关键文件 (不需要列出全部, 只需要核心模型文件).
    /// 路径相对**本地** directory (即 repositoryPathPrefix 已剥掉)。
    let requiredFiles: [String]
    /// 从 repo 中排除的文件模式 (不下载). 路径是 repository 相对.
    let excludePatterns: [String]
    /// 完整文件清单 (local 相对路径, 即 prefix 已剥掉)。非 nil 时 planner **跳过 HF tree API**,
    /// 直接按此清单拼 `/resolve/main/{file}` 直连下载 —— 跟 LLM 模型下载 (`ModelDownloader`) 一致。
    /// 动机: hf-mirror.com 只镜像文件下载 `/resolve/`, 不镜像列目录 `/api/.../tree`
    /// (该接口会 308 重定向到 huggingface.co, 国内被墙) → tree-listing 是 LIVE 下载卡顿的根因。
    /// nil = 走 tree API 动态发现 (多变体仓 / 清单易变的 asset 用这条)。
    let downloadManifest: [String]?

    init(
        id: String,
        displayName: String,
        directoryName: String,
        repositoryID: String,
        repositoryPathPrefix: String? = nil,
        requiredFiles: [String],
        excludePatterns: [String],
        downloadManifest: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.directoryName = directoryName
        self.repositoryID = repositoryID
        self.repositoryPathPrefix = repositoryPathPrefix
        self.requiredFiles = requiredFiles
        self.excludePatterns = excludePatterns
        self.downloadManifest = downloadManifest
    }
}

enum LiveModelDefinition {

    /// sherpa-onnx 中文流式 ASR (zipformer-zh, 2025-06-30 训练，~160MB int8).
    /// 选这个是因为它支持真增量流式 (acceptWaveform → decode → partial result),
    /// LIVE flow 里 Pipecat-style barge-in 的语义确认依赖这个能力。
    static let asr = LiveModelAsset(
        id: "live-asr",
        displayName: "语音识别 (ASR)",
        directoryName: "sherpa-asr-zh",
        repositoryID: "csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30",
        requiredFiles: [
            "encoder.int8.onnx",
            "decoder.onnx",
            "joiner.int8.onnx",
            "tokens.txt"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "test_wavs/"
        ]
    )

    /// 日语离线 ASR — ReazonSpeech zipformer (35k 小时日语训练的 offline transducer)。
    /// 替代旧的 WhisperKit fallback: 日语专精, 留在 sherpa 体系, 清单固定, 没有 WhisperKit
    /// 启动时再从 openai/whisper-base 拉 tokenizer 的第二链路。
    /// 交互仍是「VAD 端点后整句识别」(非真流式 partial — sherpa 暂无日语 online streaming
    /// 模型, 见 ASRBackend)。manifest 只拉 int8 encoder + fp32 decoder + int8 joiner + tokens
    /// (~162MB), 排除 565MB 的 fp32 encoder / fp32 joiner / test_wavs。
    static let asrJA = LiveModelAsset(
        id: "live-asr-ja",
        displayName: "音声認識 (ASR)",
        directoryName: "sherpa-asr-ja-reazonspeech",
        repositoryID: "reazon-research/reazonspeech-k2-v2",
        requiredFiles: [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "test_wavs/"
        ],
        downloadManifest: [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt"
        ]
    )

    static let tts = LiveModelAsset(
        id: "live-tts",
        displayName: "语音合成 (TTS)",
        directoryName: "vits-zh-hf-keqing",
        repositoryID: "csukuangfj/vits-zh-hf-keqing",
        requiredFiles: [
            "keqing.onnx",
            "lexicon.txt",
            "tokens.txt",
            "date.fst"        // 验证 FST 类文件也下载完整
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md"
        ]
    )

    static let vad = LiveModelAsset(
        id: "live-vad",
        displayName: "语音检测 (VAD)",
        directoryName: "silero-vad-coreml",
        repositoryID: "FluidInference/silero-vad-coreml",
        requiredFiles: [
            "silero-vad-unified-256ms-v6.0.0.mlmodelc"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "config.json",
            "graphs/",
            // Only need the 256ms unified v6, exclude all other variants
            "silero-vad-unified-256ms-v6.0.0.mlpackage/",
            "silero-vad-unified-v6.0.0.mlmodelc/",
            "silero-vad-unified-v6.0.0.mlpackage/",
            "silero_vad.mlmodelc/",
            "silero_vad_se_trained.mlpackage/",
            "silero_vad_se_trained_4bit.mlmodelc/"
        ],
        downloadManifest: [
            "silero-vad-unified-256ms-v6.0.0.mlmodelc/analytics/coremldata.bin",
            "silero-vad-unified-256ms-v6.0.0.mlmodelc/coremldata.bin",
            "silero-vad-unified-256ms-v6.0.0.mlmodelc/metadata.json",
            "silero-vad-unified-256ms-v6.0.0.mlmodelc/model.mil",
            "silero-vad-unified-256ms-v6.0.0.mlmodelc/weights/weight.bin"
        ]
    )

    // MARK: - 英文资产 (en-US)

    /// sherpa-onnx 英文流式 ASR (zipformer-transducer, int8, ~180 MB).
    /// 训练数据 = LibriSpeech + GigaSpeech (~10000 小时含 podcast/YouTube/audiobook),
    /// 比 LibriSpeech-only 模型在日常对话/指令场景识别率高一档。
    /// 文件命名带 -epoch-99-avg-1 后缀, 跟 zh-only 那个 (encoder.int8.onnx 短名) 不同。
    static let asrEN = LiveModelAsset(
        id: "live-asr-en",
        displayName: "English ASR",
        directoryName: "sherpa-asr-en",
        repositoryID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-21",
        requiredFiles: [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.onnx",         // 注: decoder 不做 int8 量化, 跟 zh-only 一致
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "test_wavs/",
            "export-onnx-stateless7-streaming-multi.sh",
            // fp32 encoder/joiner 是同一个模型不同精度, 我们只下 int8
            "encoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.onnx",
            // int8 decoder 比 fp32 大 (量化反而劣化, 5 MB → 1 MB), 但精度损失明显, 用 fp32
            "decoder-epoch-99-avg-1.int8.onnx"
        ]
    )

    /// Piper VITS 英文 TTS — LibriTTS-R medium 版 (~76 MB, 904 说话人多音色).
    /// 选这个的理由 (vs amy-medium):
    ///   - LibriTTS-R 是 Google 2024 年清洗优化的 LibriTTS 数据集, 训练质量比 amy 用的
    ///     HiFi-Captain 高一档, voice assistant 场景听感明显更自然
    ///   - 904 个 speaker 内嵌在同一个 .onnx 模型, 运行时 sid 切换不重新下载,
    ///     给以后做"用户选音色"留扩展口
    ///   - VITS medium 60M 参数, 推理速度跟 amy 一致, 不影响 LIVE TTS 延迟
    ///
    /// 仓库 362 个文件 / 92 MB, 优化后下载 11 个文件 / ~76 MB:
    ///   - 113 个 *_dict 字典文件 (16 MB) — `*_dict` 通配符砍掉, 只留 en_dict
    ///   - 138 个 espeak-ng-data/lang/*/* 语言定义文件 (16 KB) — `lang/` 目录砍掉,
    ///     只留 en/en-US 两个
    ///   - 104 个 espeak-ng-data/voices/* voice variant (角色音色) — `voices/` 目录砍
    ///   - 几个零散文件 (MODEL_CARD, .sh 脚本等) — 精确匹配砍
    ///
    /// **`tokens.txt` 必须保留**: sherpa-onnx 的 OfflineTtsVitsModelConfig 要求 tokens 路径非空。
    static let ttsEN = LiveModelAsset(
        id: "live-tts-en",
        displayName: "English TTS",
        directoryName: "vits-piper-en_US-libritts_r-medium",
        repositoryID: "csukuangfj/vits-piper-en_US-libritts_r-medium",
        requiredFiles: [
            "en_US-libritts_r-medium.onnx",
            "en_US-libritts_r-medium.onnx.json",
            "tokens.txt",
            // espeak-ng 共享文件 (语言无关的核心音素数据)
            "espeak-ng-data/en_dict",
            "espeak-ng-data/phondata",
            "espeak-ng-data/phontab",
            "espeak-ng-data/phonindex",
            "espeak-ng-data/intonations",
            "espeak-ng-data/phondata-manifest",
            // 英文语言定义文件 (.onnx.json 里 espeak.voice="en-us")
            "espeak-ng-data/lang/gmw/en",
            "espeak-ng-data/lang/gmw/en-US"
        ],
        excludePatterns: [
            ".gitattributes",
            "vits-piper-en_US.py",
            "vits-piper-en_US.sh",
            "MODEL_CARD",
            // 通配符: 排除所有 *_dict (en_dict 在 requiredFiles, 仍下载)
            "*_dict",
            // 目录排除: voices variant + 其他 lang 子目录 (en* 在 requiredFiles, 仍下载)
            "espeak-ng-data/voices/",
            "espeak-ng-data/lang/"
        ]
    )

    // MARK: - 日语 TTS (ja)

    static let openJTalkDictionaryDirectoryName = "open_jtalk_dic_utf_8-1.11"

    #if canImport(PiperPlus)
    static let piperPlusJARuntimeLinked = true
    #else
    static let piperPlusJARuntimeLinked = false
    #endif

    static var openJTalkDictionaryDirectory: URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent(openJTalkDictionaryDirectoryName, isDirectory: true),
            Bundle.main.resourceURL?
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(openJTalkDictionaryDirectoryName, isDirectory: true),
            ModelPaths.documentsRoot().appendingPathComponent(openJTalkDictionaryDirectoryName, isDirectory: true)
        ].compactMap { $0 }

        return candidates.first { dir in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: dir.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && fm.fileExists(atPath: dir.appendingPathComponent("sys.dic").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("matrix.bin").path)
        }
    }

    static var openJTalkDictionaryBundled: Bool {
        openJTalkDictionaryDirectory != nil
    }

    /// Piper Plus 日语 TTS 是否可启用。
    /// 必须同时满足 runtime 已链接 + OpenJTalk 词典已发布到 Bundle 或 Documents/models。
    /// 只下载模型不够; 缺词典会导致日语 G2P 不可用。
    static var piperPlusJAReady: Bool {
        piperPlusJARuntimeLinked && openJTalkDictionaryBundled
    }

    /// Piper Plus 日语模型 — tsukuyomi-chan 6-language fp16 ONNX。
    /// 运行时依赖 Piper Plus xcframework + OpenJTalk 词典, 不走 sherpa-onnx。
    /// 该仓清单固定, 只需要 model + config; samples/README 不下载。
    static let ttsPiperPlusJA = LiveModelAsset(
        id: "live-tts-ja-piper-plus",
        displayName: "音声合成 (TTS)",
        directoryName: "piper-plus-ja-tsukuyomi",
        repositoryID: "ayousanz/piper-plus-tsukuyomi-chan",
        requiredFiles: [
            "tsukuyomi-chan-6lang-fp16.onnx",
            "config.json"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md",
            "samples/"
        ],
        downloadManifest: [
            "tsukuyomi-chan-6lang-fp16.onnx",
            "config.json"
        ]
    )

    /// Supertonic-3 (日语 TTS) 是否可用 —— **当前 false (被 ORT 版本卡住)**。
    /// 仓库内置 `Frameworks/onnxruntime.xcframework` 是 **1.17.1** (ai.onnx.ml 仅到 opset 4),
    /// 而 Supertonic-3 (2026-05-11) 的 vocoder.int8.onnx 用了 **ai.onnx.ml opset 5** →
    /// `SherpaOnnxCreateOfflineTts` 加载时抛 C++ 异常 (Swift try 抓不住) → 直接 crash。
    /// 打开条件: 把 onnxruntime + sherpa-onnx xcframework 升级到支持 opset 5 的版本
    /// (ORT ≥ ~1.20; .tts_venv 里已是 1.23.2)。在那之前, 日语 TTS 不启用
    /// Supertonic, 也不走系统 TTS fallback。
    /// 升级 binary 后只需把这里改 true。
    static let supertonicJAReady = false

    /// 日语 TTS — Supertonic-3 (sherpa-onnx Supertonic 后端, int8, ~145MB)。
    /// 神经合成, 音色追平中英文的 keqing/Piper, 且和它们一样走共享 AVAudioEngine →
    /// iOS AEC 能消掉回声。
    ///
    /// Supertonic-3 是 char/unicode-based **多语**模型 (tts.json: n_langs=0, lang_emb_dim=0):
    /// 语言完全由输入文本字符 + unicode_indexer.bin 决定 — 喂日语文本即读日语,
    /// 不需要 lang 参数, 也不依赖 espeak/OpenJTalk g2p。单一内置音色 (voice.bin)。
    /// 7 个核心文件全部直连下载 (downloadManifest 跳过 HF tree API, 跟 asrJA 一致)。
    ///
    /// 注意: 当前被内置 ORT opset 边界禁用。默认日语 TTS 主线改为 Piper Plus
    /// (OpenJTalk 前端); Supertonic 只作为升级 sherpa/ORT 后的实验线。
    static let ttsJA = LiveModelAsset(
        id: "live-tts-ja",
        displayName: "音声合成 (TTS)",
        directoryName: "sherpa-tts-ja-supertonic",
        repositoryID: "csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11",
        requiredFiles: [
            "duration_predictor.int8.onnx",
            "text_encoder.int8.onnx",
            "vector_estimator.int8.onnx",
            "vocoder.int8.onnx",
            "tts.json",
            "unicode_indexer.bin",
            "voice.bin"
        ],
        excludePatterns: [
            ".gitattributes",
            "LICENSE",
            "README.md"
        ],
        downloadManifest: [
            "duration_predictor.int8.onnx",
            "text_encoder.int8.onnx",
            "vector_estimator.int8.onnx",
            "vocoder.int8.onnx",
            "tts.json",
            "unicode_indexer.bin",
            "voice.bin"
        ]
    )

    /// WhisperKit base — 多语言 ASR 模型 (~140 MB Core ML 编译版, 74M 参数).
    /// 比 tiny (39M 参数) 在中文/混合语种上识别率明显更高, 代价是下载/内存约 1.8x.
    /// argmaxinc/whisperkit-coreml repo 里同时有 tiny / base / small / large-v3 等多个变体,
    /// 用 repositoryPathPrefix 只取 openai_whisper-base/ 子目录, 本地落到
    /// Documents/models/openai_whisper-base/。
    ///
    /// 注: argmax repo 只包含 Core ML 文件 + config, 没有 tokenizer.json (~3MB).
    /// WhisperKit 启动时会自动从 openai/whisper-base 拉 tokenizer; 我们 LIVE
    /// 下载只覆盖 Core ML 大文件, tokenizer 由 WhisperKit 自己处理。
    static let whisperBase = LiveModelAsset(
        id: "live-asr-whisper",
        displayName: "Whisper Base (ASR)",
        directoryName: "openai_whisper-base",
        repositoryID: "argmaxinc/whisperkit-coreml",
        repositoryPathPrefix: "openai_whisper-base",
        requiredFiles: [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json"
        ],
        excludePatterns: [
            ".gitattributes",
            "README.md"
        ],
        // 直连清单 (跳过 tree API)。3 个 .mlmodelc 各 5 个标准 coremlc 文件 + config.json = 16。
        // 这是 WhisperKit base ASR 的功能完整集 (generation_config.json 等额外文件非必需:
        // logModelVariant 读不到只警告、不阻塞加载)。路径是 local 相对 (prefix openai_whisper-base 已剥)。
        downloadManifest: [
            "AudioEncoder.mlmodelc/analytics/coremldata.bin",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/metadata.json",
            "AudioEncoder.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/metadata.json",
            "MelSpectrogram.mlmodelc/model.mil",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/analytics/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/metadata.json",
            "TextDecoder.mlmodelc/model.mil",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "config.json"
        ]
    )

    static var all: [LiveModelAsset] {
        // ASR 资产随 backend/语言变 (日语 → asrJA ReazonSpeech, 中/英 → sherpa zh/en, 见 activeASR);
        // TTS 同理 (中 keqing / 英 Piper / 日 Supertonic-3, 见 activeTTS)。
        // activeTTS 仍是 optional, 用 if-let 防御 (将来某 locale 可能无资产)。
        var assets: [LiveModelAsset] = [activeASR]
        if let tts = activeTTS { assets.append(tts) }
        assets.append(vad)
        return assets
    }

    /// 当前激活的 ASR 资产 — 根据 backend 和系统语言决定。
    /// sherpaOnnx 后端下: 中文系统返回 zh-only sherpa, 英文返回 en sherpa。
    /// whisperKitBase 后端不区分语言 (Whisper 自己支持 99 语)。
    static var activeASR: LiveModelAsset {
        switch ASRBackend.current {
        case .sherpaOfflineJA: return asrJA           // 日语: ReazonSpeech 离线
        case .whisperKitBase: return whisperBase      // legacy 多语言 fallback (默认不再用)
        case .sherpaOnnx:
            return LanguageService.shared.current.isChinese ? asr : asrEN
        }
    }

    /// 当前激活的 sherpa TTS 资产 — 中文 vits-zh-keqing (lexicon-based) / 英文 vits-piper (espeak-based)
    /// / 日语 Supertonic-3 (char/unicode-based)。三套配置完全不同, 不能共用。
    /// 仍是 optional: 若以后某 locale 没有 sherpa 资产则返回 nil, 调用方要处理。
    static var activeTTS: LiveModelAsset? {
        switch LanguageService.shared.current.resolved {
        case .zhHans: return tts
        case .ja:
            if piperPlusJARuntimeLinked { return ttsPiperPlusJA }
            return supertonicJAReady ? ttsJA : nil   // nil → 日语神经 TTS 未接入, 不走系统 TTS
        default:      return ttsEN
        }
    }

    /// 合并 ID，用于 UI 展示和状态管理
    static let combinedID = "live-voice-models"

    /// 总大小估算 (用于 UI 提示). 根据当前语言返回对应的语言包总大小。
    static var estimatedSizeMB: Int {
        if LanguageService.shared.current.isJapanese {
            // ReazonSpeech ASR ≈ 162MB + VAD ~5MB; Piper Plus model ≈ 40MB; Supertonic-3 ≈ 145MB。
            if piperPlusJARuntimeLinked { return 207 }
            return supertonicJAReady ? 312 : 167
        }
        switch ASRBackend.current {
        case .sherpaOfflineJA:
            return 167  // 不会走到 (日语已在上面 early-return), 保留以满足 switch 穷尽。
        case .whisperKitBase:
            return 285  // Whisper base ~140MB + TTS ~136MB + VAD ~5MB (TTS 仍按中文 keqing 算)
        case .sherpaOnnx:
            if LanguageService.shared.current.isChinese {
                return 301  // zh ASR ~160MB + TTS keqing ~136MB + VAD ~5MB
            } else {
                return 261  // en ASR ~180MB + TTS libritts_r-medium ~76MB + VAD ~5MB
            }
        }
    }

    // MARK: - Path 转换 helpers (针对 repositoryPathPrefix)

    /// 把本地相对路径转成 repository URL 相对路径.
    /// 没有 prefix 时直接返回原路径; 有 prefix 时前面加上 prefix/。
    static func remotePath(for localRelative: String, in asset: LiveModelAsset) -> String {
        guard let prefix = asset.repositoryPathPrefix, !prefix.isEmpty else {
            return localRelative
        }
        return "\(prefix)/\(localRelative)"
    }

    /// 反过来: repository 路径转成本地相对路径 (剥掉 prefix).
    /// 不在 prefix 范围内的返回 nil — planner 用这个来过滤 tree。
    static func localPath(forRepository remotePath: String, in asset: LiveModelAsset) -> String? {
        guard let prefix = asset.repositoryPathPrefix, !prefix.isEmpty else {
            return remotePath
        }
        let prefixWithSlash = prefix.hasSuffix("/") ? prefix : "\(prefix)/"
        guard remotePath.hasPrefix(prefixWithSlash) else { return nil }
        return String(remotePath.dropFirst(prefixWithSlash.count))
    }

    // MARK: - Path Helpers

    /// 下载目录: Documents/models/<directoryName>/
    static func downloadedDirectory(for asset: LiveModelAsset) -> URL {
        ModelPaths.documentsRoot().appendingPathComponent(asset.directoryName, isDirectory: true)
    }

    static func partialDirectory(for asset: LiveModelAsset) -> URL {
        ModelPaths.documentsRoot().appendingPathComponent("\(asset.directoryName).partial", isDirectory: true)
    }

    /// Bundle 内模型路径（向后兼容打包方式）
    static func bundledDirectory(for asset: LiveModelAsset) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent(asset.directoryName, isDirectory: true)
        guard hasRequiredFiles(asset, at: dir) else { return nil }
        return dir
    }

    /// 解析模型路径: Bundle 优先, 否则 Documents
    static func resolve(for asset: LiveModelAsset) -> URL? {
        if let bundled = bundledDirectory(for: asset) {
            return bundled
        }
        let downloaded = downloadedDirectory(for: asset)
        if hasRequiredFiles(asset, at: downloaded) {
            return downloaded
        }
        return nil
    }

    static func hasRequiredFiles(_ asset: LiveModelAsset, at directory: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return asset.requiredFiles.allSatisfy { file in
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
    }

    /// 所有 LIVE 模型是否都已就绪 (Bundle 或 Documents)
    static var isAvailable: Bool {
        all.allSatisfy { resolve(for: $0) != nil }
    }

    // MARK: - File Filter

    /// 判断文件是否需要下载。优先级:
    ///   1. requiredFiles 列出的文件**永远下载** — exclude pattern 不能覆盖。
    ///      (例: ttsEN 的 `*_dict` 通配符排除所有字典, 但 `espeak-ng-data/en_dict`
    ///       在 requiredFiles 里, 仍会下载。)
    ///   2. 否则按 excludePatterns 匹配:
    ///      - `"foo/"` (尾部斜杠): 目录前缀排除, 匹配该目录下所有文件
    ///      - `"*_suffix"` (前缀星号): 通配符 — basename 以 _suffix 结尾就排除
    ///      - 其它: 整路径精确匹配 OR basename 匹配 (`path == pattern || path.hasSuffix("/pattern")`)
    static func shouldDownload(_ path: String, for asset: LiveModelAsset) -> Bool {
        // 白名单优先 — requiredFiles 永远下载
        if asset.requiredFiles.contains(path) {
            return true
        }

        for pattern in asset.excludePatterns {
            if pattern.hasSuffix("/") {
                // 目录排除
                if path.hasPrefix(pattern) || path.hasPrefix(String(pattern.dropLast())) {
                    return false
                }
            } else if pattern.hasPrefix("*") {
                // 通配符后缀: "*_dict" 匹配 basename 以 _dict 结尾的文件
                let suffix = String(pattern.dropFirst())
                let basename = (path as NSString).lastPathComponent
                if basename.hasSuffix(suffix) {
                    return false
                }
            } else if path == pattern || path.hasSuffix("/\(pattern)") {
                return false
            }
        }
        return true
    }
}
