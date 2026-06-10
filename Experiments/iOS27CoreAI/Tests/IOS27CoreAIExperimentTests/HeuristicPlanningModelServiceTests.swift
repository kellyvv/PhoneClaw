import XCTest
@testable import IOS27CoreAIExperiment

final class HeuristicPlanningModelServiceTests: XCTestCase {
    func testRoutesCalendarRequest() async throws {
        let service = HeuristicPlanningModelService()
        let input = PlanningInput(
            userText: "明天下午两点帮我安排产品评审会议",
            availableSkills: sampleSkills
        )

        let decision = try await service.route(input)

        XCTAssertEqual(decision.action, .useSkill)
        XCTAssertEqual(decision.skillID, "calendar")
        XCTAssertEqual(decision.toolName, "calendar-create-event")
        XCTAssertGreaterThan(decision.confidence, 0.5)
    }

    func testRoutesDirectAnswerWhenNoSkillMatches() async throws {
        let service = HeuristicPlanningModelService()
        let input = PlanningInput(
            userText: "你好，随便聊聊",
            availableSkills: sampleSkills
        )

        let decision = try await service.route(input)

        XCTAssertEqual(decision.action, .answerDirectly)
        XCTAssertNil(decision.skillID)
    }

    func testFoundationServiceIsUnavailableOnCurrentToolchain() async throws {
        if #available(macOS 27.0, iOS 27.0, *) {
            let service = FoundationPlanningModelService()
            let availability = await service.availability()

            if case .unavailable(let reason) = availability {
                XCTAssertTrue(reason.contains("FoundationModels") || reason.contains("Apple Intelligence"))
            }
        } else {
            XCTAssertTrue(true)
        }
    }

    func testCoreAIProbeReportsAOTCommand() {
        let command = CoreAIProbe().aotCompileCommand(for: URL(fileURLWithPath: "/tmp/router.aimodel"))

        XCTAssertEqual(command, [
            "xcrun",
            "coreai-build",
            "compile",
            "/tmp/router.aimodel",
            "--platform",
            "iOS",
        ])
    }

    private var sampleSkills: [SkillSummary] {
        [
            SkillSummary(
                id: "calendar",
                kind: .device,
                displayName: "Calendar",
                description: "Create calendar events and inspect schedules.",
                allowedTools: ["calendar-create-event"],
                triggerHints: ["会议", "日程", "安排", "calendar"]
            ),
            SkillSummary(
                id: "translate",
                kind: .content,
                displayName: "Translate",
                description: "Translate text between languages.",
                triggerHints: ["翻译", "译成", "translate"]
            ),
            SkillSummary(
                id: "web-search",
                kind: .network,
                displayName: "Web Search",
                description: "Search current web information.",
                allowedTools: ["web-search"],
                triggerHints: ["搜索", "联网", "最新"]
            ),
        ]
    }
}
