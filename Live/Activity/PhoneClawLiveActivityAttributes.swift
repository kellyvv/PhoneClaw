import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct PhoneClawLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var headline: String
        var detail: String
        var skillID: String?
        var skillName: String?
        var toolName: String?
        var success: Bool?
        /// Low-frequency visual tick for Dynamic Island transitions. Live Activities
        /// animate reliably when ContentState changes, not from view-local timers.
        var motionTick: Int = 0
        /// 本轮任务开始时刻 — 驱动灵动岛上的滚动耗时计时 (执行中才有值)。
        var startedAt: Date?
        /// 当前阶段开始时刻 — 驱动进度轨向下一里程碑的持续爬行。
        var phaseStartedAt: Date?
    }

    var sessionID: String
}
#endif
