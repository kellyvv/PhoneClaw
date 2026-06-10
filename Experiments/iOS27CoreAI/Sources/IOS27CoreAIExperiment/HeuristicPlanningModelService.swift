import Foundation

public final class HeuristicPlanningModelService: PlanningModelService {
    public let name = "heuristic-planning-baseline"

    public init() {}

    public func availability() async -> PlanningModelAvailability {
        .available
    }

    public func route(_ input: PlanningInput) async throws -> PlanningDecision {
        let scored = input.availableSkills
            .map { skill in (skill, score(skill: skill, userText: input.userText)) }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }

        guard let best = scored.first, best.1 > 0 else {
            return PlanningDecision(
                action: .answerDirectly,
                confidence: 0.35,
                reason: "No Skill trigger matched the request."
            )
        }

        let toolName = best.0.allowedTools.first
        return PlanningDecision(
            action: .useSkill,
            skillID: best.0.id,
            toolName: toolName,
            confidence: min(0.95, 0.45 + Double(best.1) * 0.12),
            reason: "Matched Skill trigger hints: \(best.0.triggerHints.prefix(3).joined(separator: ", "))"
        )
    }

    private func score(skill: SkillSummary, userText: String) -> Int {
        let normalized = userText.lowercased()
        var total = 0

        for hint in skill.triggerHints where !hint.isEmpty {
            if normalized.contains(hint.lowercased()) {
                total += 2
            }
        }

        if normalized.contains(skill.id.lowercased()) {
            total += 2
        }

        for token in tokenCandidates(from: skill.displayName + " " + skill.description) {
            if normalized.contains(token) {
                total += 1
            }
        }

        if skill.kind == .network, !normalized.contains("联网"), !normalized.contains("搜索") {
            total -= 1
        }

        return max(0, total)
    }

    private func tokenCandidates(from text: String) -> [String] {
        text
            .lowercased()
            .split { ch in ch.isWhitespace || ch.isPunctuation || ch.isSymbol }
            .map(String.init)
            .filter { $0.count >= 2 }
    }
}
