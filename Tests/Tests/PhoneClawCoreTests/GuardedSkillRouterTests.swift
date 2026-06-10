import XCTest
@testable import PhoneClawCore

final class GuardedSkillRouterTests: XCTestCase {
    private let enabledSkills: Set<String> = ["calendar", "reminders", "translate"]

    func testCalendarMeetingWithRelativeTimeRoutesToCalendar() {
        let decision = GuardedSkillRouter.route(
            for: "明天下午两点产品评审会",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertEqual(decision?.action, .useSkill)
        XCTAssertEqual(decision?.skillID, "calendar")
        XCTAssertEqual(decision?.reason, "calendar_intent_time")
    }

    func testDirectAnswerQuestionBlocksSkillRouting() {
        let decision = GuardedSkillRouter.route(
            for: "解释一下什么是本地模型",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertEqual(decision?.action, .answerDirectly)
        XCTAssertNil(decision?.skillID)
        XCTAssertEqual(decision?.reason, "direct_answer")
    }

    func testReminderWithTimeRoutesToReminders() {
        let decision = GuardedSkillRouter.route(
            for: "明天上午提醒我给客户发材料",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertEqual(decision?.action, .useSkill)
        XCTAssertEqual(decision?.skillID, "reminders")
        XCTAssertEqual(decision?.reason, "reminder_intent")
    }

    func testTranslateRequestRoutesToTranslate() {
        let decision = GuardedSkillRouter.route(
            for: "把这句话翻译成英文",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertEqual(decision?.action, .useSkill)
        XCTAssertEqual(decision?.skillID, "translate")
        XCTAssertEqual(decision?.reason, "translate_intent")
    }

    func testMeetingWithoutTimeOrVerbDoesNotRoute() {
        let decision = GuardedSkillRouter.route(
            for: "产品评审会",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertNil(decision)
    }

    func testOrdinaryChatDoesNotRoute() {
        let decision = GuardedSkillRouter.route(
            for: "今天心情不错",
            enabledSkillIDs: enabledSkills
        )

        XCTAssertNil(decision)
    }

    func testDisabledSkillDoesNotRoute() {
        let decision = GuardedSkillRouter.route(
            for: "明天下午两点产品评审会",
            enabledSkillIDs: ["reminders", "translate"]
        )

        XCTAssertNil(decision)
    }

    func testCanonicalSkillMappingIsApplied() {
        let decision = GuardedSkillRouter.route(
            for: "明天下午两点产品评审会",
            enabledSkillIDs: ["calendar_v2"],
            canonicalSkillID: { raw in raw == "calendar" ? "calendar_v2" : raw }
        )

        XCTAssertEqual(decision?.action, .useSkill)
        XCTAssertEqual(decision?.skillID, "calendar_v2")
    }
}
