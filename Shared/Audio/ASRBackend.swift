import Foundation

// MARK: - ASR Backend Selector
//
// 提取 backend 枚举到独立文件 (无 sherpa / WhisperKit 依赖), 让 LiveModelDefinition
// 在 CLI 端 (PhoneClawCLI 跨平台 harness) 也能编译——CLI 把 ASRService.swift 整个排除了
// (Sherpa C bindings 不能在 Mac 上链接), 所以不能再让 Backend 嵌套在 ASRService 里。

enum ASRBackend: Sendable {
    case whisperKitBase
    case sherpaOnnx
    case sherpaOfflineJA

    /// 按当前语言选 backend:
    ///   - 中/英: sherpaOnnx — zh/en **online streaming** zipformer, 真增量流式
    ///     (acceptWaveform → decode → partial), LIVE 的 Pipecat-style barge-in 语义确认依赖它。
    ///   - 日语: sherpaOfflineJA — ReazonSpeech **offline** zipformer (日语专精, 35k 小时训练)。
    ///     sherpa 暂无日语 online streaming 模型, 所以日语走「VAD 端点后整句离线识别」:
    ///     交互粒度跟之前 WhisperKit batch 同级, 但日语精度更好、留在 sherpa 体系、清单固定
    ///     (无 WhisperKit 启动时再从 openai/whisper-base 拉 tokenizer 的第二链路)。
    ///     真流式 partial 待日语 online streaming 模型出现后再升级。
    ///   - whisperKitBase: 旧的多语言 fallback, 默认不再选用 (代码保留)。
    static var current: ASRBackend {
        LanguageService.shared.current.isJapanese ? .sherpaOfflineJA : .sherpaOnnx
    }
}
