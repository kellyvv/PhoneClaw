import Foundation

/// Pure, dependency-free helpers for reasoning about how fresh a web result is.
///
/// Single home for two questions:
///   1. "When was this published?"  → `parsePublishedDate`
///   2. "How much should recency boost this result?" → `recencyScore` / `recencyBoost`
///
/// Extracted so it compiles standalone on macOS (no iOS frameworks, no `tr()` /
/// LanguageService) and can be unit-tested deterministically by passing an
/// explicit `now`.
///
/// Design intent (search-agent recency rework): freshness is a retrieval
/// contract, not a domain-specific keyword rule. We parse a real `Date` from the
/// many formats providers emit (RSS RFC822, ISO8601, localized absolute dates,
/// relative phrases), then use it in two generic ways:
///   - ranking: fresh evidence wins for time-sensitive questions;
///   - eligibility: explicitly stale dated fallback results do not enter the
///     evidence chain for "today/latest/current" questions.
///
/// An unparseable date remains neutral because some engines omit dates on
/// genuinely fresh result pages. A parseable stale date is actionable evidence
/// that the result does not satisfy the user's temporal constraint.
enum WebFreshness {

    // MARK: - Temporal intent

    /// A coarse recency window inferred from the user's question. Used to pick a
    /// search-engine time filter and to weight recency in ranking. This is the
    /// only place that reads temporal *language* — it never gates answering.
    enum Window {
        case day
        case week
        case month
        case none

        /// Half-life (hours) for the exponential recency decay applied to this
        /// window. Shorter window → faster decay → newer evidence dominates.
        var halfLifeHours: Double {
            switch self {
            case .day: return 18      // "today": ~today/yesterday dominate
            case .week: return 84      // "this week": ~3.5d half-life
            case .month: return 360    // "this month": ~15d half-life
            case .none: return 240     // generic freshness: ~10d half-life
            }
        }

        /// DuckDuckGo `df` time-filter value (`d`/`w`/`m`), or nil for no filter.
        var duckDuckGoFilter: String? {
            switch self {
            case .day: return "d"
            case .week: return "w"
            case .month: return "m"
            case .none: return nil
            }
        }

        /// Generic hard window used only for dated results. Undated results are
        /// handled by callers as neutral, because recency-filtered engines often
        /// omit explicit dates.
        var maxAcceptableAgeDays: Int? {
            switch self {
            case .day: return 2
            case .week: return 10
            case .month: return 45
            case .none: return nil
            }
        }
    }

    /// Infer the recency window from a question. Intentionally small — temporal
    /// language only, no domain vocabulary. Anything stronger than "this month"
    /// collapses to `.month` so we never over-narrow the live web.
    static func window(for query: String) -> Window {
        let lower = query.lowercased()
        let dayMarkers = ["今天", "今日", "刚刚", "this morning", "today", "right now", "as of today"]
        if dayMarkers.contains(where: { lower.contains($0) }) { return .day }
        let weekMarkers = ["本周", "这周", "这一周", "近几天", "这几天", "this week", "past few days", "last few days"]
        if weekMarkers.contains(where: { lower.contains($0) }) { return .week }
        let monthMarkers = ["本月", "这个月", "近期", "最近", "近来", "this month", "recent", "recently", "lately"]
        if monthMarkers.contains(where: { lower.contains($0) }) { return .month }
        let looseMarkers = ["现在", "当前", "实时", "最新", "now", "current", "latest", "live", "up to date", "up-to-date"]
        if looseMarkers.contains(where: { lower.contains($0) }) { return .month }
        return .none
    }

    /// Whether the question carries any recency intent at all.
    static func wantsFreshness(_ query: String) -> Bool {
        window(for: query) != .none
    }

    static func window(named raw: String?) -> Window {
        guard let raw = raw?.lowercased() else { return .none }
        switch raw {
        case "day":
            return .day
        case "week":
            return .week
        case "month":
            return .month
        default:
            return .none
        }
    }

    // MARK: - Recency scoring

    /// Age of `date` relative to `now`, in seconds. Negative for future dates.
    static func ageInSeconds(of date: Date, now: Date = Date()) -> Double {
        now.timeIntervalSince(date)
    }

    /// Exponential recency score in `[0, 1]`: 1.0 at age 0, halving every
    /// `halfLifeHours`. Future-dated items clamp to 1.0; very old items approach 0.
    static func recencyScore(ageSeconds: Double, halfLifeHours: Double) -> Double {
        guard halfLifeHours > 0 else { return 0 }
        if ageSeconds <= 0 { return 1 }
        let halfLifeSeconds = halfLifeHours * 3600
        let score = pow(0.5, ageSeconds / halfLifeSeconds)
        return min(1, max(0, score))
    }

    /// Convenience for ranking: parse `publishedAt` and return `maxBoost *
    /// recencyScore` for the given `window`. Returns 0 (neutral) when the date is
    /// missing/unparseable — a missing date neither boosts nor penalizes.
    static func recencyBoost(
        publishedAt: String?,
        now: Date = Date(),
        window: Window,
        maxBoost: Double
    ) -> Double {
        guard let date = parsePublishedDate(publishedAt, now: now) else { return 0 }
        let score = recencyScore(ageSeconds: ageInSeconds(of: date, now: now), halfLifeHours: window.halfLifeHours)
        return maxBoost * score
    }

    static func isWithinWindow(date: Date?, window: Window, now: Date = Date()) -> Bool {
        guard let maxAgeDays = window.maxAcceptableAgeDays else { return true }
        guard let date else { return true }
        let ageDays = Int(ceil(max(0, now.timeIntervalSince(date)) / 86_400))
        return ageDays <= maxAgeDays
    }

    /// The newest parseable date among a set of raw strings, if any.
    static func newestDate(among raws: [String?], now: Date = Date()) -> Date? {
        raws.compactMap { parsePublishedDate($0, now: now) }.max()
    }

    // MARK: - Published-date parsing

    /// Parse a publish/updated timestamp into an absolute `Date`, or nil.
    ///
    /// Order: relative phrases (`刚刚`, `3小时前`, `2 hours ago`, `yesterday`) →
    /// whole-string absolute formats (RFC822, ISO8601, localized) → date-like
    /// substrings embedded in longer text.
    static func parsePublishedDate(_ raw: String?, now: Date = Date()) -> Date? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let date = relativeDate(in: text, now: now) { return date }
        if let date = wholeStringDate(text) { return date }
        if let date = embeddedDate(in: text) { return date }
        return nil
    }

    // MARK: Relative dates

    private static func relativeDate(in text: String, now: Date) -> Date? {
        let lower = text.lowercased()

        if lower.contains("刚刚") || lower.contains("just now") || lower.contains("moments ago") {
            return now
        }
        if lower.contains("前天") { return now.addingTimeInterval(-2 * 86_400) }
        if lower.contains("昨天") || lower.contains("yesterday") { return now.addingTimeInterval(-86_400) }

        // Chinese "<n><unit>前"
        let zhUnits: [(pattern: String, seconds: Double)] = [
            (#"(\d+)\s*分钟前"#, 60),
            (#"(\d+)\s*小时前"#, 3_600),
            (#"(\d+)\s*天前"#, 86_400),
            (#"(\d+)\s*周前"#, 7 * 86_400),
            (#"(\d+)\s*个?月前"#, 30 * 86_400)
        ]
        for unit in zhUnits {
            if let n = firstCaptureInt(unit.pattern, in: lower) {
                return now.addingTimeInterval(-Double(n) * unit.seconds)
            }
        }

        // English "<n> <unit> ago"
        let enUnits: [(pattern: String, seconds: Double)] = [
            (#"(\d+)\s*minutes?\s+ago"#, 60),
            (#"(\d+)\s*hours?\s+ago"#, 3_600),
            (#"(\d+)\s*days?\s+ago"#, 86_400),
            (#"(\d+)\s*weeks?\s+ago"#, 7 * 86_400),
            (#"(\d+)\s*months?\s+ago"#, 30 * 86_400)
        ]
        for unit in enUnits {
            if let n = firstCaptureInt(unit.pattern, in: lower) {
                return now.addingTimeInterval(-Double(n) * unit.seconds)
            }
        }
        return nil
    }

    // MARK: Absolute dates

    private static func wholeStringDate(_ text: String) -> Date? {
        if let date = isoDate(text) { return date }
        for formatter in fixedFormatters where true {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func embeddedDate(in text: String) -> Date? {
        // Pull date-like substrings out of longer snippet/body text, newest-first
        // is not needed here — first parseable wins.
        let candidates: [(pattern: String, format: String)] = [
            (#"\d{4}年\d{1,2}月\d{1,2}日"#, "yyyy年M月d日"),
            // Bing RSS pubDate localized to zh: "周二, 30 12月 2025 15:57:00 GMT".
            // The weekday/timezone names aren't en_US_POSIX-parseable, so the
            // whole-string RFC822 formatters miss it and the result reads as
            // undated → it escapes recency demotion (a 6-month-old page ranking
            // for a "today" query). Extract the numeric "30 12月 2025" core; "月"
            // is a literal in the format, so the day/month/year digits parse
            // locale-free.
            (#"\d{1,2}\s+\d{1,2}月\s+\d{4}"#, "d M月 yyyy"),
            (#"\d{4}-\d{1,2}-\d{1,2}"#, "yyyy-MM-dd"),
            (#"\d{4}/\d{1,2}/\d{1,2}"#, "yyyy/MM/dd"),
            (#"(?i)(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}"#, "MMM d, yyyy")
        ]
        for candidate in candidates {
            guard let match = firstMatch(candidate.pattern, in: text) else { continue }
            let normalized = match.replacingOccurrences(of: ",", with: "")
            let formatter = makeFormatter(candidate.format)
            if let date = formatter.date(from: normalized) { return date }
            // English month abbreviations may be 3-letter ("Jun") or full ("June").
            if candidate.format == "MMM d, yyyy" {
                if let date = makeFormatter("MMMM d yyyy").date(from: normalized) { return date }
                if let date = makeFormatter("MMM d yyyy").date(from: normalized) { return date }
            }
        }
        // RFC822 embedded (e.g. "... Fri, 06 Jun 2026 10:30:00 GMT")
        if let match = firstMatch(#"(?i)[A-Za-z]{3},\s*\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}[\d:\s]*(?:GMT|UTC|[+-]\d{4})?"#, in: text) {
            if let date = wholeStringDate(match.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private static func isoDate(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        return nil
    }

    private static let fixedFormatters: [DateFormatter] = {
        [
            "EEE, dd MMM yyyy HH:mm:ss Z",   // RFC822 with weekday (RSS pubDate)
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy年M月d日 HH:mm",
            "yyyy年M月d日",
            "MMMM d, yyyy",
            "MMM d, yyyy"
        ].map(makeFormatter)
    }()

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }

    // MARK: Regex helpers

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func firstCaptureInt(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }
}
