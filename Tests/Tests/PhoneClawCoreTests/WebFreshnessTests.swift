import XCTest
@testable import PhoneClawCore

/// Behavior tests for the recency rework. Unlike the string-asserting contract
/// tests, these exercise the real parsing/scoring logic with a fixed `now`, so a
/// regression in *behavior* (not wording) is what fails them.
final class WebFreshnessTests: XCTestCase {

    /// Fixed reference instant so relative-date math is deterministic.
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: Absolute date parsing

    func testParsesRFC822RssPubDate() {
        // This is the exact format Bing/Bing-News RSS emits — the one the old
        // literal-date gate could never match.
        let date = WebFreshness.parsePublishedDate("Fri, 06 Jun 2026 10:30:00 GMT", now: now)
        XCTAssertNotNil(date)
        let other = WebFreshness.parsePublishedDate("Fri, 06 Jun 2026 09:30:00 GMT", now: now)
        XCTAssertNotNil(other)
        XCTAssertGreaterThan(date!, other!) // 10:30 newer than 09:30
    }

    func testParsesChineseLocalizedRssPubDate() {
        // Bing RSS localized to zh emits "周二, 30 12月 2025 15:57:00 GMT". The
        // en_US_POSIX whole-string RFC822 formatters can't read the zh weekday/
        // timezone names, so before the embedded zh-RSS pattern this read as
        // undated — and an undated result escapes recency demotion, letting a
        // 6-month-old page rank for a "today" query (the exact failure seen on
        // a "今天的 AI 新闻" search).
        let stale = WebFreshness.parsePublishedDate("周二, 30 12月 2025 15:57:00 GMT", now: now)
        XCTAssertNotNil(stale)
        let fresh = WebFreshness.parsePublishedDate("2026-06-01", now: now)!
        XCTAssertLessThan(stale!, fresh) // Dec 2025 older than Jun 2026 → demoted, not ranked as fresh
    }

    func testParsesISO8601() {
        XCTAssertNotNil(WebFreshness.parsePublishedDate("2026-06-06T10:30:00Z", now: now))
        XCTAssertNotNil(WebFreshness.parsePublishedDate("2026-06-06T10:30:00.123Z", now: now))
    }

    func testParsesLocalizedAbsoluteFormats() {
        XCTAssertNotNil(WebFreshness.parsePublishedDate("2026年6月6日", now: now))
        XCTAssertNotNil(WebFreshness.parsePublishedDate("2026-06-06", now: now))
        XCTAssertNotNil(WebFreshness.parsePublishedDate("2026/06/06", now: now))
        XCTAssertNotNil(WebFreshness.parsePublishedDate("Jun 6, 2026", now: now))
        XCTAssertNotNil(WebFreshness.parsePublishedDate("June 6, 2026", now: now))
    }

    func testOrdersAbsoluteDatesByRecency() {
        let d6 = WebFreshness.parsePublishedDate("2026-06-06", now: now)!
        let d5 = WebFreshness.parsePublishedDate("2026-06-05", now: now)!
        let d1 = WebFreshness.parsePublishedDate("2026-06-01", now: now)!
        XCTAssertGreaterThan(d6, d5)
        XCTAssertGreaterThan(d5, d1)
    }

    func testExtractsDateEmbeddedInSnippet() {
        let date = WebFreshness.parsePublishedDate("发布于 2026年6月6日 — OpenAI 发布新模型", now: now)
        XCTAssertNotNil(date)
        let en = WebFreshness.parsePublishedDate("Published Jun 6, 2026 by the newsroom", now: now)
        XCTAssertNotNil(en)
    }

    func testReturnsNilForNoDate() {
        XCTAssertNil(WebFreshness.parsePublishedDate("OpenAI announces a new model", now: now))
        XCTAssertNil(WebFreshness.parsePublishedDate("", now: now))
        XCTAssertNil(WebFreshness.parsePublishedDate(nil, now: now))
    }

    // MARK: Relative date parsing

    func testParsesChineseRelativePhrases() {
        assertClose(WebFreshness.parsePublishedDate("3小时前", now: now), now.addingTimeInterval(-3 * 3600))
        assertClose(WebFreshness.parsePublishedDate("30分钟前", now: now), now.addingTimeInterval(-30 * 60))
        assertClose(WebFreshness.parsePublishedDate("2天前", now: now), now.addingTimeInterval(-2 * 86_400))
        assertClose(WebFreshness.parsePublishedDate("刚刚发布", now: now), now)
        assertClose(WebFreshness.parsePublishedDate("昨天", now: now), now.addingTimeInterval(-86_400))
    }

    func testParsesEnglishRelativePhrases() {
        assertClose(WebFreshness.parsePublishedDate("2 hours ago", now: now), now.addingTimeInterval(-2 * 3600))
        assertClose(WebFreshness.parsePublishedDate("5 days ago", now: now), now.addingTimeInterval(-5 * 86_400))
        assertClose(WebFreshness.parsePublishedDate("yesterday", now: now), now.addingTimeInterval(-86_400))
    }

    // MARK: Recency scoring

    func testRecencyScoreDecaysByHalfLife() {
        XCTAssertEqual(WebFreshness.recencyScore(ageSeconds: 0, halfLifeHours: 24), 1.0, accuracy: 0.0001)
        XCTAssertEqual(WebFreshness.recencyScore(ageSeconds: 24 * 3600, halfLifeHours: 24), 0.5, accuracy: 0.001)
        XCTAssertEqual(WebFreshness.recencyScore(ageSeconds: 48 * 3600, halfLifeHours: 24), 0.25, accuracy: 0.001)
    }

    func testRecencyScoreClampsFutureAndVeryOld() {
        XCTAssertEqual(WebFreshness.recencyScore(ageSeconds: -10_000, halfLifeHours: 24), 1.0, accuracy: 0.0001)
        XCTAssertLessThan(WebFreshness.recencyScore(ageSeconds: 365 * 86_400, halfLifeHours: 24), 0.001)
    }

    func testRecencyBoostNeutralWhenDateMissing() {
        // The core anti-regression: a result with no parseable date is NOT
        // penalized — it just gets a neutral 0 boost, so it can still rank on
        // relevance instead of being dropped (the old gate dropped it).
        XCTAssertEqual(WebFreshness.recencyBoost(publishedAt: nil, now: now, window: .day, maxBoost: 100), 0)
        XCTAssertEqual(WebFreshness.recencyBoost(publishedAt: "no date here", now: now, window: .day, maxBoost: 100), 0)
    }

    func testRecencyBoostRewardsFresherEvidence() {
        let fresh = WebFreshness.recencyBoost(
            publishedAt: relative(hoursAgo: 2), now: now, window: .day, maxBoost: 100
        )
        let stale = WebFreshness.recencyBoost(
            publishedAt: relative(hoursAgo: 240), now: now, window: .day, maxBoost: 100
        )
        XCTAssertGreaterThan(fresh, stale)
        XCTAssertGreaterThan(fresh, 50) // 2h with 18h half-life stays high
    }

    func testWindowEligibilityRejectsExplicitlyStaleDatedSignals() {
        XCTAssertTrue(WebFreshness.isWithinWindow(
            date: WebFreshness.parsePublishedDate("2026-06-07", now: now),
            window: .day,
            now: now
        ))
        XCTAssertFalse(WebFreshness.isWithinWindow(
            date: WebFreshness.parsePublishedDate("2025-09-05", now: now),
            window: .day,
            now: now
        ))
        XCTAssertTrue(WebFreshness.isWithinWindow(date: nil, window: .day, now: now))
    }

    func testNewestDatePicksMostRecent() {
        let newest = WebFreshness.newestDate(
            among: ["2026-06-01", "2026-06-06", nil, "2026-06-03", "garbage"],
            now: now
        )
        XCTAssertEqual(newest, WebFreshness.parsePublishedDate("2026-06-06", now: now))
    }

    // MARK: Temporal intent → window → search filter

    func testWindowInference() {
        XCTAssertEqual(WebFreshness.window(for: "今天的 AI 新闻"), .day)
        XCTAssertEqual(WebFreshness.window(for: "today's AI news"), .day)
        XCTAssertEqual(WebFreshness.window(for: "本周 OpenAI 有什么进展"), .week)
        XCTAssertEqual(WebFreshness.window(for: "最近的大模型动态"), .month)
        XCTAssertEqual(WebFreshness.window(for: "iPhone 16 和 15 的区别"), WebFreshness.Window.none)
    }

    func testWindowMapsToDuckDuckGoFilter() {
        XCTAssertEqual(WebFreshness.Window.day.duckDuckGoFilter, "d")
        XCTAssertEqual(WebFreshness.Window.week.duckDuckGoFilter, "w")
        XCTAssertEqual(WebFreshness.Window.month.duckDuckGoFilter, "m")
        XCTAssertNil(WebFreshness.Window.none.duckDuckGoFilter)
    }

    func testWantsFreshness() {
        XCTAssertTrue(WebFreshness.wantsFreshness("今天的新闻"))
        XCTAssertFalse(WebFreshness.wantsFreshness("珠穆朗玛峰有多高"))
    }

    // MARK: Helpers

    private func assertClose(_ actual: Date?, _ expected: Date, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("expected a date, got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 2, file: file, line: line)
    }

    /// Build an ISO timestamp `hoursAgo` before `now` for boost tests.
    private func relative(hoursAgo: Double) -> String {
        let date = now.addingTimeInterval(-hoursAgo * 3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
