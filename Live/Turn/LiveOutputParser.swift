import Foundation

// MARK: - LiveOutputParser
//
// 增量解析 Live LLM 的 token stream, 把原始文本流切分成:
//   · marker (首个 ✓/○/◐)
//   · speechToken (要 TTS 朗读的正文)
//   · skillCall (tool_call JSON, 架构预留)
//
// 状态机:
//
//   awaitingMarker
//     ├─ 首个非空白 char = ✓  → 吃掉 ✓ + 后续空格, 进入 streamingResponse
//     ├─ 首个非空白 char = ○  → emit marker(.interrupted), 进入 finished
//     ├─ 首个非空白 char = ◐  → emit marker(.thinking),    进入 finished
//     └─ 其它                 → 视作无 marker, 整个流按 speechToken 走
//                               (宽松模式, 兼容模型偶尔忘记 ✓ 的情况)
//
//   streamingResponse
//     ├─ 检测到 "<tool_call>"  → 进入 collectingToolCall, 丢弃标记之前 buffer 里的 "<"
//     └─ 其它                   → emit speechToken(token)
//
//   collectingToolCall
//     └─ 累积到 "</tool_call>"  → 解析 JSON → emit skillCall + 进入 finished
//
//   finished
//     └─ 吞掉剩余 token
//
// 所有 emit 通过 `consume` 的返回数组返回, 调用者 (LiveTurnProcessor) 负责 forward
// 给 AsyncStream. `finish()` 在 stream 结束时调一次, 收尾工作.

final class LiveOutputParser {

    // MARK: - State

    private enum State {
        case awaitingMarker
        case streamingResponse
        case collectingToolCall(buffer: String)
        case finished
    }

    private var state: State = .awaitingMarker
    private var headroomBuffer = ""        // awaitingMarker 阶段累积前几个 token, 直到找到首个非空白
    private var toolCallOpenTag = "<tool_call>"
    private var toolCallCloseTag = "</tool_call>"
    private var streamingTail = ""         // streamingResponse 阶段跨 delta 累积的最后几个字符, 检测 "<tool_call>" 分段出现

    // MARK: - Public

    /// 消费一段 delta, 返回 0..N 个事件.
    /// 调用者负责把事件 forward 到下游 AsyncStream.
    func consume(delta: String) -> [LiveOutputEvent] {
        guard !delta.isEmpty else { return [] }

        switch state {
        case .awaitingMarker:
            return handleAwaitingMarker(delta)
        case .streamingResponse:
            return handleStreamingResponse(delta)
        case .collectingToolCall(let buffer):
            return handleCollectingToolCall(buffer + delta)
        case .finished:
            return []
        }
    }

    /// Stream 结束. Flush 还没决定模式的 headroom (兼容超短回复模型懒得打 marker 的情况).
    func finish() -> [LiveOutputEvent] {
        var events: [LiveOutputEvent] = []

        switch state {
        case .awaitingMarker:
            // 模型没输出任何有意义字符 (或者全是空白). 视作"本轮无回答".
            // 主动 emit 一个 done 让 engine 回到 listening.
            if !headroomBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 极少数: 有内容但没超过 1 字符就结束了, 还没触发状态切换.
                // 宽松: 把它当 speechToken emit.
                events.append(.speechToken(headroomBuffer))
            }

        case .streamingResponse:
            // 可能还有 streamingTail 没 emit (因为我们不确定它是不是 "<tool_call>" 的前缀).
            // stream 结束了, 直接 emit 这尾巴 — 不会再有 tool_call 了.
            if !streamingTail.isEmpty {
                events.append(.speechToken(streamingTail))
                streamingTail = ""
            }

        case .collectingToolCall:
            // tool_call 未闭合就流结束 — 视作 malformed, 不 emit skillCall.
            // MVP 阶段反正不会走到这, 记一下日志即可.
            print("[LiveOutputParser] WARN: stream ended mid tool_call, discarded")

        case .finished:
            break
        }

        state = .finished
        events.append(.done)
        return events
    }

    // MARK: - State handlers

    private func handleAwaitingMarker(_ delta: String) -> [LiveOutputEvent] {
        headroomBuffer += delta

        // 找首个非空白 char
        let trimmed = headroomBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return []   // 还是全空白, 继续等
        }

        let firstStr = String(first)

        // 匹配 marker
        if let marker = LiveMarker(rawValue: firstStr) {
            switch marker {
            case .interrupted, .thinking:
                // 静默退场 — 不 emit 后续任何 speechToken
                state = .finished
                return [.marker(marker), .done]
            case .complete:
                // ✓: 吃掉 ✓ 和紧跟的空格 (system prompt 写的 "✓ 加一个空格再接回答"),
                // 后续 tokens 全部是 speechToken.
                let afterMarker = dropMarkerAndOneSpace(
                    from: headroomBuffer, marker: firstStr
                )
                state = .streamingResponse
                headroomBuffer = ""
                var events: [LiveOutputEvent] = [.marker(.complete)]
                if !afterMarker.isEmpty {
                    events.append(contentsOf: emitAsStream(afterMarker))
                }
                return events
            }
        }

        // 宽松模式: 没 marker, 直接当 speechToken 流处理
        state = .streamingResponse
        let buffered = headroomBuffer
        headroomBuffer = ""
        return emitAsStream(buffered)
    }

    private func handleStreamingResponse(_ delta: String) -> [LiveOutputEvent] {
        return emitAsStream(delta)
    }

    private func handleCollectingToolCall(_ fullBuffer: String) -> [LiveOutputEvent] {
        if let closeRange = fullBuffer.range(of: toolCallCloseTag) {
            // 完整 <tool_call>...</tool_call> 找到了
            let jsonStart = fullBuffer.index(fullBuffer.startIndex, offsetBy: toolCallOpenTag.count)
            let jsonEnd = closeRange.lowerBound
            let jsonString = String(fullBuffer[jsonStart..<jsonEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            state = .finished
            if let call = parseSkillCall(jsonString) {
                return [.skillCall(call), .done]
            } else {
                print("[LiveOutputParser] WARN: malformed tool_call JSON: \(jsonString)")
                return [.done]
            }
        }

        // 还没结束, 继续收
        state = .collectingToolCall(buffer: fullBuffer)
        return []
    }

    // MARK: - Helpers

    /// streamingResponse 下发 speechToken, 但要处理 "<tool_call>" 分段出现的情况.
    /// 策略: 维护一个 streamingTail, 如果 tail + delta 里可能在构成 "<tool_call>" 的前缀,
    /// 暂缓 emit, 等足够判定.
    private func emitAsStream(_ delta: String) -> [LiveOutputEvent] {
        let combined = streamingTail + delta

        if let openRange = combined.range(of: toolCallOpenTag) {
            // 找到完整的 <tool_call> — 之前的部分作为 speechToken emit, 剩下进 collectingToolCall
            let beforeTag = String(combined[..<openRange.lowerBound])
            let fromTag = String(combined[openRange.lowerBound...])
            streamingTail = ""
            state = .collectingToolCall(buffer: fromTag)

            var events: [LiveOutputEvent] = []
            if !beforeTag.isEmpty {
                events.append(.speechToken(beforeTag))
            }
            // 继续处理 fromTag (可能本 delta 里 <tool_call>...</tool_call> 都有了)
            events.append(contentsOf: handleCollectingToolCall(fromTag))
            return events
        }

        // 判断 combined 末尾是否是 "<tool_call>" 的前缀 — 如果是, 留在 tail 里等下个 delta
        let suffixToKeep = pendingTagPrefixLength(in: combined, tag: toolCallOpenTag)
        if suffixToKeep > 0 {
            let splitIndex = combined.index(combined.endIndex, offsetBy: -suffixToKeep)
            let emittable = String(combined[..<splitIndex])
            streamingTail = String(combined[splitIndex...])
            return emittable.isEmpty ? [] : [.speechToken(emittable)]
        }

        // 完全没嫌疑, 全部 emit
        streamingTail = ""
        return [.speechToken(combined)]
    }

    /// 返回 combined 末尾能和 tag 前缀匹配的最长长度. 例如 tag="<tool_call>",
    /// combined=".....<tool" 返回 5. 用于暂缓 emit 防止 tag 被切断到 2 个 delta.
    private func pendingTagPrefixLength(in combined: String, tag: String) -> Int {
        let maxCheck = min(combined.count, tag.count - 1)
        for k in stride(from: maxCheck, to: 0, by: -1) {
            let suffix = combined.suffix(k)
            if tag.hasPrefix(suffix) {
                return k
            }
        }
        return 0
    }

    private func dropMarkerAndOneSpace(from raw: String, marker: String) -> String {
        // raw 是 headroomBuffer, 可能头部有若干空白 + marker + 空格 + 真正 content
        // 只丢掉 marker 和紧跟的 1 个空格, 保留前置空白前的任何东西
        // (实际上 awaitingMarker 阶段前置空白是允许的, 我们已经用 trimmed 找 marker,
        //  这里直接从原串里找 marker 位置, 丢掉 marker 和后一个空格).
        guard let range = raw.range(of: marker) else {
            return raw
        }
        var after = String(raw[range.upperBound...])
        if after.hasPrefix(" ") {
            after.removeFirst()
        }
        return after
    }

    private func parseSkillCall(_ json: String) -> LiveSkillCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else {
            return nil
        }
        let args = (obj["arguments"] as? [String: Any]) ?? [:]
        return LiveSkillCall(name: name, arguments: args)
    }
}
