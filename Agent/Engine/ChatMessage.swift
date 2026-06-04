import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var role: Role
    var content: String
    var images: [ChatImageAttachment]
    var audios: [ChatAudioAttachment]
    let timestamp: Date
    var skillName: String? = nil
    /// .skillResult 的语义类型: 区分 load_skill 注入的说明书 / 真实工具执行结果 / content skill 生成文本。
    /// executeToolChain 的「工具已跑过」去重只数 .toolExecution —— 否则 skill-id == tool-name
    /// (如 web-search) 时, "已加载说明书" 会被误判成 "工具已执行" 而跳过真正的执行。
    var skillResultKind: SkillResultKind? = nil

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        images: [ChatImageAttachment] = [],
        audios: [ChatAudioAttachment] = [],
        timestamp: Date = Date(),
        skillName: String? = nil,
        skillResultKind: SkillResultKind? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.audios = audios
        self.timestamp = timestamp
        self.skillName = skillName
        self.skillResultKind = skillResultKind
    }

    mutating func update(content: String) {
        guard self.content != content else { return }
        self.content = content
    }

    mutating func update(role: Role, content: String, skillName: String? = nil) {
        self.role = role
        self.content = content
        self.skillName = skillName
    }

    enum Role: String, Codable {
        case user, assistant, system, skillResult
    }

    /// .skillResult 三种语义 —— 让去重能区分「已加载」和「已执行」。
    enum SkillResultKind: String, Codable {
        case skillInstructions   // load_skill 注入的 SKILL.md 说明书 (给模型读, 非工具结果)
        case toolExecution       // 真实工具 / 协议工具执行返回的结果
        case generatedContent    // content 型 skill 按 SKILL.md 直接生成的文本
    }
}

struct ChatSessionSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var preview: String
    var updatedAt: Date
}
