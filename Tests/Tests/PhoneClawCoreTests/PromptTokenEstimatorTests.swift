import XCTest
@testable import PhoneClawCore

// MARK: - PromptTokenEstimator tests
//
// Plan §九 Phase 3 — replace the crude `chars / 4.0` estimator with a
// mixed-script aware one (CJK 1.5 chars/token vs Latin 4.0).
//
// Invariants under test:
//   - Empty string returns 1 (min token floor)
//   - Pure ASCII follows chars / 4.0
//   - Pure Chinese follows chars / 1.5
//   - Mixed content weights linearly between the two
//   - Result is always an integer >= 1
//   - Counts character classes correctly (汉字 / 假名 / 韩文 / 全角标点)

final class PromptTokenEstimatorTests: XCTestCase {

    func testEmptyStringReturnsOne() {
        XCTAssertEqual(PromptTokenEstimator.estimate(""), 1)
    }

    func testSingleCharFloor() {
        // 1 char / 4.0 = 0.25 → rounded up = 1 (floor)
        XCTAssertEqual(PromptTokenEstimator.estimate("a"), 1)
        // 1 CJK char / 1.5 = 0.67 → rounded up = 1
        XCTAssertEqual(PromptTokenEstimator.estimate("中"), 1)
    }

    func testPureAsciiUsesQuarterRatio() {
        // 100 ascii chars / 4.0 = 25 tokens
        let prompt = String(repeating: "a", count: 100)
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 25)
    }

    func testPureChineseUsesOnePointFiveRatio() {
        // 30 汉字 / 1.5 = 20 tokens
        let prompt = String(repeating: "中", count: 30)
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 20)
    }

    func testMixedContentAddsLinearly() {
        // 60 ascii (60/4=15) + 30 CJK (30/1.5=20) = 35 tokens
        let prompt = String(repeating: "a", count: 60) + String(repeating: "中", count: 30)
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 35)
    }

    func testCJKRangeIncludesHiragana() {
        // ひらがな = 4 hiragana chars / 1.5 = 2.67 → rounded up = 3
        let prompt = "ひらがな"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 3)
    }

    func testCJKRangeIncludesKatakana() {
        // カタカナ = 4 katakana chars / 1.5 = 2.67 → rounded up = 3
        let prompt = "カタカナ"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 3)
    }

    func testCJKRangeIncludesHangul() {
        // 안녕하세요 = 5 hangul / 1.5 = 3.33 → rounded up = 4
        let prompt = "안녕하세요"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 4)
    }

    func testCJKRangeIncludesFullwidthPunctuation() {
        // 3 fullwidth punctuation (in 0xFF00–0xFFEF range)
        // 3 / 1.5 = 2 → 2 tokens
        let prompt = "，。！"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 2)
    }

    func testHalfwidthPunctuationCountsAsLatin() {
        // ASCII punctuation: 4 chars / 4.0 = 1 token
        let prompt = ",.!?"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 1)
    }

    func testNewlinesAndWhitespaceCountAsLatin() {
        // 8 whitespace chars / 4.0 = 2 tokens
        let prompt = "    \n\n\t\t"
        XCTAssertEqual(PromptTokenEstimator.estimate(prompt), 2)
    }

    func testRealisticChinesePromptInsideExpectedRange() {
        // Realistic 100-char Chinese prompt should estimate roughly 60-70 tokens.
        // (100/1.5 = 66.7 → 67)
        let prompt = String(repeating: "你好世界这是一个测试", count: 10)  // exactly 100 chars
        XCTAssertEqual(prompt.count, 100)
        let tokens = PromptTokenEstimator.estimate(prompt)
        XCTAssertEqual(tokens, 67, "100 CJK chars should estimate ~67 tokens (100/1.5)")
    }

    func testEstimatorIsDeterministic() {
        // Same input → same output every time.
        let prompt = "Hello 世界 안녕"
        let firstRun = PromptTokenEstimator.estimate(prompt)
        for _ in 0..<10 {
            XCTAssertEqual(PromptTokenEstimator.estimate(prompt), firstRun)
        }
    }

    func testLegacyEstimatorComparison() {
        // For a Chinese-heavy prompt, new estimator should report MORE tokens
        // than legacy `chars / 4.0` (which under-counted CJK).
        // 100 汉字: new = 100/1.5 = 67; legacy = 100/4 = 25
        let prompt = String(repeating: "中", count: 100)
        let newEstimate = PromptTokenEstimator.estimate(prompt)
        let legacyEstimate = max(1, Int((Double(prompt.count) / 4.0).rounded(.up)))
        XCTAssertGreaterThan(
            newEstimate,
            legacyEstimate,
            "new estimator should report more tokens for Chinese (legacy under-counted)"
        )
        XCTAssertEqual(newEstimate, 67)
        XCTAssertEqual(legacyEstimate, 25)
    }
}
