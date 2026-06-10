import Foundation

public enum PlanningPromptBuilder {
    public static let routingInstructions = """
    You are PhoneClaw's routing model. Choose whether a user request should be answered directly, sent to one Skill, clarified, or refused.
    Return exactly one JSON object with these keys:
    action: one of answerDirectly, useSkill, askClarification, refuse
    skillID: string or null
    toolName: string or null
    confidence: number between 0 and 1
    reason: short string
    argumentsJSON: stringified JSON object or null
    Do not include Markdown or extra text.
    """

    public static func buildRoutingPrompt(input: PlanningInput) -> String {
        let payload = RoutingPayload(
            userText: input.userText,
            localeIdentifier: input.localeIdentifier,
            allowNetwork: input.allowNetwork,
            recentContext: Array(input.recentContext.suffix(4)),
            availableSkills: input.availableSkills
        )

        let encodedPayload: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            encodedPayload = String(decoding: data, as: UTF8.self)
        } catch {
            encodedPayload = #"{"userText":"\#(input.userText)"}"#
        }

        return """
        \(routingInstructions)

        Routing input:
        \(encodedPayload)
        """
    }

    public static func decodeDecision(from modelOutput: String) throws -> PlanningDecision {
        let json = try extractFirstJSONObject(from: modelOutput)
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(PlanningDecision.self, from: data)
        } catch {
            throw IOS27ExperimentError.invalidModelOutput(modelOutput)
        }
    }

    static func extractFirstJSONObject(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{") else {
            throw IOS27ExperimentError.invalidModelOutput(text)
        }

        var depth = 0
        var inString = false
        var isEscaped = false
        var cursor = start

        while cursor < trimmed.endIndex {
            let ch = trimmed[cursor]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(trimmed[start...cursor])
                    }
                }
            }

            cursor = trimmed.index(after: cursor)
        }

        throw IOS27ExperimentError.invalidModelOutput(text)
    }

    private struct RoutingPayload: Encodable {
        let userText: String
        let localeIdentifier: String
        let allowNetwork: Bool
        let recentContext: [String]
        let availableSkills: [SkillSummary]
    }
}
