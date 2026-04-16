#if canImport(UIKit)
import UIKit

enum ClipboardTools {

    static func register(into registry: ToolRegistry) {

        // ── clipboard-read ──
        registry.register(RegisteredTool(
            name: "clipboard-read",
            description: "读取剪贴板当前内容",
            parameters: "无",
            isParameterless: true,
            skipFollowUp: true
        ) { _ in
            let snapshot = await MainActor.run { () -> [String: Any] in
                let pasteboard = UIPasteboard.general

                if pasteboard.numberOfItems == 0 {
                    return ["kind": "empty"]
                }

                if pasteboard.hasImages {
                    return [
                        "kind": "image",
                        "item_count": pasteboard.numberOfItems
                    ]
                }

                if pasteboard.hasURLs,
                   let urlText = pasteboard.url?.absoluteString,
                   let preview = textPreview(from: urlText, maxCharacters: 500) {
                    return [
                        "kind": "url",
                        "content": preview.preview,
                        "truncated": preview.truncated
                    ]
                }

                if pasteboard.hasStrings,
                   let raw = pasteboard.string,
                   let preview = textPreview(from: raw, maxCharacters: 500) {
                    return [
                        "kind": "text",
                        "content": preview.preview,
                        "truncated": preview.truncated
                    ]
                }

                return [
                    "kind": "unsupported",
                    "item_count": pasteboard.numberOfItems
                ]
            }

            switch snapshot["kind"] as? String {
            case "text":
                let preview = snapshot["content"] as? String ?? ""
                let truncated = snapshot["truncated"] as? Bool ?? false
                let suffix = truncated ? "（内容较长，已截断显示）" : ""
                return successPayload(
                    result: "剪贴板当前文本内容是：\(preview)\(suffix)",
                    extras: [
                        "type": "text",
                        "content": preview,
                        "truncated": truncated
                    ]
                )

            case "url":
                let preview = snapshot["content"] as? String ?? ""
                let truncated = snapshot["truncated"] as? Bool ?? false
                let suffix = truncated ? "（内容较长，已截断显示）" : ""
                return successPayload(
                    result: "剪贴板当前是链接：\(preview)\(suffix)",
                    extras: [
                        "type": "url",
                        "content": preview,
                        "truncated": truncated
                    ]
                )

            case "image":
                let itemCount = snapshot["item_count"] as? Int ?? 1
                return successPayload(
                    result: "剪贴板当前是图片内容。为避免额外内存占用，暂不直接解码图片。",
                    extras: [
                        "type": "image",
                        "item_count": itemCount
                    ]
                )

            case "unsupported":
                let itemCount = snapshot["item_count"] as? Int ?? 1
                return successPayload(
                    result: "剪贴板当前包含 \(itemCount) 项非文本内容，暂不直接读取。",
                    extras: [
                        "type": "unsupported",
                        "item_count": itemCount
                    ]
                )

            default:
                return failurePayload(error: "剪贴板为空")
            }
        })

        // ── clipboard-write ──
        registry.register(RegisteredTool(
            name: "clipboard-write",
            description: "将文本写入剪贴板",
            parameters: "text: 要复制的文本内容",
            requiredParameters: ["text"],
            skipFollowUp: true
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return successPayload(
                result: "已写入剪贴板，共 \(text.count) 个字符。",
                extras: ["copied_length": text.count]
            )
        })
    }

    // MARK: - Private Helpers

    private static func textPreview(
        from text: String,
        maxCharacters: Int = 500
    ) -> (preview: String, truncated: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let endIndex = trimmed.index(
            trimmed.startIndex,
            offsetBy: maxCharacters,
            limitedBy: trimmed.endIndex
        ) ?? trimmed.endIndex

        return (
            preview: String(trimmed[..<endIndex]),
            truncated: endIndex < trimmed.endIndex
        )
    }
}
#else
// macOS CLI: UIPasteboard iOS-only, 剪贴板 Skill 不适用. 提供 no-op stub
// 让 ToolRegistry.registerBuiltInTools() 调用点编译通过 (整个 skill 静默跳过).
enum ClipboardTools {
    static func register(into registry: ToolRegistry) {}
}
#endif
