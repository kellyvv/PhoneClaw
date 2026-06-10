import Foundation

#if canImport(FoundationModels) && PHONECLAW_IOS27_BETA_SDK
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
public final class FoundationPlanningModelService: PlanningModelService {
    public let name = "foundation-models-planning"

    public init() {}

    public func availability() async -> PlanningModelAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        default:
            return .unavailable(String(describing: model.availability))
        }
    }

    public func route(_ input: PlanningInput) async throws -> PlanningDecision {
        let availability = await availability()
        guard case .available = availability else {
            throw IOS27ExperimentError.unavailable(String(describing: availability))
        }

        let session = LanguageModelSession(instructions: PlanningPromptBuilder.routingInstructions)
        let response = try await session.respond(to: PlanningPromptBuilder.buildRoutingPrompt(input: input))
        return try PlanningPromptBuilder.decodeDecision(from: response.content)
    }
}
#else
public final class FoundationPlanningModelService: PlanningModelService {
    public let name = "foundation-models-planning-unavailable"

    public init() {}

    public func availability() async -> PlanningModelAvailability {
        .unavailable("FoundationModels is not available. Re-run with Xcode 27 and -DPHONECLAW_IOS27_BETA_SDK.")
    }

    public func route(_ input: PlanningInput) async throws -> PlanningDecision {
        _ = input
        throw IOS27ExperimentError.unavailable("FoundationModels is not available in this build.")
    }
}
#endif
