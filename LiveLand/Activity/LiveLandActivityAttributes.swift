import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct LiveLandActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var headline: String
        var detail: String
        var entryPoint: String?
        var skillID: String?
        var skillName: String?
        var toolName: String?
        var success: Bool?
        var startedAt: Date?
        var phaseStartedAt: Date?
    }

    var sessionID: String
}
#endif
