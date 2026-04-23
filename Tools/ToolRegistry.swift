import Foundation

// MARK: - 原生工具注册表
//
// 所有原生 API 封装集中注册在这里。
// SKILL.md 通过 allowed-tools 字段引用工具名。

struct RegisteredTool {
    let name: String
    let description: String
    let parameters: String

    /// 必填参数名列表，用于泛化参数校验（替代 per-tool switch）。
    /// 空数组表示无参数或无需强制校验。
    let requiredParameters: [String]

    /// 至少要提供其中一个参数名；用于表达 search/delete 这类"多选一"契约。
    let requiredAnyOfParameters: [String]

    /// 该工具名的别名（纯格式层面），用于泛化 canonicalToolName。
    /// 例如 ["contacts_delete", "contacts-delete-contact"]
    let aliases: [String]

    /// 该工具是否完全无参，可直接执行。
    let isParameterless: Bool

    /// 如果为 true，工具执行后直接使用 result 字段作为最终回答，不再走 LLM follow-up。
    let skipFollowUp: Bool

    let execute: ([String: Any]) async throws -> String
    let executeCanonical: (([String: Any]) async throws -> CanonicalToolResult)?

    init(
        name: String,
        description: String,
        parameters: String,
        requiredParameters: [String] = [],
        requiredAnyOfParameters: [String] = [],
        aliases: [String] = [],
        isParameterless: Bool = false,
        skipFollowUp: Bool = false,
        execute: @escaping ([String: Any]) async throws -> String,
        executeCanonical: (([String: Any]) async throws -> CanonicalToolResult)? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiredParameters = requiredParameters
        self.requiredAnyOfParameters = requiredAnyOfParameters
        self.aliases = aliases
        self.isParameterless = isParameterless
        self.skipFollowUp = skipFollowUp
        self.execute = execute
        self.executeCanonical = executeCanonical
    }

    func validates(arguments: [String: Any]) -> Bool {
        if isParameterless {
            return arguments.isEmpty
        }

        for parameter in requiredParameters {
            guard Self.hasMeaningfulValue(arguments[parameter]) else {
                return false
            }
        }

        if !requiredAnyOfParameters.isEmpty,
           !requiredAnyOfParameters.contains(where: { Self.hasMeaningfulValue(arguments[$0]) }) {
            return false
        }

        return true
    }

    private static func hasMeaningfulValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        case nil:
            return false
        default:
            return true
        }
    }
}

class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: RegisteredTool] = [:]
    /// alias → canonical tool name
    private var aliasIndex: [String: String] = [:]

    private init() {
        registerBuiltInTools()
    }

    // MARK: - 公开接口

    func register(_ tool: RegisteredTool) {
        tools[tool.name] = tool
        for alias in tool.aliases {
            aliasIndex[alias] = tool.name
        }
    }

    func find(name: String) -> RegisteredTool? {
        if let tool = tools[name] {
            return tool
        }
        if let resolved = canonicalName(for: name) {
            return tools[resolved]
        }
        return nil
    }

    func execute(name: String, args: [String: Any]) async throws -> String {
        guard let tool = find(name: name) else {
            return "{\"success\": false, \"error\": \"未知工具: \(name)\"}"
        }
        return try await tool.execute(args)
    }

    func executeCanonical(name: String, args: [String: Any]) async throws -> CanonicalToolResult {
        guard let tool = find(name: name) else {
            let payload = failurePayload(error: "未知工具: \(name)")
            return canonicalToolResult(toolName: name, toolResult: payload)
        }

        if let executeCanonical = tool.executeCanonical {
            return try await executeCanonical(args)
        }

        let toolResult = try await tool.execute(args)
        return canonicalToolResult(toolName: tool.name, toolResult: toolResult)
    }

    /// 根据名称列表获取工具（用于 SKILL.md 的 allowed-tools）
    func toolsFor(names: [String]) -> [RegisteredTool] {
        names.compactMap { find(name: $0) }
    }

    /// 返回 true 如果该工具已注册
    func hasToolNamed(_ name: String) -> Bool {
        find(name: name) != nil
    }

    /// 所有已注册的工具名
    var allToolNames: [String] {
        Array(tools.keys).sorted()
    }

    // MARK: - 泛化查询（替代 AgentEngine 中的 per-tool switch）

    /// 将别名或格式变体解析为注册的 canonical tool name。
    func canonicalName(for rawName: String) -> String? {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if tools[normalized] != nil { return normalized }
        if let mapped = aliasIndex[normalized] { return mapped }
        return nil
    }

    /// 某个工具的必填参数列表。
    func requiredParams(for toolName: String) -> [String] {
        find(name: toolName)?.requiredParameters ?? []
    }

    /// 某个工具的"至少一个参数"候选列表。
    func requiredAnyOfParams(for toolName: String) -> [String] {
        find(name: toolName)?.requiredAnyOfParameters ?? []
    }

    /// 某个工具是否为无参工具。
    func isParameterlessTool(named toolName: String) -> Bool {
        find(name: toolName)?.isParameterless ?? false
    }

    /// 统一的参数契约校验。
    func validatesArguments(_ arguments: [String: Any], for toolName: String) -> Bool {
        find(name: toolName)?.validates(arguments: arguments) ?? false
    }

    /// 某个工具是否声明了跳过 LLM follow-up。
    func shouldSkipFollowUp(for toolName: String) -> Bool {
        find(name: toolName)?.skipFollowUp ?? false
    }

    // MARK: - 内置工具注册

    private func registerBuiltInTools() {
        ClipboardTools.register(into: self)
        CalendarTools.register(into: self)
        RemindersTools.register(into: self)
        ContactsTools.register(into: self)
        HealthTools.register(into: self)
    }
}
