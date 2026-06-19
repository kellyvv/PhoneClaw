import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

actor LiveLandActivityBridge {
    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private var activity: Activity<LiveLandActivityAttributes>?
    @available(iOS 16.2, *)
    private var transientResultActivity: Activity<LiveLandActivityAttributes>?
    #endif

    /// 执行中的阶段集合 — 进入即起表, 离开 (skill/listening/ended) 即停表。
    /// 时间戳由 Bridge 统一盖章, 引擎各调用点无感。
    private static let inFlightPhases: Set<String> = [
        "recording", "processing", "understanding",
        "searching", "summarizing", "executing", "speaking"
    ]
    private var turnStartedAt: Date?
    private var phaseStartedAt: Date?
    private var lastPhase: String?
    private var entryPoint = "liveLand"

    private func stampTimestamps(for phase: String) -> (started: Date?, phaseStarted: Date?) {
        let now = Date()
        if Self.inFlightPhases.contains(phase) {
            if turnStartedAt == nil { turnStartedAt = now }
        } else {
            turnStartedAt = nil
        }
        if phase != lastPhase {
            phaseStartedAt = now
            lastPhase = phase
        }
        return (turnStartedAt, phaseStartedAt)
    }

    func startSession(
        headline: String = "PhoneClaw LIVE",
        detail: String = "正在启动",
        entryPoint: String = "liveLand"
    ) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }
        self.entryPoint = entryPoint
        await endExistingActivitiesBeforeRequest(
            headline: headline,
            detail: detail,
            entryPoint: entryPoint
        )

        let attributes = LiveLandActivityAttributes(sessionID: UUID().uuidString)
        let state = LiveLandActivityAttributes.ContentState(
            phase: "starting",
            headline: headline,
            detail: detail,
            entryPoint: entryPoint,
            skillID: nil,
            skillName: nil,
            toolName: nil,
            success: nil
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            print("[LiveLandActivity] started id=\(activity?.id ?? "unknown")")
        } catch {
            print("[LiveLandActivity] start failed: \(error)")
        }
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private func endExistingActivitiesBeforeRequest(
        headline: String,
        detail: String,
        entryPoint: String
    ) async {
        for existing in Activity<LiveLandActivityAttributes>.activities {
            let finalState = LiveLandActivityAttributes.ContentState(
                phase: "ended",
                headline: headline,
                detail: detail,
                entryPoint: entryPoint,
                skillID: nil,
                skillName: nil,
                toolName: nil,
                success: nil
            )
            await existing.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            print("[LiveLandActivity] ended stale activity before request id=\(existing.id)")
        }
    }
    #endif

    func waitForDismissal() async -> Bool {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *), let activity else { return false }
        let activityID = activity.id

        for await state in activity.activityStateUpdates {
            switch state {
            case .dismissed:
                if self.activity?.id == activityID {
                    self.activity = nil
                }
                print("[LiveLandActivity] dismissed by user id=\(activityID)")
                return true
            case .ended:
                if self.activity?.id == activityID {
                    self.activity = nil
                }
                return false
            default:
                break
            }
        }
        #endif
        return false
    }

    func presentTransientResult(
        headline: String,
        detail: String,
        skillID: String? = nil,
        skillName: String? = nil,
        toolName: String? = nil,
        success: Bool? = nil,
        entryPoint: String? = nil,
        allowTransientRequest: Bool = true
    ) async -> Bool {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

        let state = LiveLandActivityAttributes.ContentState(
            phase: "result",
            headline: clipped(headline, limit: 40),
            detail: clipped(detail, limit: detailLimit(for: "result", skillID: skillID, toolName: toolName)),
            entryPoint: entryPoint ?? self.entryPoint,
            skillID: skillID,
            skillName: skillName.map { clipped($0, limit: 28) },
            toolName: toolName.map { clipped($0, limit: 36) },
            success: success,
            startedAt: nil,
            phaseStartedAt: Date()
        )
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(30),
            relevanceScore: 100
        )

        if let transientResultActivity {
            await transientResultActivity.end(content, dismissalPolicy: .immediate)
            self.transientResultActivity = nil
        }

        if await publishExpandedResultAlert(content: content) {
            return true
        }

        guard allowTransientRequest else {
            print("[LiveLandActivity] transient result blocked by caller")
            return false
        }

        guard #available(iOS 18.0, *) else {
            print("[LiveLandActivity] transient result unavailable before iOS 18")
            return false
        }

        do {
            transientResultActivity = try Activity.request(
                attributes: LiveLandActivityAttributes(sessionID: UUID().uuidString),
                content: content,
                pushType: nil,
                style: .transient
            )
            print("[LiveLandActivity] transient result started id=\(transientResultActivity?.id ?? "unknown")")
            return true
        } catch {
            print("[LiveLandActivity] transient result start failed: \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private func publishExpandedResultAlert(
        content: ActivityContent<LiveLandActivityAttributes.ContentState>
    ) async -> Bool {
        guard let activity else { return false }
        let alertConfiguration = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: clipped(content.state.headline, limit: 36)),
            body: LocalizedStringResource(stringLiteral: clipped(content.state.detail, limit: 90)),
            sound: .default
        )
        await activity.update(content, alertConfiguration: alertConfiguration)
        print("[LiveLandActivity] result expanded alert update id=\(activity.id)")
        return true
    }
    #endif

    func update(
        phase: String,
        headline: String,
        detail: String,
        skillID: String? = nil,
        skillName: String? = nil,
        toolName: String? = nil,
        success: Bool? = nil,
        entryPoint: String? = nil,
        alertTitle: String? = nil,
        alertBody: String? = nil
    ) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let activity else { return }

        let stamps = stampTimestamps(for: phase)
        let detailLimit = detailLimit(for: phase, skillID: skillID, toolName: toolName)
        let state = LiveLandActivityAttributes.ContentState(
            phase: phase,
            headline: clipped(headline, limit: 40),
            detail: clipped(detail, limit: detailLimit),
            entryPoint: entryPoint ?? self.entryPoint,
            skillID: skillID,
            skillName: skillName.map { clipped($0, limit: 28) },
            toolName: toolName.map { clipped($0, limit: 36) },
            success: success,
            startedAt: stamps.started,
            phaseStartedAt: stamps.phaseStarted
        )
        let alertConfiguration: AlertConfiguration?
        if let alertTitle, let alertBody {
            alertConfiguration = AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: clipped(alertTitle, limit: 36)),
                body: LocalizedStringResource(stringLiteral: clipped(alertBody, limit: 90)),
                sound: .default
            )
        } else {
            alertConfiguration = nil
        }

        await activity.update(
            ActivityContent(state: state, staleDate: nil),
            alertConfiguration: alertConfiguration
        )
        #endif
    }

    private func detailLimit(for phase: String, skillID: String?, toolName: String?) -> Int {
        if phase == "skill" || phase == "result" {
            return 1_200
        }
        let sourceKeys = [skillID, toolName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if sourceKeys.contains(where: { $0.contains("web") || $0.contains("search") || $0.contains("fetch") }) {
            return 320
        }
        return 140
    }

    func endSession(
        headline: String = "PhoneClaw LIVE",
        detail: String = "已结束",
        entryPoint: String? = nil
    ) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }

        let finalState = LiveLandActivityAttributes.ContentState(
            phase: "ended",
            headline: headline,
            detail: detail,
            entryPoint: entryPoint ?? self.entryPoint,
            skillID: nil,
            skillName: nil,
            toolName: nil,
            success: nil
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        guard activity != nil || transientResultActivity != nil else { return }
        if let activity {
            await activity.end(
                content,
                dismissalPolicy: .immediate
            )
            self.activity = nil
            print("[LiveLandActivity] ended")
        }
        if let transientResultActivity {
            await transientResultActivity.end(
                content,
                dismissalPolicy: .immediate
            )
            self.transientResultActivity = nil
            print("[LiveLandActivity] transient result ended")
        }
        #endif
    }

    private func clipped(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
