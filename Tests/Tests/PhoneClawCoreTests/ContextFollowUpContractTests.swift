import XCTest

final class ContextFollowUpContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PhoneClawCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testRecentContextArtifactShapeIsExplicit() throws {
        let router = try source("Agent/Engine/Router.swift")

        XCTAssertTrue(router.contains("struct RecentContextArtifact"))
        XCTAssertTrue(router.contains("case assistantAnswer = \"assistant_answer\""))
        XCTAssertTrue(router.contains("case toolResult = \"tool_result\""))
        XCTAssertTrue(router.contains("case imageAnswer = \"image_answer\""))
        XCTAssertTrue(router.contains("case generatedContent = \"generated_content\""))
        XCTAssertTrue(router.contains("let sourceMessageID: UUID"))
        XCTAssertTrue(router.contains("let supportsRefresh: Bool"))
        XCTAssertTrue(router.contains("let createdAt: Date"))
        XCTAssertTrue(router.contains("func latestPriorContextArtifact() -> RecentContextArtifact?"))
    }

    func testContextIntentContractsExist() throws {
        let router = try source("Agent/Engine/Router.swift")
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        XCTAssertTrue(router.contains("case elaborateLastResult = \"elaborate_last_result\""))
        XCTAssertTrue(router.contains("case transformLastResult = \"transform_last_result\""))
        XCTAssertTrue(promptBuilder.contains("- elaborate_last_result:"))
        XCTAssertTrue(promptBuilder.contains("- transform_last_result:"))
        XCTAssertTrue(promptBuilder.contains("should_execute_tool 必须是 false"))
        XCTAssertTrue(promptBuilder.contains("提供了新的待处理正文"))
        XCTAssertTrue(promptBuilder.contains("act 必须是 new_task"))
    }

    func testContextCompilerForbidsToolCallsAndPreservesArtifact() throws {
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        XCTAssertTrue(promptBuilder.contains("buildPreviousContextArtifactReplyPrompt"))
        XCTAssertTrue(promptBuilder.contains("不要调用工具"))
        XCTAssertTrue(promptBuilder.contains("不要输出 `<tool_call>`"))
        XCTAssertTrue(promptBuilder.contains("previousVisibleAnswer"))
        XCTAssertTrue(promptBuilder.contains("上一轮展示给用户的回答"))
        XCTAssertTrue(promptBuilder.contains("整理时保留相关来源"))
        XCTAssertTrue(promptBuilder.contains("只要下面提供了上一轮内容"))
        XCTAssertTrue(promptBuilder.contains("enableThinking: Bool = false"))
        XCTAssertTrue(promptBuilder.contains("let thinkingPrefix = enableThinking ? \"<|think|>\" : \"\""))
        XCTAssertTrue(promptBuilder.contains("thinkingLanguageInstruction"))
    }

    func testProcessInputRoutesContextOperationsBeforeNormalChat() throws {
        let processInput = try source("Agent/Engine/ProcessInput.swift")

        XCTAssertTrue(processInput.contains("forcedContextAct: DialogueAct? = nil"))
        XCTAssertTrue(processInput.contains("latestPriorContextArtifact()"))
        XCTAssertTrue(processInput.contains("classifyContextOperation("))
        XCTAssertTrue(processInput.contains("answerFromPriorContextArtifact("))
        XCTAssertTrue(processInput.contains(".elaborateLastResult"))
        XCTAssertTrue(processInput.contains(".transformLastResult"))
        XCTAssertTrue(processInput.contains("previousArtifact.supportsRefresh"))
    }

    func testContextArtifactFollowUpHonorsThinkingMode() throws {
        let router = try source("Agent/Engine/Router.swift")
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        XCTAssertTrue(promptBuilder.contains("\\(thinkingPrefix)\\(defaultSystemPrompt)"))
        XCTAssertTrue(router.contains("enableThinking: effectiveEnableThinking"))
        XCTAssertTrue(router.contains("shape: effectiveEnableThinking ? .thinking : .lightFull"))
        XCTAssertTrue(router.contains("PromptBuilder.sanitizedAssistantHistoryContent(cleanOutput(rawReply))"))
    }

    func testFollowUpSuggestionsCarryOperationAndTarget() throws {
        let responseUI = try source("UI/ResponseUI.swift")
        let contentView = try source("UI/ContentView.swift")

        XCTAssertTrue(responseUI.contains("let contextAct: DialogueAct?"))
        XCTAssertTrue(responseUI.contains("let targetItemID: UUID?"))
        XCTAssertTrue(contentView.contains("pendingContextFollowUpTargetItemID"))
        XCTAssertTrue(contentView.contains("targetItemID: item.id"))
        XCTAssertTrue(contentView.contains("contextAct: .transformLastResult"))
        XCTAssertTrue(contentView.contains("帮我结构化"))
        XCTAssertTrue(contentView.contains("pendingContextFollowUpTargetItemID == lastDisplayItemID"))
    }
}
