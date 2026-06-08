import XCTest

/// Source-contract guards for the web-grounded answer path.
///
/// These assert the *shape* of the prompt/validator contract (a stable, scannable
/// two-section answer) and — for the recency rework — that explicitly stale
/// dated results do not enter the grounded evidence chain for time-sensitive
/// questions. The actual recency math/behavior is covered deterministically by
/// `WebFreshnessTests`.
final class WebGroundedAnswerContractTests: XCTestCase {
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

    // MARK: The answer is still a scannable, two-section grounded reply

    func testWebSearchAnswerPromptRequiresScannableStructure() throws {
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        XCTAssertTrue(promptBuilder.contains("不要写成单段长文"))
        XCTAssertTrue(promptBuilder.contains("可扫描的结构化 Markdown"))
        XCTAssertTrue(promptBuilder.contains("`- 标签：事实/影响`"))
        XCTAssertTrue(promptBuilder.contains("Use a table only when ranking, comparison, pricing, specifications, or timeline data clearly benefits from it."))

        // News must be enumerated as distinct dated events, not collapsed by theme.
        XCTAssertTrue(promptBuilder.contains("逐条列出 3-6 个不同的事件"))
        XCTAssertTrue(promptBuilder.contains("enumerate 3-6 distinct events"))
        XCTAssertFalse(promptBuilder.contains("多条新闻/趋势按主题合并"))
    }

    // MARK: Freshness is a retrieval contract, with honest answer synthesis

    func testWebSearchAnswerPromptTreatsRecencyAsOrderingNotRefusal() throws {
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        // Synthesis contract: order newest-first, state publish dates, and never
        // claim stale items are same-day.
        XCTAssertTrue(promptBuilder.contains("时效性用于排序而不是拒答"))
        XCTAssertTrue(promptBuilder.contains("先给最新的相关条目并标注其发布时间"))
        XCTAssertTrue(promptBuilder.contains("没有找到严格满足时间约束的，以下是检索到的最新内容"))
        XCTAssertTrue(promptBuilder.contains("Use recency to order, not to refuse"))

        // Regression: the old literal-freshness refusal gate must be gone.
        XCTAssertFalse(promptBuilder.contains("freshness_relevant_result_count"))
        XCTAssertFalse(promptBuilder.contains("freshness_relevant 不是 false"))
        XCTAssertFalse(promptBuilder.contains("low freshness relevance"))
    }

    func testWebAnswerRepairPromptKeepsStructureAndDropsFreshnessGate() throws {
        let promptBuilder = try source("LLM/PromptBuilder.swift")

        XCTAssertTrue(promptBuilder.contains("你正在修复一个联网搜索回答"))
        XCTAssertTrue(promptBuilder.contains("“总结”必须是可扫描的结构化 Markdown"))
        XCTAssertTrue(promptBuilder.contains("时效性用于排序而不是拒答：先给最新的相关条目并标注其发布时间"))
        XCTAssertTrue(promptBuilder.contains("Recency orders, it does not refuse"))
        XCTAssertFalse(promptBuilder.contains("freshness_relevant=false"))
    }

    // MARK: Grounded validator enforces scannable two-section structure

    func testGroundedAnswerValidatorEnforcesStructureAndSummaryHeading() throws {
        let toolChain = try source("Agent/Engine/ToolChain.swift")

        // Structure is still enforced.
        XCTAssertTrue(toolChain.contains("webAnswerLooksUnstructured"))
        XCTAssertTrue(toolChain.contains("总结正文是单段长文，缺少可扫描结构。"))
        XCTAssertTrue(toolChain.contains("lacks scannable structure"))
        // The deterministic post-processor adds "总结"/"Summary" if the model
        // omits it, and the validator rejects answers that still lack it.
        XCTAssertTrue(toolChain.contains("ensureLeadingSummaryHeading"))
        XCTAssertTrue(toolChain.contains("isSummarySectionHeading"))
        XCTAssertTrue(toolChain.contains("缺少独立的“总结”段。"))
        XCTAssertTrue(toolChain.contains("Missing separate Summary section."))
    }

    // MARK: Citations filter on relevance, quality, and stale dated evidence

    func testGroundedSourcesFilterLowRelevanceAndStaleDatedResults() throws {
        let toolChain = try source("Agent/Engine/ToolChain.swift")

        XCTAssertTrue(toolChain.contains("detailSourceKeys"))
        XCTAssertTrue(toolChain.contains("isUsableSourceResult"))
        XCTAssertTrue(toolChain.contains("result[\"query_relevant\"] as? Bool == false"))
        XCTAssertTrue(toolChain.contains("result[\"confidence\"] as? String == \"low\""))
        XCTAssertTrue(toolChain.contains("result[\"is_homepage_like\"] as? Bool == true"))
        XCTAssertTrue(toolChain.contains("sourceItemFreshEnough"))
        XCTAssertTrue(toolChain.contains("WebFreshness.isWithinWindow(date: sourceDate"))
        XCTAssertTrue(toolChain.contains("emptySourceSection"))

        // Old literal freshness flags should not exist; the generic window/date
        // contract replaces them.
        XCTAssertFalse(toolChain.contains("result[\"freshness_relevant\"] as? Bool == false"))
    }

    // MARK: Web handler does generic stale-date filtering, not a literal-date gate

    func testWebHandlerUsesGenericFreshnessFilteringNotLiteralDateGate() throws {
        let webHandler = try source("Tools/Handlers/Web.swift")

        // New: time-filter at retrieval, parse provider/source-visible dates,
        // freshness-filter stale dated results, and expose freshness metadata.
        XCTAssertTrue(webHandler.contains("WebFreshness.window(for: originalQuestion)"))
        XCTAssertTrue(webHandler.contains("duckDuckGoFilter"))
        XCTAssertTrue(webHandler.contains("WebFreshness.recencyBoost"))
        XCTAssertTrue(webHandler.contains("WebFreshness.parsePublishedDate"))
        XCTAssertTrue(webHandler.contains("freshnessFilteredSearchResults"))
        XCTAssertTrue(webHandler.contains("searchResultSourceDate"))
        XCTAssertTrue(webHandler.contains("\"freshness_ok\""))
        XCTAssertTrue(webHandler.contains("extractPublishedAt"))
        XCTAssertTrue(webHandler.contains("\"freshest_published_at\""))
        XCTAssertTrue(webHandler.contains("\"published_at\""))

        // Regression: the literal-date gate and insufficient-on-freshness logic are gone.
        XCTAssertFalse(webHandler.contains("freshness_relevant"))
        XCTAssertFalse(webHandler.contains("lacksFreshnessEvidence"))
        XCTAssertFalse(webHandler.contains("searchResultFreshnessMatches"))
        XCTAssertFalse(webHandler.contains("queryRequiresCurrentDay"))
        XCTAssertFalse(webHandler.contains("textContainsCurrentDayEvidence"))
    }

    func testWebHandlerAvoidsRepeatedDuckDuckGoTimeouts() throws {
        let webHandler = try source("Tools/Handlers/Web.swift")

        XCTAssertTrue(webHandler.contains("SearchProviderCircuitBreaker"))
        XCTAssertTrue(webHandler.contains("provider cooling down after repeated timeouts"))
        XCTAssertTrue(webHandler.contains("skipped: enough results from RSS providers"))
        XCTAssertTrue(webHandler.contains("fetchText(url: url, accept: \"text/html\", timeout: 4)"))

        let bingIndex = webHandler.range(of: "(\"bing-rss\", searchBingRSS)")?.lowerBound
        let newsIndex = webHandler.range(of: "(\"bing-news-rss\", searchBingNewsRSS)")?.lowerBound
        let ddgIndex = webHandler.range(of: "(\"duckduckgo-html\", searchDuckDuckGo)")?.lowerBound
        XCTAssertNotNil(bingIndex)
        XCTAssertNotNil(newsIndex)
        XCTAssertNotNil(ddgIndex)
        XCTAssertLessThan(bingIndex!, ddgIndex!)
        XCTAssertLessThan(newsIndex!, ddgIndex!)
    }

    // MARK: Structured fallback reply unchanged

    func testGroundedFallbackReplyIsStructured() throws {
        let toolChain = try source("Agent/Engine/ToolChain.swift")

        // Fallback stays scannable (bulleted); final web answer post-processing
        // owns the visible "总结"/"Summary" heading.
        XCTAssertTrue(toolChain.contains("- 结果：这次工具返回了可检查的来源"))
        XCTAssertTrue(toolChain.contains("- 结论：我找到了可用的搜索证据"))
        XCTAssertTrue(toolChain.contains("- Result: The tool returned checkable sources"))
        XCTAssertTrue(toolChain.contains("- Conclusion: I found usable search evidence"))
    }
}
