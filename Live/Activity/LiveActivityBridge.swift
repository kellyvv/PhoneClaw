import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

actor LiveActivityBridge {
    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private var activity: Activity<PhoneClawLiveActivityAttributes>?
    #endif

    private static let motionInterval: Duration = .milliseconds(650)
    private static let motionPhases: Set<String> = [
        "starting", "listening", "recording", "processing",
        "understanding", "searching", "summarizing", "executing", "speaking"
    ]
    /// 执行中的阶段集合 — 进入即起表, 离开 (skill/listening/ended) 即停表。
    /// 时间戳由 Bridge 统一盖章, 引擎各调用点无感。
    private static let inFlightPhases: Set<String> = [
        "recording", "processing", "understanding",
        "searching", "summarizing", "executing", "speaking"
    ]
    private var turnStartedAt: Date?
    private var phaseStartedAt: Date?
    private var lastPhase: String?
    private var motionTick = 0
    private var motionTask: Task<Void, Never>?
    #if canImport(ActivityKit)
    @available(iOS 16.2, *)
    private var latestState: PhoneClawLiveActivityAttributes.ContentState?
    #endif

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

    func startSession() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let attributes = PhoneClawLiveActivityAttributes(sessionID: UUID().uuidString)
        let state = PhoneClawLiveActivityAttributes.ContentState(
            phase: "starting",
            headline: "PhoneClaw LIVE",
            detail: "正在启动",
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
            latestState = state
            startMotionTickerIfNeeded(for: state.phase)
            print("[LiveActivity] started id=\(activity?.id ?? "unknown")")
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
        #endif
    }

    func waitForDismissal() async -> Bool {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *), let activity else { return false }
        let activityID = activity.id

        for await state in activity.activityStateUpdates {
            switch state {
            case .dismissed:
                if self.activity?.id == activityID {
                    stopMotionTicker()
                    self.activity = nil
                    self.latestState = nil
                }
                print("[LiveActivity] dismissed by user id=\(activityID)")
                return true
            case .ended:
                if self.activity?.id == activityID {
                    stopMotionTicker()
                    self.activity = nil
                    self.latestState = nil
                }
                return false
            default:
                break
            }
        }
        #endif
        return false
    }

    func update(
        phase: String,
        headline: String,
        detail: String,
        skillID: String? = nil,
        skillName: String? = nil,
        toolName: String? = nil,
        success: Bool? = nil,
        alertTitle: String? = nil,
        alertBody: String? = nil
    ) async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let activity else { return }

        let previousPhase = lastPhase
        let stamps = stampTimestamps(for: phase)
        if previousPhase != phase {
            advanceMotionCounter()
        }
        let state = PhoneClawLiveActivityAttributes.ContentState(
            phase: phase,
            headline: clipped(headline, limit: 40),
            detail: clipped(detail, limit: 90),
            skillID: skillID,
            skillName: skillName.map { clipped($0, limit: 28) },
            toolName: toolName.map { clipped($0, limit: 36) },
            success: success,
            motionTick: motionTick,
            startedAt: stamps.started,
            phaseStartedAt: stamps.phaseStarted
        )
        latestState = state
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
        startMotionTickerIfNeeded(for: phase)
        #endif
    }

    func endSession() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let activity else { return }

        stopMotionTicker()
        let finalState = PhoneClawLiveActivityAttributes.ContentState(
            phase: "ended",
            headline: "PhoneClaw LIVE",
            detail: "已结束",
            skillID: nil,
            skillName: nil,
            toolName: nil,
            success: nil,
            motionTick: motionTick
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        self.activity = nil
        self.latestState = nil
        print("[LiveActivity] ended")
        #endif
    }

    private func advanceMotionCounter() {
        motionTick = (motionTick + 1) % 10_000
    }

    private func startMotionTickerIfNeeded(for phase: String) {
        guard Self.motionPhases.contains(phase) else {
            stopMotionTicker()
            return
        }
        guard motionTask == nil else { return }

        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.motionInterval)
                guard !Task.isCancelled else { break }
                await self?.publishMotionTick()
            }
        }
    }

    private func stopMotionTicker() {
        motionTask?.cancel()
        motionTask = nil
    }

    private func publishMotionTick() async {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        guard let activity, var state = latestState else {
            stopMotionTicker()
            return
        }
        guard Self.motionPhases.contains(state.phase) else {
            stopMotionTicker()
            return
        }

        advanceMotionCounter()
        state.motionTick = motionTick
        latestState = state
        await activity.update(ActivityContent(state: state, staleDate: nil))
        #endif
    }

    private func clipped(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
