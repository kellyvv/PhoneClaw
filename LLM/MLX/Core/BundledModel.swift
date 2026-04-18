import Foundation

// MARK: - Runtime Profile 类型
//
// 双层内存安全架构 (2026-04-18 重构):
//
// 第一层 — 线性公式 (宽松初始预估):
//   tokens = clamp(min, max(0, headroom - safetyMargin) * tokensPerMB, max)
//   maxTokens 放开到 4096, 让 UI 滑块 (maxOutputTokens) 成为实际上限。
//   公式不再是主要限制因素, 只做粗粒度预算。
//
// 第二层 — 实时 headroom 地板检测 (真正安全网):
//   生成循环中每 32 token 检查 MemoryStats.headroomMB,
//   低于 headroomFloorMB (E2B=150, E4B=200) 立即停止。
//   这比公式更精确, 因为它看的是真实内存而不是预测值。
//
// 多模态和 historyDepth 仍保留 tier 表 (语义不适合线性化)。

/// 线性预算公式:
///   tokens = clamp(minTokens, max(0, headroom - safetyMarginMB) * tokensPerMB, maxTokens)
public struct LinearBudgetFormula: Sendable, Equatable {
    public let safetyMarginMB: Int  // headroom 减去这个量才参与计算 (留给系统/transient peak)
    public let tokensPerMB: Double  // 1 MB usable headroom 折算多少 token
    public let minTokens: Int       // 下限 (即使 headroom 极低也保证最少这么多)
    public let maxTokens: Int       // 上限 (避免 headroom 极大时给出荒诞的输出长度)

    public init(safetyMarginMB: Int, tokensPerMB: Double, minTokens: Int, maxTokens: Int) {
        self.safetyMarginMB = safetyMarginMB
        self.tokensPerMB = tokensPerMB
        self.minTokens = minTokens
        self.maxTokens = maxTokens
    }

    public func evaluate(headroom: Int) -> Int {
        let usable = max(0, headroom - safetyMarginMB)
        let raw = Int((Double(usable) * tokensPerMB).rounded())
        return min(maxTokens, max(minTokens, raw))
    }
}

/// 单档预算 (仅用于 historyDepth, 整数离散映射)
public struct BudgetTier: Sendable, Equatable {
    public let headroomMaxMB: Int  // headroom < 此值时命中此档
    public let tokens: Int         // 此处 tokens 字段是"消息条数"

    public init(headroomMaxMB: Int, tokens: Int) {
        self.headroomMaxMB = headroomMaxMB
        self.tokens = tokens
    }
}

/// 多模态单档预算: 仅约束 imageSoftTokenCap (vision encoder token 预算)。
/// 输出 token 上限不在此处设定 — 由生成循环的 headroomFloorMB 运行时检测动态控制。
public struct MultimodalTier: Sendable, Equatable {
    public let headroomMaxMB: Int
    public let imageSoftTokenCap: Int?

    public init(headroomMaxMB: Int, imageSoftTokenCap: Int?) {
        self.headroomMaxMB = headroomMaxMB
        self.imageSoftTokenCap = imageSoftTokenCap
    }
}

/// 模型运行时 profile
///
/// 历史背景:
/// 早期版本有 textSequenceBudget / thinkingSequenceBudget 两个字段, 用来表达
/// "prompt + output 的总序列预算"。这是 chunked prefill 之前的设计, 假设 KV
/// cache 与总序列长度线性增长, prompt 必须从 output 预算里扣减。
///
/// chunked prefill (windowSize=256) 上线后, 单次 forward 的 transient 内存
/// 与 prompt 长度解耦, prepared 长度对峰值内存几乎无影响 (实测 prepared
/// 290 → 3319 之间, footprint Δ 完全不相关)。"总序列预算"概念失去意义,
/// 已删除。output 上限只受 textOutputBudget / thinkingOutputBudget 单一约束,
/// 它们已经是 headroom 的函数, 内存吃紧时自动收紧, 无需再做 prepared 扣减。
public struct ModelRuntimeProfile: Sendable {
    /// 触发 thinking 模式的 marker (nil = 不支持 thinking)
    public let thinkingMarker: String?

    /// 普通文本输出 token 上限 (单次 generateStream 的硬上限, 不含 prompt)
    public let textOutputBudget: LinearBudgetFormula

    /// thinking 输出 token 上限
    public let thinkingOutputBudget: LinearBudgetFormula

    /// 多模态: 保留 tier 表用于 image soft token cap (随 headroom 调节图像精度)
    /// 输出 token 上限不再在 tier 中设定, 完全由 headroomFloorMB 动态控制
    public let multimodalOutputTiers: [MultimodalTier]

    /// 多模态严格下限 (headroom <= 此值直接 throw multimodalMemoryRisk)
    /// 0 = 不做严格下限检查
    public let multimodalCriticalHeadroomMB: Int

    /// 运行时内存地板 (MB): 生成过程中实时检测 headroom, 低于此值立即停止
    /// 这是真正的安全网, 取代了之前公式中过于保守的 tokensPerMB 预测。
    public let headroomFloorMB: Int

    /// safeHistoryDepth: 整数离散映射, 保留 tier 表
    public let historyDepthTiers: [BudgetTier]

    public init(
        thinkingMarker: String?,
        textOutputBudget: LinearBudgetFormula,
        thinkingOutputBudget: LinearBudgetFormula,
        multimodalOutputTiers: [MultimodalTier],
        multimodalCriticalHeadroomMB: Int,
        headroomFloorMB: Int,
        historyDepthTiers: [BudgetTier]
    ) {
        self.thinkingMarker = thinkingMarker
        self.textOutputBudget = textOutputBudget
        self.thinkingOutputBudget = thinkingOutputBudget
        self.multimodalOutputTiers = multimodalOutputTiers
        self.multimodalCriticalHeadroomMB = multimodalCriticalHeadroomMB
        self.headroomFloorMB = headroomFloorMB
        self.historyDepthTiers = historyDepthTiers
    }
}

// MARK: - Gemma 4 Profiles
//
// 公式系数标定原则 (基于 2026-04-08 实测日志):
//   - E4B baseline footprint = 4550 MB, 生成时峰值 +400 MB transient
//   - jetsam = 6144 MB, 实测 headroom 稳定在 1500-1600 MB
//   - safetyMarginMB = 300: 留 200 MB jetsam buffer + 100 MB transient overhead
//   - tokensPerMB 约为 1.0-1.8: 1 MB usable headroom 大概折 1-2 个 token 的 KV cache
//   - sequence > output: 序列预算包含 prompt + output, 系数比 output 更高

public enum MLXModelProfiles {

    // MARK: Gemma 4 E2B — 轻量, 26 layers (KV cache 较小)

    public static let gemma4_e2b = ModelRuntimeProfile(
        thinkingMarker: "<|think|>",

        // 文本/思考预算: maxTokens 放开到 4096, 让 UI maxOutputTokens 滑块成为
        // 真正上限。实际安全由生成循环中的 headroomFloorMB 实时检测保障。
        // 公式仍保留 safetyMarginMB 做初始预估, 但不再是主要限制因素。
        textOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 150, tokensPerMB: 4.0, minTokens: 512, maxTokens: 4_096
        ),
        thinkingOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 150, tokensPerMB: 4.0, minTokens: 512, maxTokens: 4_096
        ),

        // 多模态: E2B 不像 E4B 那么吃内存, 平表
        multimodalOutputTiers: [
            MultimodalTier(headroomMaxMB: .max, imageSoftTokenCap: 160),
        ],
        multimodalCriticalHeadroomMB: 0,
        headroomFloorMB: 150,

        historyDepthTiers: [
            BudgetTier(headroomMaxMB: 500,    tokens: 0),
            BudgetTier(headroomMaxMB: 900,    tokens: 2),
            BudgetTier(headroomMaxMB: 1_500,  tokens: 4),
            BudgetTier(headroomMaxMB: .max,   tokens: 6),
        ]
    )

    // MARK: Gemma 4 E4B — 重量, 42 layers (KV cache 大, 更紧)

    public static let gemma4_e4b = ModelRuntimeProfile(
        thinkingMarker: "<|think|>",

        // 文本/思考预算: maxTokens 放开, 真正安全网靠 headroomFloorMB 实时检测。
        textOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 200, tokensPerMB: 3.0, minTokens: 384, maxTokens: 4_096
        ),
        thinkingOutputBudget: LinearBudgetFormula(
            safetyMarginMB: 200, tokensPerMB: 3.0, minTokens: 384, maxTokens: 4_096
        ),

        // 多模态: E4B vision 激活内存大, 必须保留细分 tier
        multimodalOutputTiers: [
            MultimodalTier(headroomMaxMB: 500,    imageSoftTokenCap: 48),
            MultimodalTier(headroomMaxMB: 700,    imageSoftTokenCap: 64),
            MultimodalTier(headroomMaxMB: 900,    imageSoftTokenCap: 80),
            MultimodalTier(headroomMaxMB: 1_100,  imageSoftTokenCap: 96),
            MultimodalTier(headroomMaxMB: 1_300,  imageSoftTokenCap: 128),
            MultimodalTier(headroomMaxMB: .max,   imageSoftTokenCap: 160),
        ],
        multimodalCriticalHeadroomMB: 320,
        headroomFloorMB: 200,

        historyDepthTiers: [
            BudgetTier(headroomMaxMB: 700,    tokens: 0),
            BudgetTier(headroomMaxMB: 1_100,  tokens: 2),
            BudgetTier(headroomMaxMB: 1_700,  tokens: 4),
            BudgetTier(headroomMaxMB: .max,   tokens: 6),
        ]
    )

    // MARK: - Lookup

    /// 根据 model.id 查 profile
    public static func profile(for modelID: String) -> ModelRuntimeProfile? {
        switch modelID {
        case "gemma-4-e2b-it-4bit": return gemma4_e2b
        case "gemma-4-e4b-it-4bit": return gemma4_e4b
        default: return nil
        }
    }
}
