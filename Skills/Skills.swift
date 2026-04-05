import Foundation

// MARK: - Skill 数据模型
//
// 文件驱动架构：
//   - SKILL.md 定义 Skill 元数据 + 指令体（热更新）
//   - ToolRegistry.swift 注册原生工具实现（编译时）
//   - SkillLoader.swift 解析和加载 SKILL.md
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
    var samplePrompt: String
    var tools: [ToolInfo] = []
    var isEnabled: Bool = true
    var filePath: URL?      // SKILL.md 路径（用于编辑）

    /// 从 SkillDefinition 转换
    init(from def: SkillDefinition, registry: ToolRegistry) {
        self.id = def.id
        self.name = def.metadata.name
        self.description = def.metadata.description
        self.icon = def.metadata.icon
        self.samplePrompt = def.metadata.examples.first?.query ?? ""
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
    var samplePrompt: String = ""
}
