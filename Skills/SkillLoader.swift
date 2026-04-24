import Foundation
import Yams
// MARK: - SKILL.md 解析 + Skill Registry
//
// 拆分 (对称 ToolRegistry):
//   - SkillLoader  : 无状态, 纯解析 + bundle 读取 (static helpers)
//   - SkillRegistry: 有状态, 持有 [id: SkillDefinition], 提供注册/查询/启用/保存
//
// 注册制架构:
//   - Skills 在 app 启动时显式 register, 不再扫描文件系统
//   - Built-in skills 从 Bundle.main/Library/<id>/SKILL.md 读取
//   - 用户编辑 -> saveSkill 写 Application Support/skills/<id>/SKILL.md
//     作为 override; 下次启动注册时优先使用 override (读不到才回 bundle)
//   - 未来 download / import / in-app 创建 复用同一个 register API
//     (给出 SkillDefinition 即可, 内容来源无感知)

// MARK: - 数据模型

struct SkillExample {
    let query: String
    let scenario: String
}

/// Skill 类别。决定 system prompt 给模型的调用规则。
///
/// - device : 访问 iPhone 硬件或系统数据 (clipboard/calendar/contacts/...).
///            只有当用户明确要求执行设备操作时才 load_skill。
///            含糊词不触发, 闲聊不触发。
/// - content: 对文本做变换 (translate/summarize/rewrite/...).
///            只要用户意图是该类操作就立即 load_skill, 包括"翻译这段"
///            这种带指代词的请求 (skill body 会指导从历史定位源文本)。
enum SkillType: String, Sendable {
    case device
    case content
}

struct SkillMetadata {
    let id: String              // 目录名 "clipboard"
    let name: String            // 默认英文名 / 回退显示名
    let localizedNameZh: String?
    let description: String
    let version: String
    let icon: String
    let disabled: Bool
    let type: SkillType         // 类别 (frontmatter `type:` 必填, 缺省视为 .device)
    let requiresTimeAnchor: Bool
    let triggers: [String]
    let allowedTools: [String]
    let examples: [SkillExample]
    /// 欢迎页快捷 chip 的发送内容. 来源 SKILL.md 的 `chip_prompt` 字段 (可选).
    /// 不声明的 skill 不会出现在 chip 列表里.
    let chipPrompt: String?

    /// 欢迎页快捷 chip 的 UI 显示短 label. 来源 SKILL.md 的 `chip_label` 字段 (可选).
    /// 缺省时 UI 直接显示 chipPrompt 全文 (向后兼容旧 skill).
    /// Decoupled 设计: UI 短 label ("创建日程") + 点击发送长 prompt
    /// ("帮我创建明天下午两点的产品评审会议"), 节约 chip 横向空间, 同时给 LLM 完整意图.
    let chipLabel: String?

    var displayName: String {
        if LanguageService.shared.current.isChinese,
           let localizedNameZh,
           !localizedNameZh.isEmpty {
            return localizedNameZh
        }
        return name
    }
}

struct SkillDefinition: Identifiable {
    let id: String
    let filePath: URL           // 内容来源 URL (bundle 或 override)
    let metadata: SkillMetadata
    var body: String?           // Markdown body (register 时已解析填充)
    var isEnabled: Bool

    /// 完整的 SKILL.md 原始内容
    var rawContent: String? {
        try? String(contentsOf: filePath, encoding: .utf8)
    }
}

// MARK: - Skill Loader (无状态: 解析 + bundle 读取)
//
// 有状态的注册表见 SkillRegistry.swift。

enum SkillLoader {

    /// 从 Bundle.main/Library/<id>/SKILL.md 读取并解析为 SkillDefinition
    ///
    /// 语言选择:
    ///   - 英文 locale 先找 `SKILL.en.md`, 找不到 fallback 回 `SKILL.md`
    ///   - 中文 locale 直接 `SKILL.md`
    ///   - 这样增量: skill 作者可以先只维护 zh, 后续陆续加 en 版
    ///
    /// 注: 不用 `Bundle.main.url(forResource:withExtension:subdirectory:)` —
    /// 该 API 在多点文件名 ("SKILL.en.md") 上行为不稳 (会把 `.en` 当 extension,
    /// 真机拿不到 URL). 改用手动拼接 `bundleURL + "Library/<id>/SKILL.en.md"`
    /// 然后 FileManager 检查存在性, 这条路径在 iOS 真机 / simulator 都一致。
    static func loadFromBundle(id: String) -> SkillDefinition? {
        let libraryURL = Bundle.main.bundleURL.appendingPathComponent("Library/\(id)", isDirectory: true)

        let candidateFile: URL = {
            if LanguageService.shared.current.isEnglish {
                let enURL = libraryURL.appendingPathComponent("SKILL.en.md")
                if FileManager.default.fileExists(atPath: enURL.path) {
                    return enURL
                }
            }
            return libraryURL.appendingPathComponent("SKILL.md")
        }()

        guard FileManager.default.fileExists(atPath: candidateFile.path) else {
            print("[SkillLoader] skill '\(id)' 未找到: \(candidateFile.path)")
            return nil
        }
        guard let content = try? String(contentsOf: candidateFile, encoding: .utf8) else {
            print("[SkillLoader] skill '\(id)' 读取失败")
            return nil
        }
        return parseDefinition(id: id, content: content, filePath: candidateFile)
    }

    /// 从任意 URL 读取并解析
    static func loadFromFile(id: String, url: URL) -> SkillDefinition? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseDefinition(id: id, content: content, filePath: url)
    }

    /// 解析 SKILL.md 文本为 SkillDefinition
    static func parseDefinition(id: String, content: String, filePath: URL) -> SkillDefinition? {
        guard let frontmatter = parseFrontmatter(content) else { return nil }

        let typeRaw = (frontmatter["type"] as? String)?.lowercased() ?? "device"
        let type = SkillType(rawValue: typeRaw) ?? .device

        let metadata = SkillMetadata(
            id: id,
            name: frontmatter["name"] as? String ?? id,
            localizedNameZh: frontmatter["name-zh"] as? String,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            icon: frontmatter["icon"] as? String ?? "wrench",
            disabled: frontmatter["disabled"] as? Bool ?? false,
            type: type,
            requiresTimeAnchor: frontmatter["requires-time-anchor"] as? Bool ?? false,
            triggers: frontmatter["triggers"] as? [String] ?? [],
            allowedTools: frontmatter["allowed-tools"] as? [String] ?? [],
            examples: parseExamples(frontmatter["examples"]),
            chipPrompt: (frontmatter["chip_prompt"] as? String)?.trimmingCharacters(in: .whitespaces),
            chipLabel: (frontmatter["chip_label"] as? String)?.trimmingCharacters(in: .whitespaces)
        )

        return SkillDefinition(
            id: id,
            filePath: filePath,
            metadata: metadata,
            body: parseBody(content),
            isEnabled: !metadata.disabled
        )
    }

    // MARK: - 解析 helpers

    private static func parseFrontmatter(_ content: String) -> [String: Any]? {
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n(.*?)\\n---\\s*\\n",
            options: .dotMatchesLineSeparators
        ) else { return nil }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let yamlRange = Range(match.range(at: 1), in: content) else { return nil }

        let yamlString = String(content[yamlRange])
        guard let parsed = try? Yams.load(yaml: yamlString) as? [String: Any] else { return nil }
        return parsed
    }

    private static func parseBody(_ content: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n.*?\\n---\\s*\\n(.*)$",
            options: .dotMatchesLineSeparators
        ) else { return content }

        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range),
           let bodyRange = Range(match.range(at: 1), in: content) {
            return String(content[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseExamples(_ raw: Any?) -> [SkillExample] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let query = dict["query"] as? String,
                  let scenario = dict["scenario"] as? String else { return nil }
            return SkillExample(query: query, scenario: scenario)
        }
    }
}
