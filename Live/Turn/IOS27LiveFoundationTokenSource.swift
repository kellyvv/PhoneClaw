import Foundation
import CoreImage

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - IOS27LiveFoundationTokenSource
//
// FoundationModels 档位 A token 源 — 系统模型读与本地模型**完全相同**的 turnPrompt
// (含 LiveSkillRuntime 拼好的 LIVE_SKILL_CONTRACT), 按 contract 输出 <tool_call>
// 文本或 ✓ 追问。输出原样喂回 LiveOutputParser, 下游 normalize → validate →
// ToolRegistry 收口与本地路径同一条, 这里只是另一张"念 contract 的嘴"。
//
// 选它的动机: FM 推理在系统进程执行, 不占本 app 的 GPU/Metal 配额, 后台轮次
// 不受 background GPU 限制; 也不碰本地 live conversation 的 KV。
//
// instructions 只写协议级约束, 不含任何领域词/skill 名 — skill 语义全部由
// turnPrompt 里的 contract (SKILL.md 驱动) 提供, 不引入第二套理解逻辑。

final class IOS27LiveFoundationTokenSource: LiveTurnTokenSource {

    var sourceName: String { "foundation" }

    var isUsable: Bool {
        guard HotfixFeatureFlags.enableLiveFoundationTokenSource else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    private let lock = NSLock()
    private var activeTask: Task<Void, Never>?

    func stream(turnPrompt: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        guard images.isEmpty else {
            return AsyncThrowingStream {
                $0.finish(throwing: LiveTokenSourceError.unsupportedInput("foundation source takes no images"))
            }
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 26.0, *) {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let text = try await IOS27LiveFoundationRuntime.generate(turnPrompt: turnPrompt)
                        if !Task.isCancelled {
                            continuation.yield(text)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                lock.lock()
                activeTask = task
                lock.unlock()
            }
        }
        #endif

        return AsyncThrowingStream {
            $0.finish(throwing: LiveTokenSourceError.unavailable)
        }
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        activeTask = nil
        lock.unlock()
        task?.cancel()
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 26.0, *)
private enum IOS27LiveFoundationRuntime {
    static func generate(turnPrompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw LiveTokenSourceError.unavailable
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        let options: GenerationOptions
        if #available(iOS 27.0, macOS 27.0, *) {
            options = GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: 256,
                toolCallingMode: .disallowed
            )
        } else {
            options = GenerationOptions(
                samplingMode: .greedy,
                maximumResponseTokens: 256
            )
        }

        let response = try await session.respond(to: turnPrompt, options: options)
        if #available(iOS 27.0, macOS 27.0, *) {
            print(
                "[LiveTokenSource] foundation usage input=\(response.usage.input.totalTokenCount) " +
                "output=\(response.usage.output.totalTokenCount)"
            )
        }
        return response.content
    }

    /// 协议级指令 — 与 LiveLocale 系统提示中的 tool_call 规则一致, 零领域词。
    /// 强偏向 tool_call: 小模型容易把 contract 里的示例占位符当"期望值形态"而反复追问
    /// (真机日志: 用户已给出口语化参数仍被要求"提供具体关键词"), 这里明确禁止。
    private static let instructions = """
    You are the structured skill executor inside PhoneClaw LIVE voice mode.
    The user message embeds a LIVE_SKILL_CONTRACT block that defines the allowed tools and their JSON schema; a recent-conversation block may precede it for context.
    Obey that contract exactly. You may produce only one of two outputs:
    1. Exactly one complete <tool_call>{"name":"...","arguments":{...}}</tool_call>, with no other text before or after it.
    2. Only when a required argument value is truly absent and cannot be inferred, one short follow-up question starting with "✓", in the same language as the user, with no tool call.
    Strongly prefer output 1. Derive argument values directly from the user's words and the recent conversation — the user's own phrasing is a valid argument value. Never ask the user to rephrase, shorten, or reformat what they already said. Example values shown inside the contract are format placeholders, not values to request from the user.
    Never invent tool names or arguments outside the contract.
    """
}
#endif
