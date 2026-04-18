import Foundation
import MLXLMCommon

// MARK: - RuntimeBudgets
//
// 纯函数 budget 计算, 零模型 ID 字符串, 零全局状态。
// 输入: ModelRuntimeProfile + headroom + 少量上下文标志。
// 输出: 各类 budget struct。
//
// 文本/思考 budget 现在使用 LinearBudgetFormula 连续公式 (2026-04-08 重构),
// 多模态和 historyDepth 仍走 tier 表 (它们的语义不适合线性化)。

// MARK: - Budget 返回类型

public struct TextBudget: Sendable, Equatable {
    public let maxOutputTokens: Int
    public let headroomMB: Int
}

public struct ThinkingBudget: Sendable, Equatable {
    public let maxOutputTokens: Int
    public let headroomMB: Int
}

public struct MultimodalBudget: Sendable, Equatable {
    public let imageSoftTokenCap: Int?
    public let headroomMB: Int
}

// MARK: - RuntimeBudgets

public enum RuntimeBudgets {

    // MARK: 通用 tier 查表 (仅 historyDepth 用)

    /// 整数离散映射: 找第一个 headroom < tier.headroomMaxMB 的档。
    /// 最后一档通常用 .max 兜底。
    static func lookup(_ tiers: [BudgetTier], headroom: Int) -> Int {
        for tier in tiers where headroom < tier.headroomMaxMB {
            return tier.tokens
        }
        return tiers.last?.tokens ?? 0
    }

    static func lookupMultimodal(_ tiers: [MultimodalTier], headroom: Int) -> MultimodalTier? {
        for tier in tiers where headroom < tier.headroomMaxMB {
            return tier
        }
        return tiers.last
    }

    // MARK: 文本输出 (线性公式)

    public static func text(
        profile: ModelRuntimeProfile,
        headroom: Int,
        enabled: Bool
    ) -> TextBudget? {
        guard enabled else { return nil }
        return TextBudget(
            maxOutputTokens: profile.textOutputBudget.evaluate(headroom: headroom),
            headroomMB: headroom
        )
    }

    // MARK: Thinking 输出 (线性公式)

    public static func thinking(
        profile: ModelRuntimeProfile,
        headroom: Int,
        enabled: Bool
    ) -> ThinkingBudget? {
        guard enabled else { return nil }
        return ThinkingBudget(
            maxOutputTokens: profile.thinkingOutputBudget.evaluate(headroom: headroom),
            headroomMB: headroom
        )
    }

    // MARK: 多模态输出

    /// 对应原 dynamicMultimodalBudget(hasImages:hasAudio:)。
    /// - 无图无音: 返回 nil
    /// - headroom <= multimodalCriticalHeadroomMB (且该字段 > 0): throw MLXError.multimodalMemoryRisk
    /// - 其他情况: 按 tier 表返回
    public static func multimodal(
        profile: ModelRuntimeProfile,
        headroom: Int,
        hasImages: Bool,
        hasAudio: Bool,
        modelDisplayName: String,
        fallbackRecommendation: String
    ) throws -> MultimodalBudget? {
        guard hasImages || hasAudio else { return nil }

        // 严格下限保护 (原 L849 E4B 专属, 通过 critical=0 关闭 E2B)
        if profile.multimodalCriticalHeadroomMB > 0,
           headroom <= profile.multimodalCriticalHeadroomMB {
            throw MLXError.multimodalMemoryRisk(
                model: modelDisplayName,
                headroomMB: headroom,
                recommendation: fallbackRecommendation
            )
        }

        let tier = lookupMultimodal(profile.multimodalOutputTiers, headroom: headroom)
        // 原代码: hasImages ? cap : nil。tier 里存的是"有图时用什么 cap"。
        let imageSoftCap = hasImages ? tier?.imageSoftTokenCap : nil

        return MultimodalBudget(
            imageSoftTokenCap: imageSoftCap,
            headroomMB: headroom
        )
    }

    // adjustedTextOutputTokens 已在 2026-04-08 删除。
    //
    // 它原本基于"prompt + output 必须 fit 在总序列预算里, 所以 output 必须扣减
    // prepared"的设计。但 chunked prefill (windowSize=256) 让 prepared 长度
    // 对峰值内存几乎无影响 (实测 prepared 290 → 3319 之间, footprint Δ 完全
    // 不相关), 这个扣减成了 false positive 截断的根源。
    //
    // 现在的内存安全网完全靠 textOutputBudget / thinkingOutputBudget 两个公式,
    // 它们已经是 headroom 的函数, 内存吃紧时自动收紧。无需再做 prepared 扣减。
    //
    // 如果将来发现真的需要"context window 限制" (而不是内存限制), 应该独立
    // 表达 (比如 ModelRuntimeProfile.contextWindowTokens), 不要复活旧的
    // sequence budget 概念。

    // MARK: 安全 history 深度

    /// 对应原 safeHistoryDepth (L755-778)。
    public static func safeHistoryDepth(
        profile: ModelRuntimeProfile,
        headroom: Int
    ) -> Int {
        lookup(profile.historyDepthTiers, headroom: headroom)
    }

    // MARK: Thinking 检测

    /// 对应原 isThinkingEnabled(for:) (L901-924)。
    /// 本次 Phase 1 不在 validator 覆盖范围 (纯字符串匹配, 无数值风险)。
    public static func isThinkingEnabled(
        input: UserInput,
        profile: ModelRuntimeProfile
    ) -> Bool {
        if let enabled = input.additionalContext?["enable_thinking"] as? Bool, enabled {
            return true
        }
        guard let marker = profile.thinkingMarker else { return false }

        switch input.prompt {
        case .text(let text):
            return text.contains(marker)
        case .chat(let messages):
            return messages.contains { $0.content.contains(marker) }
        case .messages(let messages):
            return messages.contains { msg in
                if let s = msg["content"] as? String { return s.contains(marker) }
                if let arr = msg["content"] as? [[String: any Sendable]] {
                    return arr.contains { ($0["text"] as? String)?.contains(marker) == true }
                }
                return false
            }
        }
    }
}
