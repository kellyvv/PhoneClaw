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
private struct IOS27GeneratedSkillRoute {
    let action: String
    let skillID: String
    let toolName: String
    let confidence: Double
    let reason: String
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

            let routeSchema = try routeGenerationSchema(candidates: candidates)
            let response = try await session.respond(
                to: prompt(for: normalized, candidates: candidates),
                schema: routeSchema,
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
            let route = try decodedRoute(from: response.content)
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
        guard !normalized.isEmpty, normalized != "null", normalized != "none" else { return nil }

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

    private static func routeGenerationSchema(candidates: [IOS27FoundationSkillCandidate]) throws -> GenerationSchema {
        let skillIDChoices = uniqueSorted(candidates.map(\.id) + ["none"])
        let toolChoices = uniqueSorted(candidates.flatMap { candidate in
            candidate.tools.map(\.name)
        } + ["none"])

        let root = DynamicGenerationSchema(
            name: "PhoneClawSkillRoute",
            description: "A PhoneClaw skill routing decision.",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "action",
                    description: "Routing action.",
                    schema: DynamicGenerationSchema(
                        name: "PhoneClawSkillRouteAction",
                        anyOf: ["answerDirectly", "useSkill", "askClarification"]
                    )
                ),
                DynamicGenerationSchema.Property(
                    name: "skillID",
                    description: "Selected skill identifier. Use none when no skill is selected.",
                    schema: DynamicGenerationSchema(
                        name: "PhoneClawSkillRouteSkillID",
                        anyOf: skillIDChoices
                    )
                ),
                DynamicGenerationSchema.Property(
                    name: "toolName",
                    description: "Selected tool name from the selected skill, or none.",
                    schema: DynamicGenerationSchema(
                        name: "PhoneClawSkillRouteToolName",
                        anyOf: toolChoices
                    )
                ),
                DynamicGenerationSchema.Property(
                    name: "confidence",
                    description: "Confidence from 0.0 to 1.0.",
                    schema: DynamicGenerationSchema(
                        type: Double.self,
                        guides: [.range(0.0...1.0)]
                    )
                ),
                DynamicGenerationSchema.Property(
                    name: "reason",
                    description: "Short reason for the routing decision.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )

        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func decodedRoute(from content: GeneratedContent) throws -> IOS27GeneratedSkillRoute {
        guard let data = content.jsonString.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IOS27FoundationRouteDecodeError.invalidContent
        }

        return IOS27GeneratedSkillRoute(
            action: stringValue(object["action"]),
            skillID: stringValue(object["skillID"]),
            toolName: stringValue(object["toolName"]),
            confidence: doubleValue(object["confidence"]),
            reason: stringValue(object["reason"])
        )
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case _ as NSNull:
            return "none"
        case .none:
            return "none"
        default:
            return String(describing: value ?? "none")
        }
    }

    private static func doubleValue(_ value: Any?) -> Double {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value) ?? 0
        default:
            return 0
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
        - For skillID, choose one schema-provided skill id exactly.
        - For toolName, choose one schema-provided tool name for that skill, or none when tool choice should be decided later.
        - Explanation, definition, introduction, or summary requests => answerDirectly/none/none.
        - Never answerDirectly for a request that should read or change private device/app state.
        - Do not invent skill IDs or tool names that are not listed above.
        """
    }
}

@available(iOS 27.0, macOS 27.0, *)
private enum IOS27FoundationRouteDecodeError: Error {
    case invalidContent
}
#endif
