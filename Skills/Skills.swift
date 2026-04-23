import Foundation

// MARK: - Skill 数据模型
//
// 文件驱动架构：
//   - SKILL.md 定义 Skill 元数据 + 指令体（热更新）
//   - ToolRegistry.swift 注册原生工具实现（编译时）
//   - SkillLoader.swift 解析 SKILL.md (无状态) + SkillRegistry 注册/查询 (有状态)
//
// 以下仅为给 UI 和 PromptBuilder 使用的精简数据结构。

// MARK: - Skill 条目（给 UI 管理用）

struct ToolInfo: Equatable {
    let name: String
    let description: String
    let parameters: String
}

struct SkillEntry: Identifiable {
    let id: String          // skill directory name, e.g. "clipboard"
    var name: String        // display name, e.g. "Clipboard"
    var description: String
    var icon: String
    var type: SkillType
    var requiresTimeAnchor: Bool = false
    var samplePrompt: String
    /// 欢迎页快捷 chip 的发送内容 (来源 SKILL.md `chip_prompt` 字段).
    /// 不声明的 skill 不会出现在 chip 列表里.
    var chipPrompt: String?
    /// 欢迎页快捷 chip 的 UI 显示短 label (来源 SKILL.md `chip_label`).
    /// 缺省时 UI 直接显示 chipPrompt 全文.
    var chipLabel: String?
    var tools: [ToolInfo] = []
    var isEnabled: Bool = true
    var filePath: URL?      // SKILL.md 路径（用于编辑）

    /// 从 SkillDefinition 转换
    init(from def: SkillDefinition, registry: ToolRegistry) {
        self.id = def.id
        self.name = def.metadata.displayName
        self.description = def.metadata.description
        self.icon = def.metadata.icon
        self.type = def.metadata.type
        self.requiresTimeAnchor = def.metadata.requiresTimeAnchor
        self.samplePrompt = def.metadata.examples.first?.query ?? ""
        self.chipPrompt = def.metadata.chipPrompt?.isEmpty == true ? nil : def.metadata.chipPrompt
        self.chipLabel = def.metadata.chipLabel?.isEmpty == true ? nil : def.metadata.chipLabel
        self.isEnabled = def.isEnabled
        self.filePath = def.filePath
        self.tools = def.metadata.allowedTools.compactMap { toolName in
            guard let tool = registry.find(name: toolName) else { return nil }
            return ToolInfo(name: tool.name, description: tool.description, parameters: tool.parameters)
        }
    }
}

// MARK: - SkillInfo（给 PromptBuilder 用的精简描述）

struct SkillInfo {
    let name: String        // skill id, e.g. "clipboard"
    let description: String
    var displayName: String = ""
    var icon: String = "wrench"
    var type: SkillType = .device
    var requiresTimeAnchor: Bool = false
    var samplePrompt: String = ""
    var chipPrompt: String? = nil
    var chipLabel: String? = nil
}
