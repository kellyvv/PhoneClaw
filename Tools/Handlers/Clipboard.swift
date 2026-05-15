#if canImport(UIKit)
import UIKit

enum ClipboardTools {

    static func register(into registry: ToolRegistry) {

        // ── clipboard-read ──
        let readTool = RegisteredTool(
            name: "clipboard-read",
            description: tr("读取剪贴板当前内容", "Read the current clipboard contents"),
            parameters: tr("无", "None"),
            isParameterless: true,
            skipFollowUp: true,
            execute: { _ in
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
                return canonicalReadResult(from: snapshot).detail
            },
            executeCanonical: { _ in
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
                return canonicalReadResult(from: snapshot)
            }
        )
        registry.register(readTool)

        // ── clipboard-write ──
        let writeTool = RegisteredTool(
            name: "clipboard-write",
            description: tr("将文本写入剪贴板", "Write text to the clipboard"),
            parameters: tr("text: 要复制的文本内容", "text: The text content to copy"),
            requiredParameters: ["text"],
            skipFollowUp: true,
            execute: { args in
                guard let text = args["text"] as? String else {
                    return failurePayload(error: tr("缺少 text 参数", "Missing text parameter"))
                }
                await MainActor.run { UIPasteboard.general.string = text }
                return canonicalWriteResult(text: text).detail
            },
            executeCanonical: { args in
                guard let text = args["text"] as? String else {
                    return canonicalToolResult(
                        toolName: "clipboard-write",
                        toolResult: failurePayload(error: tr("缺少 text 参数", "Missing text parameter"))
                    )
                }
                await MainActor.run { UIPasteboard.general.string = text }
                return canonicalWriteResult(text: text)
            }
        )
        registry.register(writeTool)
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

    private static func canonicalReadResult(from snapshot: [String: Any]) -> CanonicalToolResult {
        switch snapshot["kind"] as? String {
        case "text":
            let preview = snapshot["content"] as? String ?? ""
            let truncated = snapshot["truncated"] as? Bool ?? false
            let suffix = truncated
                ? tr("（内容较长，已截断显示）", " (content is long; truncated)")
                : ""
            let summary = tr(
                "剪贴板里是：\(preview)\(suffix)",
                "Clipboard: \(preview)\(suffix)"
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "type": "text",
                    "content": preview,
                    "truncated": truncated
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "url":
            let preview = snapshot["content"] as? String ?? ""
            let truncated = snapshot["truncated"] as? Bool ?? false
            let suffix = truncated
                ? tr("（内容较长，已截断显示）", " (content is long; truncated)")
                : ""
            let summary = tr(
                "剪贴板里是这个链接：\(preview)\(suffix)",
                "Clipboard URL: \(preview)\(suffix)"
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "type": "url",
                    "content": preview,
                    "truncated": truncated
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "image":
            let itemCount = snapshot["item_count"] as? Int ?? 1
            let summary = tr(
                "剪贴板里是一张图片，暂时不能直接读取图片内容。",
                "The clipboard contains an image, which cannot be read directly yet."
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "type": "image",
                    "item_count": itemCount
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "unsupported":
            let itemCount = snapshot["item_count"] as? Int ?? 1
            let summary = tr(
                "剪贴板里有 \(itemCount) 项非文本内容，暂时不能直接读取。",
                "The clipboard contains \(itemCount) non-text item(s), which cannot be read directly yet."
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "type": "unsupported",
                    "item_count": itemCount
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        default:
            let summary = tr("剪贴板当前为空。", "The clipboard is currently empty.")
            let detail = successPayload(
                result: summary,
                extras: ["type": "empty"]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }
    }

    private static func canonicalWriteResult(text: String) -> CanonicalToolResult {
        let summary = tr(
            "已复制到剪贴板。",
            "Copied to the clipboard."
        )
        let detail = successPayload(
            result: summary,
            extras: ["copied_length": text.count]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }
}
#elseif canImport(AppKit)
import AppKit

// macOS: NSPasteboard 实现, 跟 iOS UIPasteboard 行为对齐 — 让 CLI harness
// 真的读写系统剪贴板 (写到 macOS 系统剪贴板 / 从系统剪贴板读), 而不是 mock 内存.
// CLI harness 跑 clipboard scenario 现在跟 iOS 真机数据流一致.

enum ClipboardTools {

    static func register(into registry: ToolRegistry) {

        // ── clipboard-read ──
        let readTool = RegisteredTool(
            name: "clipboard-read",
            description: tr("读取剪贴板当前内容", "Read the current clipboard contents"),
            parameters: tr("无", "None"),
            isParameterless: true,
            skipFollowUp: true,
            execute: { _ in
                let snapshot = await MainActor.run { () -> [String: Any] in
                    let pb = NSPasteboard.general
                    let types = pb.types ?? []

                    if types.isEmpty {
                        return ["kind": "empty"]
                    }

                    if types.contains(.tiff) || types.contains(.png) {
                        return ["kind": "image", "item_count": pb.pasteboardItems?.count ?? 1]
                    }

                    if types.contains(.URL),
                       let urlString = pb.string(forType: .URL),
                       let preview = textPreview(from: urlString, maxCharacters: 500) {
                        return [
                            "kind": "url",
                            "content": preview.preview,
                            "truncated": preview.truncated
                        ]
                    }

                    if let raw = pb.string(forType: .string),
                       let preview = textPreview(from: raw, maxCharacters: 500) {
                        return [
                            "kind": "text",
                            "content": preview.preview,
                            "truncated": preview.truncated
                        ]
                    }

                    return ["kind": "unsupported", "item_count": pb.pasteboardItems?.count ?? 1]
                }
                return canonicalReadResult(from: snapshot).detail
            },
            executeCanonical: { _ in
                let snapshot = await MainActor.run { () -> [String: Any] in
                    let pb = NSPasteboard.general
                    let types = pb.types ?? []

                    if types.isEmpty {
                        return ["kind": "empty"]
                    }

                    if types.contains(.tiff) || types.contains(.png) {
                        return ["kind": "image", "item_count": pb.pasteboardItems?.count ?? 1]
                    }

                    if types.contains(.URL),
                       let urlString = pb.string(forType: .URL),
                       let preview = textPreview(from: urlString, maxCharacters: 500) {
                        return [
                            "kind": "url",
                            "content": preview.preview,
                            "truncated": preview.truncated
                        ]
                    }

                    if let raw = pb.string(forType: .string),
                       let preview = textPreview(from: raw, maxCharacters: 500) {
                        return [
                            "kind": "text",
                            "content": preview.preview,
                            "truncated": preview.truncated
                        ]
                    }

                    return ["kind": "unsupported", "item_count": pb.pasteboardItems?.count ?? 1]
                }
                return canonicalReadResult(from: snapshot)
            }
        )
        registry.register(readTool)

        // ── clipboard-write ──
        let writeTool = RegisteredTool(
            name: "clipboard-write",
            description: tr("将文本写入剪贴板", "Write text to the clipboard"),
            parameters: tr("text: 要复制的文本内容", "text: The text content to copy"),
            requiredParameters: ["text"],
            skipFollowUp: true,
            execute: { args in
                guard let text = args["text"] as? String else {
                    return failurePayload(error: tr("缺少 text 参数", "Missing text parameter"))
                }
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
                return canonicalWriteResult(text: text).detail
            },
            executeCanonical: { args in
                guard let text = args["text"] as? String else {
                    return canonicalToolResult(
                        toolName: "clipboard-write",
                        toolResult: failurePayload(error: tr("缺少 text 参数", "Missing text parameter"))
                    )
                }
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
                return canonicalWriteResult(text: text)
            }
        )
        registry.register(writeTool)
    }

    private static func textPreview(
        from text: String,
        maxCharacters: Int = 500
    ) -> (preview: String, truncated: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let endIndex = trimmed.index(
            trimmed.startIndex, offsetBy: maxCharacters, limitedBy: trimmed.endIndex
        ) ?? trimmed.endIndex
        return (preview: String(trimmed[..<endIndex]), truncated: endIndex < trimmed.endIndex)
    }

    private static func canonicalReadResult(from snapshot: [String: Any]) -> CanonicalToolResult {
        switch snapshot["kind"] as? String {
        case "text":
            let preview = snapshot["content"] as? String ?? ""
            let truncated = snapshot["truncated"] as? Bool ?? false
            let suffix = truncated
                ? tr("（内容较长，已截断显示）", " (content is long; truncated)")
                : ""
            let summary = tr(
                "剪贴板里是：\(preview)\(suffix)",
                "Clipboard: \(preview)\(suffix)"
            )
            let detail = successPayload(
                result: summary,
                extras: ["type": "text", "content": preview, "truncated": truncated]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "url":
            let preview = snapshot["content"] as? String ?? ""
            let truncated = snapshot["truncated"] as? Bool ?? false
            let suffix = truncated
                ? tr("（内容较长，已截断显示）", " (content is long; truncated)")
                : ""
            let summary = tr(
                "剪贴板里是这个链接：\(preview)\(suffix)",
                "Clipboard URL: \(preview)\(suffix)"
            )
            let detail = successPayload(
                result: summary,
                extras: ["type": "url", "content": preview, "truncated": truncated]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "image":
            let itemCount = snapshot["item_count"] as? Int ?? 1
            let summary = tr(
                "剪贴板里是一张图片，暂时不能直接读取图片内容。",
                "The clipboard contains an image, which cannot be read directly yet."
            )
            let detail = successPayload(
                result: summary,
                extras: ["type": "image", "item_count": itemCount]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        case "unsupported":
            let itemCount = snapshot["item_count"] as? Int ?? 1
            let summary = tr(
                "剪贴板里有 \(itemCount) 项非文本内容，暂时不能直接读取。",
                "The clipboard contains \(itemCount) non-text item(s), which cannot be read directly yet."
            )
            let detail = successPayload(
                result: summary,
                extras: ["type": "unsupported", "item_count": itemCount]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)

        default:
            let summary = tr("剪贴板当前为空。", "The clipboard is currently empty.")
            let detail = successPayload(
                result: summary,
                extras: ["type": "empty"]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }
    }

    private static func canonicalWriteResult(text: String) -> CanonicalToolResult {
        let summary = tr(
            "已复制到剪贴板。",
            "Copied to the clipboard."
        )
        let detail = successPayload(
            result: summary,
            extras: ["copied_length": text.count]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }
}
#else
// 既无 UIKit 也无 AppKit (理论上不会发生) — no-op stub
enum ClipboardTools {
    static func register(into registry: ToolRegistry) {}
}
#endif
