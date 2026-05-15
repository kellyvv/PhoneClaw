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
    formatter.locale = LanguageService.shared.current.isChinese
        ? Locale(identifier: "zh_Hans_CN")
        : Locale(identifier: "en_US")
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
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // ISO 8601 严格格式必含时间 — 视为 explicit
    if let date = parseISO8601Date(trimmed) {
        return (date, hasExplicitTime: true)
    }

    guard let date = parseDateTimeWithDataDetector(trimmed, anchor: anchor) else {
        return nil
    }

    // 启发式: 解析后是 12:00:00 整 + 输入 ≤ 4 字 → 大概率 NSDataDetector 给纯日期
    // 输入补的默认正午 ("今天"/"明天"/"后天"/"5月3日" 都 ≤4 字, 解析后都 12:00).
    // 用户真说了"中午十二点" 是 5 字, 不会被这个启发式拦.
    var calendar = Calendar.current
    calendar.timeZone = .current
    let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
    let isExactNoon = comps.hour == 12 && comps.minute == 0 && comps.second == 0
    let isShortInput = trimmed.count <= 4
    let hasExplicitTime = !(isExactNoon && isShortInput)
    return (date, hasExplicitTime: hasExplicitTime)
}

private func parseDateTimeWithDataDetector(_ raw: String, anchor: Date) -> Date? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    else { return nil }
    let range = NSRange(raw.startIndex..., in: raw)
    let matches = detector.matches(in: raw, range: range)
    // 取第一个匹配 (最高置信度). NSDataDetector 内部用 anchor=now 做相对计算.
    return matches.first?.date
}
