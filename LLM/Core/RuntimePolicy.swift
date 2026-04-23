import Foundation

// MARK: - Runtime Policy
//
// 给 Agent / Live 做决策用的运行时策略。
//
// 从 ModelRuntimeProfile 派生，提供简单的查询接口。
// 产品层不需要知道 LinearBudgetFormula / BudgetTier 这些内部实现，
// 只需要调 `safeHistoryDepth(headroomMB:)` 拿到一个 Int。

public struct RuntimePolicy: Sendable {

    /// 底层 profile (包含公式和 tier 数据)
    public let profile: ModelRuntimeProfile

    /// 模型能力
    public let capabilities: ModelCapabilities

    public init(profile: ModelRuntimeProfile, capabilities: ModelCapabilities) {
        self.profile = profile
        self.capabilities = capabilities
    }

    // MARK: - Queries

    /// 当前 headroom 下安全的对话历史深度 (条数)
    public func safeHistoryDepth(headroomMB: Double) -> Int {
        let headroom = Int(headroomMB)
        for tier in profile.historyDepthTiers where headroom < tier.headroomMaxMB {
            return tier.tokens
        }
        return 4 // fallback
    }

    /// 当前 headroom 下安全的最大输出 token 数
    public func maxOutputTokens(headroomMB: Double) -> Int {
        profile.textOutputBudget.evaluate(headroom: Int(headroomMB))
    }

    /// 内存地板 (MB) — 生成过程中 headroom 低于此值应立即停止
    public var headroomFloorMB: Int { profile.headroomFloorMB }

    /// 是否支持 Live 模式
    public var supportsLive: Bool { capabilities.supportsLive }

    /// 是否支持结构化规划 (多 skill 编排)
    public var supportsStructuredPlanning: Bool { capabilities.supportsStructuredPlanning }

    /// 是否支持多模态 (图/音)
    public var supportsMultimodal: Bool { capabilities.supportsVision || capabilities.supportsAudio }

    /// 是否支持 thinking 模式
    public var supportsThinking: Bool { capabilities.supportsThinking }
}
