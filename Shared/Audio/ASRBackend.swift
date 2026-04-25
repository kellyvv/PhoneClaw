import Foundation

// MARK: - ASR Backend Selector
//
// 提取 backend 枚举到独立文件 (无 sherpa / WhisperKit 依赖), 让 LiveModelDefinition
// 在 CLI 端 (PhoneClawCLI 跨平台 harness) 也能编译——CLI 把 ASRService.swift 整个排除了
// (Sherpa C bindings 不能在 Mac 上链接), 所以不能再让 Backend 嵌套在 ASRService 里。

enum ASRBackend: Sendable {
    case whisperKitBase
    case sherpaOnnx

    /// sherpaOnnx 是默认: zh-only streaming zipformer (中文场景) / en-only streaming
    /// zipformer (英文场景), 都支持真增量流式 (acceptWaveform → decode → partial),
    /// LIVE flow 里 Pipecat-style barge-in 的语义确认通路依赖这个能力。
    /// WhisperKit 系列是 batch transcribe, 整段 turn 识别准但 barge-in 走不通,
    /// 保留 whisperKitBase 作为可选 backend, 不删。
    static let current: ASRBackend = .sherpaOnnx
}
