import UIKit
import Foundation

// MARK: - 原生工具注册表
//
// 所有原生 API 封装集中注册在这里。
// SKILL.md 通过 allowed-tools 字段引用工具名。

struct RegisteredTool {
    let name: String
    let description: String
    let parameters: String
    let execute: ([String: Any]) async throws -> String
}

class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: RegisteredTool] = [:]

    init() {
        registerBuiltInTools()
    }

    // MARK: - 公开接口

    func register(_ tool: RegisteredTool) {
        tools[tool.name] = tool
    }

    func find(name: String) -> RegisteredTool? {
        tools[name]
    }

    func execute(name: String, args: [String: Any]) async throws -> String {
        guard let tool = tools[name] else {
            return "{\"success\": false, \"error\": \"未知工具: \(name)\"}"
        }
        return try await tool.execute(args)
    }

    /// 根据名称列表获取工具（用于 SKILL.md 的 allowed-tools）
    func toolsFor(names: [String]) -> [RegisteredTool] {
        names.compactMap { tools[$0] }
    }

    /// 根据工具名反查：它属于哪些 allowed-tools 列表
    /// 返回 true 如果该工具已注册
    func hasToolNamed(_ name: String) -> Bool {
        tools[name] != nil
    }

    /// 所有已注册的工具名
    var allToolNames: [String] {
        Array(tools.keys).sorted()
    }

    // MARK: - 内置工具注册

    private func registerBuiltInTools() {
        func officialDevicePayload() async -> [String: Any] {
            let info = ProcessInfo.processInfo
            let device = await MainActor.run {
                (
                    UIDevice.current.name,
                    UIDevice.current.model,
                    UIDevice.current.localizedModel,
                    UIDevice.current.systemName,
                    UIDevice.current.systemVersion,
                    UIDevice.current.identifierForVendor?.uuidString
                )
            }

            var payload: [String: Any] = [
                "success": true,
                "name": device.0,
                "model": device.1,
                "localized_model": device.2,
                "system_name": device.3,
                "system_version": device.4,
                "memory_bytes": Double(info.physicalMemory),
                "memory_gb": Double(info.physicalMemory) / 1_073_741_824.0,
                "processor_count": info.processorCount
            ]

            if let identifierForVendor = device.5, !identifierForVendor.isEmpty {
                payload["identifier_for_vendor"] = identifierForVendor
            }

            return payload
        }

        // ── Clipboard ──
        register(RegisteredTool(
            name: "clipboard-read",
            description: "读取剪贴板当前内容",
            parameters: "无"
        ) { _ in
            let content = await MainActor.run { UIPasteboard.general.string }
            if let raw = content, !raw.isEmpty {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return "{\"success\": false, \"error\": \"剪贴板为空\"}" }
                return "{\"success\": true, \"type\": \"text\", \"content\": \"\(jsonEscape(String(text.prefix(500))))\", \"length\": \(text.count)}"
            }
            return "{\"success\": false, \"error\": \"剪贴板为空\"}"
        })

        register(RegisteredTool(
            name: "clipboard-write",
            description: "将文本写入剪贴板",
            parameters: "text: 要复制的文本内容"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return "{\"success\": true, \"copied_length\": \(text.count)}"
        })

        // ── Device ──
        register(RegisteredTool(
            name: "device-info",
            description: "使用 iOS 官方公开 API 汇总获取当前设备名称、设备类型、系统版本、内存和处理器数量",
            parameters: "无"
        ) { _ in
            jsonString(await officialDevicePayload())
        })

        register(RegisteredTool(
            name: "device-name",
            description: "使用 UIDevice.current.name 获取当前设备名称",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "name": payload["name"] as? String ?? ""
            ])
        })

        register(RegisteredTool(
            name: "device-model",
            description: "使用 UIDevice.current.model 和 localizedModel 获取当前设备类型",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "model": payload["model"] as? String ?? "",
                "localized_model": payload["localized_model"] as? String ?? ""
            ])
        })

        register(RegisteredTool(
            name: "device-system-version",
            description: "使用 UIDevice.current.systemName 和 systemVersion 获取系统版本",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "system_name": payload["system_name"] as? String ?? "",
                "system_version": payload["system_version"] as? String ?? ""
            ])
        })

        register(RegisteredTool(
            name: "device-memory",
            description: "使用 ProcessInfo.processInfo.physicalMemory 获取设备物理内存",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "memory_bytes": payload["memory_bytes"] as? Double ?? 0,
                "memory_gb": payload["memory_gb"] as? Double ?? 0
            ])
        })

        register(RegisteredTool(
            name: "device-processor-count",
            description: "使用 ProcessInfo.processInfo.processorCount 获取处理器核心数",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "processor_count": payload["processor_count"] as? Int ?? 0
            ])
        })

        register(RegisteredTool(
            name: "device-identifier-for-vendor",
            description: "使用 UIDevice.current.identifierForVendor 获取当前 App 在该设备上的 vendor 标识",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            return jsonString([
                "success": true,
                "identifier_for_vendor": payload["identifier_for_vendor"] as? String ?? ""
            ])
        })

        // ── Text ──
        register(RegisteredTool(
            name: "calculate-hash",
            description: "计算文本的哈希值",
            parameters: "text: 要计算哈希的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            let hash = text.hashValue
            return "{\"success\": true, \"input\": \"\(jsonEscape(text))\", \"hash\": \(hash)}"
        })

        register(RegisteredTool(
            name: "text-reverse",
            description: "翻转文本",
            parameters: "text: 要翻转的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return "{\"success\": false, \"error\": \"缺少 text 参数\"}"
            }
            let reversed = String(text.reversed())
            return "{\"success\": true, \"original\": \"\(jsonEscape(text))\", \"reversed\": \"\(jsonEscape(reversed))\"}"
        })
    }
}

// MARK: - Helpers

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"success\": false, \"error\": \"JSON 编码失败\"}"
    }
    return string
}
