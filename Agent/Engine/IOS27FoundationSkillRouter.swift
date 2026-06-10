import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct IOS27FoundationSkillRouteResult {
    let decision: GuardedSkillRouteDecision?
    let diagnostics: IOS27FoundationSkillRouteDiagnostics
}

struct IOS27FoundationSkillRouteDiagnostics {
    let availability: String
    let prewarmMilliseconds: Int?
    let routeMilliseconds: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let totalTokens: Int?
    let confidence: Double?
    let rawAction: String?
    let rawSkillID: String?
    let rawToolName: String?
    let reason: String
    let errorDescription: String?
}

enum IOS27FoundationSkillRouter {
    static func route(
        for userQuestion: String,
        enabledSkillIDs: Set<String>,
        minimumConfidence: Double = 0.82
    ) async -> IOS27FoundationSkillRouteResult? {
        guard HotfixFeatureFlags.enableIOS27FoundationRouter else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return await IOS27FoundationSkillRouterRuntime.route(
                for: userQuestion,
                enabledSkillIDs: enabledSkillIDs,
                minimumConfidence: minimumConfidence
            )
        }
        #endif

        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
@Generable(description: "A PhoneClaw skill routing decision.")
private struct IOS27GeneratedSkillRoute {
    @Guide(description: "Routing action.", .anyOf(["answerDirectly", "useSkill", "askClarification"]))
    var action: String

    @Guide(description: "Selected skill identifier, or null.", .anyOf(["calendar", "reminders", "clipboard", "health", "translate", "web-search", "null"]))
    var skillID: String

    @Guide(description: "Selected tool name, or null.", .anyOf(["calendar-create-event", "reminders-create", "null"]))
    var toolName: String

    @Guide(description: "Confidence from 0.0 to 1.0.", .range(0.0...1.0))
    var confidence: Double

    @Guide(description: "Short reason for the routing decision.")
    var reason: String
}

@available(iOS 27.0, *)
private enum IOS27FoundationSkillRouterRuntime {
    static func route(
        for userQuestion: String,
        enabledSkillIDs: Set<String>,
        minimumConfidence: Double
    ) async -> IOS27FoundationSkillRouteResult? {
        let normalized = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let model = SystemLanguageModel.default
        let availability = availabilityDescription(model.availability)
        guard case .available = model.availability else {
            return IOS27FoundationSkillRouteResult(
                decision: nil,
                diagnostics: IOS27FoundationSkillRouteDiagnostics(
                    availability: availability,
                    prewarmMilliseconds: nil,
                    routeMilliseconds: nil,
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    reasoningTokens: nil,
                    totalTokens: nil,
                    confidence: nil,
                    rawAction: nil,
                    rawSkillID: nil,
                    rawToolName: nil,
                    reason: "model_unavailable",
                    errorDescription: nil
                )
            )
        }

        let routeStart = ProcessInfo.processInfo.systemUptime
        var prewarmMilliseconds: Int?
        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let prewarmStart = ProcessInfo.processInfo.systemUptime
            session.prewarm()
            prewarmMilliseconds = milliseconds(since: prewarmStart)

            let response = try await session.respond(
                to: prompt(for: normalized),
                generating: IOS27GeneratedSkillRoute.self,
                options: GenerationOptions(
                    samplingMode: .greedy,
                    maximumResponseTokens: 96,
                    toolCallingMode: .disallowed
                ),
                contextOptions: ContextOptions(includeSchemaInPrompt: true),
                metadata: [
                    "phoneclaw_component": "skill_router",
                    "phoneclaw_router": "foundation"
                ]
            )
            let route = response.content
            let decision = decision(
                from: route,
                enabledSkillIDs: enabledSkillIDs,
                minimumConfidence: minimumConfidence
            )
            let routeMilliseconds = milliseconds(since: routeStart)

            return IOS27FoundationSkillRouteResult(
                decision: decision,
                diagnostics: IOS27FoundationSkillRouteDiagnostics(
                    availability: availability,
                    prewarmMilliseconds: prewarmMilliseconds,
                    routeMilliseconds: routeMilliseconds,
                    inputTokens: response.usage.input.totalTokenCount,
                    cachedInputTokens: response.usage.input.cachedTokenCount,
                    outputTokens: response.usage.output.totalTokenCount,
                    reasoningTokens: response.usage.output.reasoningTokenCount,
                    totalTokens: response.usage.totalTokenCount,
                    confidence: route.confidence,
                    rawAction: route.action,
                    rawSkillID: route.skillID,
                    rawToolName: route.toolName,
                    reason: decision?.reason ?? noDecisionReason(
                        for: route,
                        enabledSkillIDs: enabledSkillIDs,
                        minimumConfidence: minimumConfidence
                    ),
                    errorDescription: nil
                )
            )
        } catch {
            return IOS27FoundationSkillRouteResult(
                decision: nil,
                diagnostics: IOS27FoundationSkillRouteDiagnostics(
                    availability: availability,
                    prewarmMilliseconds: prewarmMilliseconds,
                    routeMilliseconds: milliseconds(since: routeStart),
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    reasoningTokens: nil,
                    totalTokens: nil,
                    confidence: nil,
                    rawAction: nil,
                    rawSkillID: nil,
                    rawToolName: nil,
                    reason: "route_error",
                    errorDescription: sanitizedLogValue(String(describing: error))
                )
            )
        }
    }

    private static func decision(
        from route: IOS27GeneratedSkillRoute,
        enabledSkillIDs: Set<String>,
        minimumConfidence: Double
    ) -> GuardedSkillRouteDecision? {
        guard route.confidence >= minimumConfidence else {
            return nil
        }

        switch route.action {
        case "answerDirectly":
            return GuardedSkillRouteDecision(
                action: .answerDirectly,
                skillID: nil,
                reason: "foundation_direct_answer"
            )
        case "useSkill", "askClarification":
            let skillID = normalizedSkillID(route.skillID)
            guard let skillID,
                  enabledSkillIDs.contains(skillID),
                  isSupportedRoute(skillID: skillID, toolName: route.toolName) else {
                return nil
            }
            let reasonPrefix = route.action == "askClarification"
                ? "foundation_clarification"
                : "foundation"
            return GuardedSkillRouteDecision(
                action: .useSkill,
                skillID: skillID,
                reason: "\(reasonPrefix)_\(normalizedReason(route.reason))"
            )
        default:
            return nil
        }
    }

    private static func noDecisionReason(
        for route: IOS27GeneratedSkillRoute,
        enabledSkillIDs: Set<String>,
        minimumConfidence: Double
    ) -> String {
        guard route.confidence >= minimumConfidence else {
            return "below_confidence"
        }

        switch route.action {
        case "useSkill", "askClarification":
            guard let skillID = normalizedSkillID(route.skillID) else {
                return "missing_skill"
            }
            guard enabledSkillIDs.contains(skillID) else {
                return "disabled_skill"
            }
            guard isSupportedRoute(skillID: skillID, toolName: route.toolName) else {
                return "unsupported_tool"
            }
            return "unhandled_skill"
        case "answerDirectly":
            return "direct_answer"
        default:
            return "unknown_action"
        }
    }

    private static func normalizedSkillID(_ rawValue: String) -> String? {
        let normalized = rawValue
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != "null" else { return nil }
        switch normalized {
        case "reminder":
            return "reminders"
        default:
            return normalized
        }
    }

    private static func isSupportedRoute(skillID: String, toolName: String) -> Bool {
        let normalizedTool = toolName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch skillID {
        case "calendar":
            return normalizedTool == "calendar-create-event"
        case "reminders":
            return normalizedTool == "reminders-create"
        case "translate":
            return normalizedTool == "null" || normalizedTool.isEmpty
        default:
            return false
        }
    }

    private static func availabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "unavailable_device_not_eligible"
            case .appleIntelligenceNotEnabled:
                return "unavailable_apple_intelligence_not_enabled"
            case .modelNotReady:
                return "unavailable_model_not_ready"
            @unknown default:
                return "unavailable_unknown"
            }
        @unknown default:
            return "unknown"
        }
    }

    private static func normalizedReason(_ rawValue: String) -> String {
        let lowered = rawValue.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                return Character(scalar)
            }
            return "_"
        }
        let compacted = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        guard !compacted.isEmpty else { return "model_reason" }
        return String(compacted.prefix(64))
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func sanitizedLogValue(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(160)
            .description
    }

    private static let instructions = """
    You are PhoneClaw's conservative fallback skill router.
    Use the provided schema. Return useSkill only when the user clearly asks PhoneClaw
    to perform an action through one of the listed Skills. Return answerDirectly only
    for explanation, definition, summary, or ordinary chat requests that need no tool.
    Return askClarification when a matching Skill exists but required details are missing.
    Do not invent skill IDs or tool names.
    """

    private static func prompt(for request: String) -> String {
        """
        Route this request.

        User request:
        \(request)

        Available Skills:
        - calendar: creates calendar events for meetings, appointments, and schedules. Tool: calendar-create-event.
        - reminders: creates reminders and to-do items. Tool: reminders-create.
        - translate: translates text. Tool: null.

        Decision hints:
        - Meeting scheduling with date or time present => useSkill/calendar/calendar-create-event.
        - Meeting scheduling without date or time => askClarification/calendar/calendar-create-event.
        - Reminder creation with time or task information => useSkill/reminders/reminders-create.
        - Explicit translation requests => useSkill/translate/null.
        - Explanation, definition, introduction, or summary requests => answerDirectly/null/null.
        - Never answerDirectly for a request that should change calendar, reminders, or another device/app state.
        """
    }
}
#endif
