import Foundation

// MARK: - Prompt Observation
//
// 每轮推理的诊断快照 + 环形缓冲。用于 debug dump 和 prompt pipeline
// 调优。不影响推理行为，纯可观测性基础设施。

struct HotfixTurnObservation: Codable, Equatable {
    let prompt_shape: String
    let session_group: String
    let session_reset_reason: String
    let estimated_prompt_tokens: Int
    let reserved_output_tokens: Int
    let history_messages_included: Int
    let history_chars_included: Int
    let kv_prefill_tokens: Int
    let preflight_hard_reject: Bool
    let timestamp_ms: Int64
}

struct HotfixTurnObservationRingBuffer {
    private(set) var items: [HotfixTurnObservation] = []
    private let capacity = 10

    mutating func append(_ item: HotfixTurnObservation) {
        items.append(item)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    func recent(_ count: Int) -> ArraySlice<HotfixTurnObservation> {
        items.suffix(count)
    }
}

extension HotfixTurnObservation {
    func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

extension PromptPlan {
    var sessionResetReason: SessionResetReason {
        switch reuseDecision {
        case .reuse:
            return .normalContinuation
        case .reset(let reason):
            return reason
        }
    }
}
