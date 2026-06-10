import XCTest
@testable import IOS27CoreAIExperiment

final class PlanningPromptBuilderTests: XCTestCase {
    func testRoutingPromptContainsSkillsAndContract() {
        let input = PlanningInput(
            userText: "明天下午两点帮我安排产品评审会议",
            availableSkills: [
                SkillSummary(
                    id: "calendar",
                    kind: .device,
                    displayName: "Calendar",
                    description: "Create and inspect calendar events.",
                    allowedTools: ["calendar-create-event"],
                    triggerHints: ["会议", "日程", "安排"]
                ),
            ]
        )

        let prompt = PlanningPromptBuilder.buildRoutingPrompt(input: input)

        XCTAssertTrue(prompt.contains("Return exactly one JSON object"))
        XCTAssertTrue(prompt.contains("\"id\" : \"calendar\""))
        XCTAssertTrue(prompt.contains("明天下午两点"))
        XCTAssertTrue(prompt.contains("calendar-create-event"))
    }

    func testDecodeDecisionAcceptsPlainJSON() throws {
        let output = """
        {"action":"useSkill","skillID":"calendar","toolName":"calendar-create-event","confidence":0.91,"reason":"calendar request","argumentsJSON":null}
        """

        let decision = try PlanningPromptBuilder.decodeDecision(from: output)

        XCTAssertEqual(decision.action, .useSkill)
        XCTAssertEqual(decision.skillID, "calendar")
        XCTAssertEqual(decision.toolName, "calendar-create-event")
    }

    func testDecodeDecisionExtractsFencedJSON() throws {
        let output = """
        ```json
        {"action":"answerDirectly","skillID":null,"toolName":null,"confidence":0.4,"reason":"chat","argumentsJSON":null}
        ```
        """

        let decision = try PlanningPromptBuilder.decodeDecision(from: output)

        XCTAssertEqual(decision.action, .answerDirectly)
        XCTAssertEqual(decision.skillID, nil)
    }
}
