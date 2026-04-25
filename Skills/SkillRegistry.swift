import Foundation

// MARK: - Skill Registry (有状态: 注册/查询/启用/保存)
//
// 对称 ToolRegistry。持有 [id: SkillDefinition], 提供注册制 API。
// 解析和 bundle 读取由无状态的 SkillLoader (SkillLoader.swift) 提供。

class SkillRegistry {
    private static var didLogSuccessfulValidation = false

    private static let skillAliases: [String: String] = [
        "contacts_delete": "contacts",
        "contacts-delete": "contacts"
    ]

    /// 用户编辑的 override 目录 (runtime 可写)
    let overridesDirectory: URL

    /// Registry: skill id -> SkillDefinition
    private var skills: [String: SkillDefinition] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.overridesDirectory = appSupport.appendingPathComponent("PhoneClaw/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: overridesDirectory, withIntermediateDirectories: true)
        registerBuiltInSkills()
    }

    // MARK: - 公开 API

    /// 返回所有已注册的 skill。
    /// 名字沿用 discoverSkills() 以保持向后兼容, 实际是 "all registered"。
    func discoverSkills() -> [SkillDefinition] {
        Array(skills.values).sorted { $0.id < $1.id }
    }

    /// 返回 skill body (register 时已解析, 直接从 cache 返回)
    func loadBody(skillId: String) -> String? {
        let id = canonicalSkillId(for: skillId)
        return skills[id]?.body
    }

    /// 用户保存 SKILL.md。写到 override 目录, 重新 parse 并更新 registry。
    func saveSkill(skillId: String, content: String) throws {
        let dir = overridesDirectory.appendingPathComponent(skillId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        // 重新 parse 并更新 registry (保持原 isEnabled)
        if var def = SkillLoader.parseDefinition(id: skillId, content: content, filePath: file) {
            if let existing = skills[skillId] {
                def.isEnabled = existing.isEnabled
            }
            skills[skillId] = def
        }
    }

    /// 重载所有 (清空 registry 并重新注册)
    func reloadAll() -> [SkillDefinition] {
        skills.removeAll()
        registerBuiltInSkills()
        return discoverSkills()
    }

    /// 根据工具名反查 skill id
    func findSkillId(forTool toolName: String) -> String? {
        for (id, def) in skills where def.metadata.allowedTools.contains(toolName) {
            return id
        }
        return nil
    }

    /// 获取注册的 SkillDefinition
    func getDefinition(_ skillId: String) -> SkillDefinition? {
        skills[canonicalSkillId(for: skillId)]
    }

    /// 更新启用状态
    func setEnabled(_ skillId: String, enabled: Bool) {
        skills[canonicalSkillId(for: skillId)]?.isEnabled = enabled
    }

    /// 别名归一化 (例如 "contacts_delete" -> "contacts")
    func canonicalSkillId(for skillId: String) -> String {
        Self.skillAliases[skillId] ?? skillId
    }

    // MARK: - 注册 API (core)

    /// 核心注册 API。传入一个 SkillDefinition 就注册进 registry。
    ///
    /// 来源无感知: bundle / 下载 / import / in-app 创建 都走同一个入口。
    /// 未来支持运行时动态添加 skill 时, caller 构造 SkillDefinition 后直接调用。
    func register(_ definition: SkillDefinition) {
        skills[definition.id] = definition
    }

    // MARK: - Built-in 注册 (从 bundle)

    /// 注册一个内置 skill: 优先用户 override, 否则从 bundle 加载。
    private func registerBuiltIn(id: String) {
        // 1. 优先 override
        let overrideFile = overridesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("SKILL.md")

        if FileManager.default.fileExists(atPath: overrideFile.path),
           let def = SkillLoader.loadFromFile(id: id, url: overrideFile) {
            register(def)
            return
        }

        // 2. 从 bundle 读取
        if let def = SkillLoader.loadFromBundle(id: id) {
            register(def)
        }
    }

    /// Built-in skill 注册列表。对称 ToolRegistry.registerBuiltInTools 的模式:
    /// 显式声明要启用什么, 数据在 SKILL.md, 这里只是"加这一行让它被加载"。
    ///
    /// 加新内置 skill 的流程:
    ///   1. 在 `Skills/Library/<new-id>/` 创建 SKILL.md
    ///   2. 在 Xcode 里把 Library/<new-id>/ 加进 PhoneClaw target (bundle)
    ///   3. 在下面加一行 `registerBuiltIn(id: "<new-id>")`
    private func registerBuiltInSkills() {
        registerBuiltIn(id: "clipboard")
        registerBuiltIn(id: "calendar")
        registerBuiltIn(id: "reminders")
        registerBuiltIn(id: "contacts")
        registerBuiltIn(id: "translate")
        registerBuiltIn(id: "health")

        validateRegisteredSkills()
    }

    // MARK: - Load-time validation
    //
    // 校验所有 SKILL.md 的 `allowed-tools` 字段引用的 tool 名都真实存在于
    // ToolRegistry。SKILL.md 是手工维护的 frontmatter, 没有编译时检查;
    // 这里在启动时一次性 cross-check, 写错的 tool 名会立刻在控制台暴露,
    // 而不是等运行时模型 emit tool_call 然后被 cage 静默丢弃。
    //
    // 这是 ToolRegistry "白名单"角色的另一个体现: 不只在运行时丢弃非法
    // 调用, 也在加载时拒绝非法引用。

    private func validateRegisteredSkills() {
        let registry = ToolRegistry.shared
        var hadError = false
        for (id, def) in skills {
            for toolName in def.metadata.allowedTools {
                if registry.find(name: toolName) == nil {
                    print("[SkillRegistry] ⚠️ skill '\(id)' 的 allowed-tools 引用了未注册的工具 '\(toolName)'")
                    hadError = true
                }
            }
        }
        if !hadError && !Self.didLogSuccessfulValidation {
            Self.didLogSuccessfulValidation = true
            print("[SkillRegistry] ✓ 所有 \(skills.count) 个 skill 的 allowed-tools 校验通过")
        }
    }
}
