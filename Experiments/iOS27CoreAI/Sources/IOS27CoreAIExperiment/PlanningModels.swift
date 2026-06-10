import Foundation

public enum SkillKind: String, Codable, Equatable, Sendable {
    case device
    case content
    case network
}

public struct SkillSummary: Codable, Equatable, Sendable {
    public let id: String
    public let kind: SkillKind
    public let displayName: String
    public let description: String
    public let allowedTools: [String]
    public let triggerHints: [String]

    public init(
        id: String,
        kind: SkillKind,
        displayName: String,
        description: String,
        allowedTools: [String] = [],
        triggerHints: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.description = description
        self.allowedTools = allowedTools
        self.triggerHints = triggerHints
    }
}

public struct PlanningInput: Codable, Equatable, Sendable {
    public let userText: String
    public let localeIdentifier: String
    public let availableSkills: [SkillSummary]
    public let recentContext: [String]
    public let allowNetwork: Bool

    public init(
        userText: String,
        localeIdentifier: String = "zh-Hans",
        availableSkills: [SkillSummary],
        recentContext: [String] = [],
        allowNetwork: Bool = false
    ) {
        self.userText = userText
        self.localeIdentifier = localeIdentifier
        self.availableSkills = availableSkills
        self.recentContext = recentContext
        self.allowNetwork = allowNetwork
    }
}

public enum PlanningAction: String, Codable, Equatable, Sendable {
    case answerDirectly
    case useSkill
    case askClarification
    case refuse
}

public struct PlanningDecision: Codable, Equatable, Sendable {
    public let action: PlanningAction
    public let skillID: String?
    public let toolName: String?
    public let confidence: Double
    public let reason: String
    public let argumentsJSON: String?

    public init(
        action: PlanningAction,
        skillID: String? = nil,
        toolName: String? = nil,
        confidence: Double,
        reason: String,
        argumentsJSON: String? = nil
    ) {
        self.action = action
        self.skillID = skillID
        self.toolName = toolName
        self.confidence = confidence
        self.reason = reason
        self.argumentsJSON = argumentsJSON
    }
}

public enum PlanningModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public protocol PlanningModelService: AnyObject, Sendable {
    var name: String { get }
    func availability() async -> PlanningModelAvailability
    func route(_ input: PlanningInput) async throws -> PlanningDecision
}

public enum IOS27ExperimentError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidModelOutput(String)
    case noSkillMatch

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .invalidModelOutput(let output):
            return "Invalid model output: \(output)"
        case .noSkillMatch:
            return "No matching Skill was found."
        }
    }
}
