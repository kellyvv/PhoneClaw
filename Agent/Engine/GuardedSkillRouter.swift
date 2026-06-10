import Foundation

struct GuardedSkillRouteDecision: Equatable {
    enum Action: String, Equatable {
        case answerDirectly
        case useSkill
    }

    let action: Action
    let skillID: String?
    let reason: String
}

enum GuardedSkillRouter {
    static func route(
        for userQuestion: String,
        enabledSkillIDs: Set<String>,
        canonicalSkillID: (String) -> String = { $0 }
    ) -> GuardedSkillRouteDecision? {
        let normalized = userQuestion
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if directAnswerRequest(normalized) {
            return GuardedSkillRouteDecision(
                action: .answerDirectly,
                skillID: nil,
                reason: "direct_answer"
            )
        }

        let calendarSkillID = canonicalSkillID("calendar")
        if let reason = calendarRouteReason(for: normalized),
           enabledSkillIDs.contains(calendarSkillID) {
            return GuardedSkillRouteDecision(
                action: .useSkill,
                skillID: calendarSkillID,
                reason: reason
            )
        }

        let remindersSkillID = canonicalSkillID("reminders")
        if reminderRequest(normalized),
           enabledSkillIDs.contains(remindersSkillID) {
            return GuardedSkillRouteDecision(
                action: .useSkill,
                skillID: remindersSkillID,
                reason: "reminder_intent"
            )
        }

        let translateSkillID = canonicalSkillID("translate")
        if translateRequest(normalized),
           enabledSkillIDs.contains(translateSkillID) {
            return GuardedSkillRouteDecision(
                action: .useSkill,
                skillID: translateSkillID,
                reason: "translate_intent"
            )
        }

        return nil
    }

    private static func directAnswerRequest(_ text: String) -> Bool {
        guard containsAny(text, [
            "解释", "介绍", "什么是", "是什么", "为什么", "原理", "定义",
            "explain", "what is", "why"
        ]) else {
            return false
        }

        return !translateRequest(text)
            && !containsAny(text, [
                "安排", "创建", "添加", "新建", "预约", "约会", "日程", "提醒",
                "待办", "schedule", "book", "remind"
            ])
    }

    private static func calendarRouteReason(for text: String) -> String? {
        let hasTime = hasDateOrTimeSignal(text)
        let hasScheduleVerb = containsAny(text, [
            "安排", "创建", "添加", "新建", "定个", "定一下", "约一下", "预约",
            "schedule", "book", "set up"
        ])
        let hasCalendarQuery = containsAny(text, [
            "日程", "行程", "空闲", "忙不忙", "有没有空", "calendar"
        ])
        let hasMeetingNoun = containsAny(text, [
            "会议", "开会", "约会", "碰面", "碰头", "会面", "评审会", "同步会",
            "例会", "周会", "晨会", "meeting"
        ])
        let hasPeopleMeetingHint = containsAny(text, ["见", "聊", "面谈", "碰一下"])

        if hasCalendarQuery {
            return "calendar_query"
        }
        if hasMeetingNoun && (hasTime || hasScheduleVerb) {
            return hasTime ? "calendar_intent_time" : "calendar_intent"
        }
        if hasScheduleVerb && hasTime && hasPeopleMeetingHint {
            return "calendar_schedule_time"
        }
        return nil
    }

    private static func reminderRequest(_ text: String) -> Bool {
        containsAny(text, [
            "提醒", "待办", "记得", "提示", "叫我", "喊我", "remind me"
        ]) && hasDateOrTimeSignal(text)
    }

    private static func translateRequest(_ text: String) -> Bool {
        containsAny(text, [
            "翻译", "译成", "翻成", "译为", "中译英", "英译中",
            "translate", "translation", "用英语", "用英文", "用日语", "用韩语",
            "用法语", "用德语", "用西语", "英文怎么说", "英语怎么说", "日语怎么说"
        ])
    }

    private static func hasDateOrTimeSignal(_ text: String) -> Bool {
        if containsAny(text, [
            "今天", "明天", "后天", "大后天", "今晚", "明早", "上午", "下午",
            "中午", "晚上", "凌晨", "早上", "点", "半", "刻", "周", "星期",
            "礼拜", "月", "号", "日", "today", "tomorrow", "tonight",
            "morning", "afternoon", "evening", "am", "pm"
        ]) {
            return true
        }

        let patterns = [
            #"(?<!\d)([01]?\d|2[0-3])[:：][0-5]\d(?!\d)"#,
            #"(?<!\d)\d{1,2}\s*(am|pm)(?![a-z])"#,
            #"(?<!\d)\d{1,2}\s*月\s*\d{1,2}\s*(号|日)?"#
        ]
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { needle in
            containsAsWord(needle.lowercased(), in: text)
        }
    }

    private static func containsAsWord(_ trigger: String, in text: String) -> Bool {
        let isAsciiWord = !trigger.isEmpty && trigger.unicodeScalars.allSatisfy { scalar in
            (scalar.value < 128) && (
                CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "-" || scalar == "_"
            )
        }
        guard isAsciiWord else {
            return text.contains(trigger)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text.contains(trigger)
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
