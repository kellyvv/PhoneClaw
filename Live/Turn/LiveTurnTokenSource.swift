import Foundation
import CoreImage

// MARK: - LiveTurnTokenSource
//
// 一轮 LIVE 推理的 token 来源抽象 — 把"谁来念这份 turnPrompt"从 LiveTurnProcessor
// 解耦出来。contract 构造 (LiveSkillRuntime)、token 流解析 (LiveOutputParser)、
// tool_call 收口 (normalize → validate → ToolRegistry) 全部不感知 token 由谁生成,
// 原 Skill 链路零改动。
//
// 实现:
//   · LocalLiveTurnTokenSource          — 现状路径, 包一层 InferenceService.generateLive
//   · IOS27LiveFoundationTokenSource    — FoundationModels 档位 A (Skill 轮 FM 先行,
//                                         失败回退本地; 见 IOS27LiveFoundationTokenSource.swift)
//   · (预留) 远程 Mac 网关源             — stateless chat/completions + liveHistory 重放

protocol LiveTurnTokenSource {
    /// 进日志的来源名 (e.g. "local" / "foundation")。
    var sourceName: String { get }

    /// 本轮能否使用 (模型可用性 / 系统条件 / feature flag)。
    var isUsable: Bool { get }

    /// 生成本轮 token 流。流结束即本轮生成结束。
    /// 实现者保证: 创建即开始生成 (与 generateLive 语义一致), 调用方决定何时消费。
    func stream(turnPrompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error>

    /// 主动取消在飞生成 (如 parser 截获 tool_call 后提前停)。
    func cancel()
}

enum LiveTokenSourceError: Error {
    case unavailable
    case unsupportedInput(String)
}

/// 现状路径: 本地引擎 persistent live conversation。
/// chat 轮 (含视觉轮) 永远走这里; Skill 轮在替代源失败时回退到这里。
struct LocalLiveTurnTokenSource: LiveTurnTokenSource {
    let inference: InferenceService

    var sourceName: String { "local" }

    var isUsable: Bool { true }

    func stream(turnPrompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        inference.generateLive(prompt: turnPrompt, images: images, audios: [])
    }

    func cancel() {
        inference.cancel()
    }
}
