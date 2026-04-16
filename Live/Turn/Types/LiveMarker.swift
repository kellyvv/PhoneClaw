import Foundation

/// LLM 在 Live 语音模式下的 turn-completeness marker.
///
/// 约束写在 system prompt (`PromptBuilder.defaultLiveVoiceConstraints`) 里,
/// 解析在 `LiveOutputParser`, engine 根据 marker 决定:
///   - `.complete`    → ✓ 后续 token 是回答, 走 TTS 朗读
///   - `.interrupted` → ○ 用户被打断, 本轮不回答, 退回 listening
///   - `.thinking`    → ◐ 用户在思考, 本轮不回答, 退回 listening
enum LiveMarker: String, Sendable {
    case complete    = "✓"
    case interrupted = "○"
    case thinking    = "◐"
}
