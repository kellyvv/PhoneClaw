import Foundation

// MARK: - JSON Utilities

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"success\": false, \"error\": \"JSON 编码失败\"}"
    }
    return string
}

// MARK: - Tool Result Payloads

func successPayload(
    result: String,
    extras: [String: Any] = [:]
) -> String {
    var payload = extras
    payload["success"] = true
    payload["status"] = "succeeded"
    payload["result"] = result
    return jsonString(payload)
}

func failurePayload(error: String, extras: [String: Any] = [:]) -> String {
    var payload = extras
    payload["success"] = false
    payload["status"] = "failed"
    payload["error"] = error
    return jsonString(payload)
}

func canonicalToolResult(
    toolName: String,
    toolResult: String
) -> CanonicalToolResult {
    let trimmed = toolResult.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return CanonicalToolResult(
            success: true,
            summary: tr(
                "已完成，但没有返回可展示的内容。",
                "Done, but there was no displayable result."
            ),
            detail: ""
        )
    }

    if let data = trimmed.data(using: .utf8),
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let success = payload["success"] as? Bool,
           !success {
            let errorText = (payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CanonicalToolResult(
                success: false,
                summary: errorText.isEmpty
                    ? tr("这项操作没有完成。",
                         "This action could not be completed.")
                    : tr("这项操作没有完成：\(errorText)",
                         "This action could not be completed: \(errorText)"),
                detail: trimmed,
                errorCode: payload["error_code"] as? String
            )
        }

        if let result = payload["result"] as? String {
            let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return CanonicalToolResult(
                    success: true,
                    summary: summary,
                    detail: trimmed
                )
            }
        }
    }

    return CanonicalToolResult(
        success: true,
        summary: trimmed,
        detail: trimmed
    )
}

// MARK: - Date Helpers

func parseISO8601Date(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let isoFormatters: [ISO8601DateFormatter] = [
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }(),
        {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    ]

    for formatter in isoFormatters {
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    let formats = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm"
    ]

    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }

    return nil
}

func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func displayDateTimeString(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = LanguageService.shared.current.isJapanese
        ? Locale(identifier: "ja_JP")
        : (LanguageService.shared.current.isChinese
            ? Locale(identifier: "zh_Hans_CN")
            : Locale(identifier: "en_US"))
    formatter.timeZone = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

// MARK: - Flexible Tool DateTime Parsing
//
// 设计原则: SKILL/TOOL 契约按**最低能力的模型**来设计. 弱模型 (E2B 2B) 不会
// 把"明天下午两点"算成 ISO 8601, 但能复制原字符串; tool 自己接住任何合理的
// 时间表达式.
//
// 这里**不写规则化的中文解析器** (上一版尝试过 — 几百行 regex/数字/时段映射,
// 覆盖不全 + 维护成本高). 改用 Apple 自带的 NSDataDetector — 跨语言 (中/英)、
// 系统级、零维护. 它处理不了的就让 tool 返失败, 让模型问用户.
//
// 解析顺序:
//   1. parseISO8601Date — 强模型 (E4B+) 直接给 ISO 8601, 0 开销
//   2. NSDataDetector — Apple 内置, 处理常见自然语言时间表达
//
// 任何一步成功就返回, 都失败才返回 nil → tool 走 failurePayload → 模型问用户.

enum SlotKind: String {
    case temporal
    case person
    case location
    case quantity
    case content
    case appEntity
}

enum SlotResolutionStatus: String {
    case resolved
    case missing
    case ambiguous
    case unresolved
}

struct SlotProvenance {
    let sourceText: String
    let resolverID: String
    let method: String
    let confidence: Double
}

struct TemporalSlotValue {
    let date: Date
    let hasExplicitTime: Bool
}

struct TemporalSlotResolution {
    let kind: SlotKind
    let status: SlotResolutionStatus
    let value: TemporalSlotValue?
    let provenance: SlotProvenance?
    let message: String?

    static func resolved(
        date: Date,
        hasExplicitTime: Bool,
        sourceText: String,
        method: String,
        confidence: Double
    ) -> TemporalSlotResolution {
        TemporalSlotResolution(
            kind: .temporal,
            status: .resolved,
            value: TemporalSlotValue(date: date, hasExplicitTime: hasExplicitTime),
            provenance: SlotProvenance(
                sourceText: sourceText,
                resolverID: TemporalSlotResolver.resolverID,
                method: method,
                confidence: confidence
            ),
            message: nil
        )
    }

    static func unresolved(_ sourceText: String, message: String) -> TemporalSlotResolution {
        TemporalSlotResolution(
            kind: .temporal,
            status: .unresolved,
            value: nil,
            provenance: SlotProvenance(
                sourceText: sourceText,
                resolverID: TemporalSlotResolver.resolverID,
                method: "none",
                confidence: 0
            ),
            message: message
        )
    }
}

enum TemporalSlotResolver {
    static let resolverID = "temporal.foundation.detector.v1"

    static func resolve(_ raw: String, anchor: Date = Date()) -> TemporalSlotResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unresolved(raw, message: "empty temporal expression")
        }

        if let date = parseISO8601Date(trimmed) {
            return .resolved(
                date: date,
                hasExplicitTime: true,
                sourceText: trimmed,
                method: "iso8601",
                confidence: 1
            )
        }

        if let omittedMonthDate = parseOmittedMonthDayDateTime(trimmed, anchor: anchor) {
            return .resolved(
                date: omittedMonthDate.date,
                hasExplicitTime: omittedMonthDate.hasExplicitTime,
                sourceText: trimmed,
                method: "omitted_month_day",
                confidence: omittedMonthDate.hasExplicitTime ? 0.86 : 0.74
            )
        }

        if let englishTime = parseEnglishTimeOnly(trimmed, anchor: anchor) {
            return .resolved(
                date: englishTime,
                hasExplicitTime: true,
                sourceText: trimmed,
                method: "english_time_only",
                confidence: 0.82
            )
        }

        guard let date = parseDateTimeWithDataDetector(trimmed, anchor: anchor) else {
            return .unresolved(trimmed, message: "no date detector match")
        }

        var calendar = Calendar.current
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let isExactNoon = comps.hour == 12 && comps.minute == 0 && comps.second == 0
        let isShortInput = trimmed.count <= 4
        let hasExplicitTime = !(isExactNoon && isShortInput)

        return .resolved(
            date: date,
            hasExplicitTime: hasExplicitTime,
            sourceText: trimmed,
            method: "data_detector",
            confidence: hasExplicitTime ? 0.78 : 0.68
        )
    }
}

func parseToolDateTime(_ raw: String, anchor: Date = Date()) -> Date? {
    parseToolDateTimeDetailed(raw, anchor: anchor)?.date
}

/// 比 parseToolDateTime 更细 — 同时返回"用户是否给了具体时间".
///
/// 信号: NSDataDetector 对纯日期输入 (如 "今天" / "明天" / "5月3日") 默认补正午 12:00:00;
/// 对带时间的输入会得出真实小时. 结合 raw 长度 (短串更可能是纯日期) 可以判别.
///
/// 这是通用 NLP-风格的日期完整性检测, 不感知具体 SKILL — Calendar / Reminders /
/// 任何要求"用户必须给具体时间"的 tool 都能复用. 不是 SKILL 业务规则.
func parseToolDateTimeDetailed(_ raw: String, anchor: Date = Date()) -> (date: Date, hasExplicitTime: Bool)? {
    guard let value = TemporalSlotResolver.resolve(raw, anchor: anchor).value else {
        return nil
    }
    return (value.date, hasExplicitTime: value.hasExplicitTime)
}

func rawChineseOmittedMonthDayDateTimeExpression(in text: String) -> String? {
    let pattern = #"[一二三四五六七八九十廿卅两〇零0-9]{1,3}\s*(?:号|日)\s*(?:(?:凌晨|早上|上午|中午|下午|傍晚|晚上|今晚|明早)?\s*[一二三四五六七八九十两〇零0-9]{1,3}\s*点\s*(?:[一二三四五六七八九十两〇零0-9]{1,3}\s*分?)?)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          let matchedRange = Range(match.range, in: text) else {
        return nil
    }
    let raw = String(text[matchedRange])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
}

private func parseDateTimeWithDataDetector(_ raw: String, anchor: Date) -> Date? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    else { return nil }
    let range = NSRange(raw.startIndex..., in: raw)
    let matches = detector.matches(in: raw, range: range)
    // 取第一个匹配 (最高置信度). NSDataDetector 内部用 anchor=now 做相对计算.
    return matches.first?.date
}

private func parseEnglishTimeOnly(_ raw: String, anchor: Date) -> Date? {
    let normalized = normalizeEnglishTimeOnly(raw)
    guard !normalized.isEmpty else { return nil }

    let hourWords: [String: Int] = [
        "zero": 0,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
        "eleven": 11,
        "twelve": 12
    ]
    let minuteWords: [String: Int] = [
        "oh five": 5,
        "five": 5,
        "ten": 10,
        "fifteen": 15,
        "quarter": 15,
        "twenty": 20,
        "twenty five": 25,
        "thirty": 30,
        "half": 30,
        "forty": 40,
        "forty five": 45,
        "quarter to": 45,
        "fifty": 50,
        "fifty five": 55
    ]

    let tokens = normalized.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }

    var hour: Int?
    var minute = 0
    var meridiem: String?

    if tokens.count == 1 {
        hour = Int(tokens[0]) ?? hourWords[tokens[0]]
    } else if tokens.count == 2 {
        if let numericHour = Int(tokens[0]), ["am", "pm"].contains(tokens[1]) {
            hour = numericHour
            meridiem = tokens[1]
        } else if let wordHour = hourWords[tokens[0]], ["am", "pm"].contains(tokens[1]) {
            hour = wordHour
            meridiem = tokens[1]
        } else if let wordHour = hourWords[tokens[0]], let wordMinute = minuteWords[tokens[1]] {
            hour = wordHour
            minute = wordMinute
        }
    } else if tokens.count == 3 {
        let minuteText = "\(tokens[1]) \(tokens[2])"
        if let wordHour = hourWords[tokens[0]], let wordMinute = minuteWords[minuteText] {
            hour = wordHour
            minute = wordMinute
        } else if let wordHour = hourWords[tokens[0]],
                  let wordMinute = minuteWords[tokens[1]],
                  ["am", "pm"].contains(tokens[2]) {
            hour = wordHour
            minute = wordMinute
            meridiem = tokens[2]
        }
    } else if tokens.count == 4 {
        let minuteText = "\(tokens[1]) \(tokens[2])"
        if let wordHour = hourWords[tokens[0]],
           let wordMinute = minuteWords[minuteText],
           ["am", "pm"].contains(tokens[3]) {
            hour = wordHour
            minute = wordMinute
            meridiem = tokens[3]
        }
    }

    if hour == nil {
        let parts = normalized.split(separator: ":").map(String.init)
        if parts.count == 2,
           let numericHour = Int(parts[0]),
           let numericMinute = Int(parts[1]),
           (0...59).contains(numericMinute) {
            hour = numericHour
            minute = numericMinute
        }
    }

    guard let parsedHour = hour,
          (0...23).contains(parsedHour),
          (0...59).contains(minute) else {
        return nil
    }

    return nextEnglishTimeOnlyDate(
        hour: parsedHour,
        minute: minute,
        meridiem: meridiem,
        anchor: anchor
    )
}

private func normalizeEnglishTimeOnly(_ raw: String) -> String {
    var text = raw.lowercased()
        .replacingOccurrences(of: #"[\.,!?]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"["'“”‘’]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\bo['’]?clock\b"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\bat\b"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    text = text
        .replacingOccurrences(of: #"(\d)\s*(a\.?m\.?|p\.?m\.?)\b"#, with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: #"a\.?m\.?"#, with: "am", options: .regularExpression)
        .replacingOccurrences(of: #"p\.?m\.?"#, with: "pm", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text
}

private func nextEnglishTimeOnlyDate(
    hour: Int,
    minute: Int,
    meridiem: String?,
    anchor: Date
) -> Date? {
    var calendar = Calendar.current
    calendar.timeZone = .current

    func hour24(_ hour: Int, meridiem: String?) -> [Int] {
        if meridiem == "am" {
            return [hour == 12 ? 0 : hour]
        }
        if meridiem == "pm" {
            return [hour == 12 ? 12 : hour + 12]
        }
        if hour == 0 || hour > 12 {
            return [hour]
        }
        if hour == 12 {
            return [12]
        }
        return [hour, hour + 12]
    }

    let dayStart = calendar.startOfDay(for: anchor)
    for dayOffset in 0...2 {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: dayStart) else {
            continue
        }
        for candidateHour in hour24(hour, meridiem: meridiem).sorted() {
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = candidateHour
            components.minute = minute
            components.second = 0
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            guard let candidate = calendar.date(from: components),
                  candidate > anchor else {
                continue
            }
            return candidate
        }
    }

    return nil
}

/// NSDataDetector 对中文“二十九号上午七点三十分”这类省略月份的表达只会匹配
/// “上午七点三十分”, 丢掉“二十九号”。这里补一个窄而通用的兜底:只处理“几号/几日”
/// 没有显式月份的日期, 月份按 anchor 所在月份补齐；如果结果已经过去, 滚到下一个有效月份。
private func parseOmittedMonthDayDateTime(
    _ raw: String,
    anchor: Date
) -> (date: Date, hasExplicitTime: Bool)? {
    guard let dayMatch = firstOmittedMonthDayMatch(in: raw) else {
        return nil
    }

    let hasExplicitTime = containsExplicitTimeCue(raw)
    let matchedOnlyDate = raw.trimmingCharacters(in: .whitespacesAndNewlines).count == dayMatch.matchedText.count
    guard hasExplicitTime || matchedOnlyDate else {
        return nil
    }

    var calendar = Calendar.current
    calendar.timeZone = .current

    let detectorDate = parseDateTimeWithDataDetector(raw, anchor: anchor)
    let timeComponents = detectorDate.map {
        calendar.dateComponents([.hour, .minute, .second], from: $0)
    }

    let hour = hasExplicitTime ? (timeComponents?.hour ?? 12) : 12
    let minute = hasExplicitTime ? (timeComponents?.minute ?? 0) : 0
    let second = hasExplicitTime ? (timeComponents?.second ?? 0) : 0

    return nextDate(
        matchingDay: dayMatch.day,
        hour: hour,
        minute: minute,
        second: second,
        hasExplicitTime: hasExplicitTime,
        anchor: anchor,
        calendar: calendar
    ).map { ($0, hasExplicitTime: hasExplicitTime) }
}

private func firstOmittedMonthDayMatch(in raw: String) -> (day: Int, matchedText: String)? {
    let pattern = #"([0-3]?\d|[０-３]?[０-９]|[零〇一二两三四五六七八九十廿卅]{1,4})(?:号|日)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let nsRange = NSRange(raw.startIndex..., in: raw)
    for match in regex.matches(in: raw, range: nsRange) {
        guard let fullRange = Range(match.range, in: raw),
              let tokenRange = Range(match.range(at: 1), in: raw) else {
            continue
        }

        if fullRange.lowerBound > raw.startIndex {
            let previous = raw[raw.index(before: fullRange.lowerBound)]
            if previous == "月" || previous == "第" {
                continue
            }
        }

        let token = String(raw[tokenRange])
        guard let day = parseChineseDayOfMonthToken(token),
              (1...31).contains(day) else {
            continue
        }

        return (day: day, matchedText: String(raw[fullRange]))
    }

    return nil
}

private func containsExplicitTimeCue(_ raw: String) -> Bool {
    let patterns = [
        #"\d{1,2}\s*[:：]\s*\d{1,2}"#,
        #"[0-9０-９零〇一二两三四五六七八九十]{1,4}\s*(点|時|时)"#,
        #"\b\d{1,2}\s*(am|pm|AM|PM)\b"#
    ]

    return patterns.contains { pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }
}

private func parseChineseDayOfMonthToken(_ token: String) -> Int? {
    let normalized = token
        .replacingOccurrences(of: "两", with: "二")
        .replacingOccurrences(of: "０", with: "0")
        .replacingOccurrences(of: "１", with: "1")
        .replacingOccurrences(of: "２", with: "2")
        .replacingOccurrences(of: "３", with: "3")
        .replacingOccurrences(of: "４", with: "4")
        .replacingOccurrences(of: "５", with: "5")
        .replacingOccurrences(of: "６", with: "6")
        .replacingOccurrences(of: "７", with: "7")
        .replacingOccurrences(of: "８", with: "8")
        .replacingOccurrences(of: "９", with: "9")

    if let value = Int(normalized) {
        return value
    }

    if normalized.hasPrefix("卅") {
        let suffix = String(normalized.dropFirst())
        return 30 + (suffix.isEmpty ? 0 : (chineseDigitValue(suffix) ?? -100))
    }
    if normalized.hasPrefix("廿") {
        let suffix = String(normalized.dropFirst())
        return 20 + (suffix.isEmpty ? 0 : (chineseDigitValue(suffix) ?? -100))
    }
    if normalized == "十" {
        return 10
    }
    if normalized.hasPrefix("十") {
        let suffix = String(normalized.dropFirst())
        return 10 + (suffix.isEmpty ? 0 : (chineseDigitValue(suffix) ?? -100))
    }
    if normalized.hasSuffix("十") {
        let prefix = String(normalized.dropLast())
        return (chineseDigitValue(prefix) ?? -100) * 10
    }
    if let tenIndex = normalized.firstIndex(of: "十") {
        let tensText = String(normalized[..<tenIndex])
        let onesText = String(normalized[normalized.index(after: tenIndex)...])
        let tens = tensText.isEmpty ? 1 : (chineseDigitValue(tensText) ?? -100)
        let ones = onesText.isEmpty ? 0 : (chineseDigitValue(onesText) ?? -100)
        return tens * 10 + ones
    }

    return chineseDigitValue(normalized)
}

private func chineseDigitValue(_ text: String) -> Int? {
    switch text {
    case "零", "〇": return 0
    case "一": return 1
    case "二": return 2
    case "三": return 3
    case "四": return 4
    case "五": return 5
    case "六": return 6
    case "七": return 7
    case "八": return 8
    case "九": return 9
    default: return nil
    }
}

private func nextDate(
    matchingDay day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    hasExplicitTime: Bool,
    anchor: Date,
    calendar: Calendar
) -> Date? {
    guard let currentMonthStart = calendar.dateInterval(of: .month, for: anchor)?.start else {
        return nil
    }

    let anchorDayStart = calendar.startOfDay(for: anchor)
    for monthOffset in 0...12 {
        guard let month = calendar.date(byAdding: .month, value: monthOffset, to: currentMonthStart) else {
            continue
        }
        let monthComponents = calendar.dateComponents([.year, .month], from: month)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = monthComponents.year
        components.month = monthComponents.month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let candidate = calendar.date(from: components) else {
            continue
        }
        let check = calendar.dateComponents([.year, .month, .day], from: candidate)
        guard check.year == components.year,
              check.month == components.month,
              check.day == day else {
            continue
        }

        if hasExplicitTime {
            if candidate > anchor {
                return candidate
            }
        } else if calendar.startOfDay(for: candidate) >= anchorDayStart {
            return candidate
        }
    }

    return nil
}
