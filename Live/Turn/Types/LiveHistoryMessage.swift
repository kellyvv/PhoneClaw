import Foundation

/// 一条 Live 历史消息.
///
/// 和主 Chat UI 的 `ChatMessage` 保持解耦:
///   - `ChatMessage` 带 images / audios / skillName / timestamp / id 等 UI 字段
///   - Live 历史只关心 role + content, 语音 pipeline 不需要这些元信息
///
/// Role 限定在 user / assistant — Live 不处理 system 或 skillResult 角色,
/// 这些由 LiveTurnProcessor 在本轮 prompt 构建时自行注入.
struct LiveHistoryMessage: Sendable {

    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}
