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

struct IOS27FoundationSkillToolCandidate: Equatable, Sendable {
    let name: String
    let description: String
    let parameters: String
    let isParameterless: Bool
}

struct IOS27FoundationSkillCandidate: Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let type: String
    let triggers: [String]
    let exampleQueries: [String]
    let tools: [IOS27FoundationSkillToolCandidate]

    var promptBlock: String {
        let toolText = tools.isEmpty
            ? "none"
            : tools.map { tool in
                let suffix = tool.isParameterless ? " (no arguments)" : ""
                let parameters = Self.compact(tool.parameters, limit: 180)
                let parameterText = parameters.isEmpty ? "" : " Parameters: \(parameters)"
                return "\(tool.name)\(suffix): \(Self.compact(tool.description, limit: 120)).\(parameterText)"
            }.joined(separator: "; ")
        let triggerText = triggers.isEmpty
            ? "none"
            : triggers.prefix(10).map { Self.compact($0, limit: 40) }.joined(separator: ", ")
        let exampleText = exampleQueries.isEmpty
            ? "none"
            : exampleQueries.prefix(4).map { Self.compact($0, limit: 80) }.joined(separator: " | ")

        return """
        - id: \(id)
          name: \(Self.compact(displayName, limit: 80))
          type: \(type)
          description: \(Self.compact(description, limit: 180))
          tools: \(toolText)
          triggers: \(triggerText)
          examples: \(exampleText)
        """
    }

    private static func compact(_ rawValue: String, limit: Int) -> String {
        let normalized = rawValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit))
    }
}

enum IOS27FoundationSkillRouter {
    static func route(
        for userQuestion: String,
        candidates: [IOS27FoundationSkillCandidate],
        minimumConfidence: Double = 0.82
    ) async -> IOS27FoundationSkillRouteResult? {
        guard HotfixFeatureFlags.enableIOS27FoundationRouter else { return nil }
        let routeCandidates = candidates.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !routeCandidates.isEmpty else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            return await IOS27FoundationSkillRouterRuntime.route(
                for: userQuestion,
                candidates: routeCandidates,
                minimumConfidence: minimumConfidence
            )
        }
        #endif

        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
@Generable(description: "A PhoneClaw skill routing decision.")
private struct IOS27GeneratedSkillRoute {
    @Guide(description: "Routing action.", .anyOf(["answerDirectly", "useSkill", "askClarification"]))
    var action: String

    @Guide(description: "Selected skill identifier from Available Skills, or null.")
    var skillID: String

    @Guide(description: "Selected tool name from the selected skill's tools, or null.")
    var toolName: String

    @Guide(description: "Confidence from 0.0 to 1.0.", .range(0.0...1.0))
    var confidence: Double

    @Guide(description: "Short reason for the routing decision.")
    var reason: String
}

@available(iOS 27.0, macOS 27.0, *)
private enum IOS27FoundationSkillRouterRuntime {
    static func route(
        for userQuestion: String,
        candidates: [IOS27FoundationSkillCandidate],
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
                to: prompt(for: normalized, candidates: candidates),
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
                candidates: candidates,
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
                        candidates: candidates,
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
        candidates: [IOS27FoundationSkillCandidate],
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
            guard let skillID = resolvedSkillID(route.skillID, candidates: candidates),
                  let candidate = candidates.first(where: { $0.id == skillID }),
                  isSupportedRoute(candidate: candidate, toolName: route.toolName) else {
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
        candidates: [IOS27FoundationSkillCandidate],
        minimumConfidence: Double
    ) -> String {
        guard route.confidence >= minimumConfidence else {
            return "below_confidence"
        }

        switch route.action {
        case "useSkill", "askClarification":
            guard let skillID = resolvedSkillID(route.skillID, candidates: candidates) else {
                return "missing_skill"
            }
            guard let candidate = candidates.first(where: { $0.id == skillID }),
                  isSupportedRoute(candidate: candidate, toolName: route.toolName) else {
                return "unsupported_tool"
            }
            return "unhandled_skill"
        case "answerDirectly":
            return "direct_answer"
        default:
            return "unknown_action"
        }
    }

    private static func resolvedSkillID(_ rawValue: String, candidates: [IOS27FoundationSkillCandidate]) -> String? {
        let normalized = normalizedIdentifier(rawValue)
        guard !normalized.isEmpty, normalized != "null" else { return nil }

        for candidate in candidates {
            let ids = [
                candidate.id,
                candidate.displayName
            ]
            if ids.contains(where: { normalizedIdentifier($0) == normalized }) {
                return candidate.id
            }
        }
        return nil
    }

    private static func isSupportedRoute(candidate: IOS27FoundationSkillCandidate, toolName: String) -> Bool {
        let normalizedTool = normalizedIdentifier(toolName)
        if normalizedTool.isEmpty || normalizedTool == "null" || normalizedTool == "none" {
            return true
        }

        return candidate.tools.contains { tool in
            normalizedIdentifier(tool.name) == normalizedTool
        }
    }

    private static func normalizedIdentifier(_ rawValue: String) -> String {
        rawValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
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

    private static func prompt(for request: String, candidates: [IOS27FoundationSkillCandidate]) -> String {
        let availableSkills = candidates
            .sorted { $0.id < $1.id }
            .map(\.promptBlock)
            .joined(separator: "\n")

        return """
        Route this request.

        User request:
        \(request)

        Available Skills (use the id exactly):
        \(availableSkills)

        Decision hints:
        - Return useSkill only when the request clearly matches one listed skill id, name, description, trigger, example, or tool.
        - Return askClarification when one listed skill matches but required details appear missing.
        - For skillID, copy the exact id from Available Skills.
        - For toolName, copy one listed tool for that skill, or return null when tool choice should be decided later.
        - Explanation, definition, introduction, or summary requests => answerDirectly/null/null.
        - Never answerDirectly for a request that should read or change private device/app state.
        - Do not invent skill IDs or tool names that are not listed above.
        """
    }
}
#endif
