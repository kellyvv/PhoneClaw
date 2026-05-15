import EventKit
import Foundation

enum RemindersTools {

    static func register(into registry: ToolRegistry) {

        // ── reminders-create ──
        registry.register(RegisteredTool(
            name: "reminders-create",
            description: tr(
                "创建新的提醒事项，可写入标题、到期时间和备注",
                "Create a new reminder with title, due time, and notes."
            ),
            // 设计原则: SKILL/TOOL 契约按最低能力的模型 (E2B 2B) 来. 不要求 LLM 把
            // 中文相对时间转成 ISO 8601 — handler 自己解析任何合理时间表达式.
            parameters: tr(
                "title: 提醒标题, due: 到期时间（可选, 支持 ISO 8601 / 中文相对时间如\"今晚八点\" / 中文绝对时间如\"5月3日15:00\"）, notes: 备注（可选）",
                "title: reminder title, due: due time (optional, supports ISO 8601 or natural language like \"tonight 8pm\" / \"May 3 15:00\"), notes: notes (optional)"
            ),
            requiredParameters: ["title"],
            execute: { args in
                try await createReminderCanonical(args).detail
            },
            executeCanonical: { args in
                try await createReminderCanonical(args)
            }
        ))
    }

    // MARK: - Private Helpers

    private static func writableReminderCalendar() -> EKCalendar? {
        if let calendar = SystemStores.event.defaultCalendarForNewReminders(),
           calendar.allowsContentModifications {
            return calendar
        }

        return SystemStores.event.calendars(for: .reminder)
            .first(where: \.allowsContentModifications)
    }

    private static func newReminderListTitle() -> String {
        let prefersChinese = LanguageService.shared.current.isChinese
        return prefersChinese ? "PhoneClaw 提醒事项" : "PhoneClaw Reminders"
    }

    private static func reminderCalendarCreationSources() -> [EKSource] {
        let existingReminderSources = Set(
            SystemStores.event.calendars(for: .reminder)
                .map(\.source.sourceIdentifier)
        )

        func priority(for source: EKSource) -> Int? {
            switch source.sourceType {
            case .local:
                return existingReminderSources.contains(source.sourceIdentifier) ? 0 : 1
            case .mobileMe:
                return existingReminderSources.contains(source.sourceIdentifier) ? 2 : 3
            case .calDAV:
                return existingReminderSources.contains(source.sourceIdentifier) ? 4 : 5
            case .exchange:
                return existingReminderSources.contains(source.sourceIdentifier) ? 6 : 7
            case .subscribed, .birthdays:
                return nil
            @unknown default:
                return existingReminderSources.contains(source.sourceIdentifier) ? 8 : 9
            }
        }

        let prioritizedSources: [(priority: Int, source: EKSource)] = SystemStores.event.sources.compactMap { source -> (priority: Int, source: EKSource)? in
            guard let priority = priority(for: source) else { return nil }
            return (priority, source)
        }

        return prioritizedSources
            .sorted { lhs, rhs in
                if lhs.priority == rhs.priority {
                    return lhs.source.title.localizedCaseInsensitiveCompare(rhs.source.title) == .orderedAscending
                }
                return lhs.priority < rhs.priority
            }
            .map(\.source)
    }

    private static func ensureWritableReminderCalendar() throws -> EKCalendar? {
        if let calendar = writableReminderCalendar() {
            return calendar
        }

        var lastError: Error?
        for source in reminderCalendarCreationSources() {
            let reminderList = EKCalendar(for: .reminder, eventStore: SystemStores.event)
            reminderList.title = newReminderListTitle()
            reminderList.source = source

            do {
                try SystemStores.event.saveCalendar(reminderList, commit: true)
                if reminderList.allowsContentModifications {
                    return reminderList
                }
                if let saved = SystemStores.event.calendar(withIdentifier: reminderList.calendarIdentifier),
                   saved.allowsContentModifications {
                    return saved
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private static func reminderDateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            in: .current,
            from: date
        )
    }

    // 约定:
    // - 业务失败不抛出, 统一返回 CanonicalToolResult(success: false, ...)
    // - 系统失败才 throw, 由上层 ToolChain / Planner 的 catch 统一兜底
    private static func createReminderCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        guard let rawTitle = args["title"] as? String else {
            return reminderFailure(
                summary: tr(
                    "提醒您做什么呢?",
                    "What would you like to be reminded of?"
                ),
                detail: tr(
                    "缺少 title 参数",
                    "Missing title parameter."
                ),
                errorCode: "TITLE_MISSING"
            )
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return reminderFailure(
                summary: tr(
                    "提醒您做什么呢?",
                    "What would you like to be reminded of?"
                ),
                detail: tr(
                    "缺少 title 参数",
                    "Missing title parameter."
                ),
                errorCode: "TITLE_MISSING"
            )
        }

        let dueRaw = (args["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dueRaw, !dueRaw.isEmpty,
              let parsed = parseToolDateTimeDetailed(dueRaw) else {
            return reminderFailure(
                summary: tr(
                    "什么时候提醒您? 例如\"今晚八点\"或\"明天上午10点\"",
                    "When should I remind you? For example \"tonight 8pm\" or \"tomorrow 10am\"."
                ),
                detail: tr(
                    "提醒事项必须给具体时间, 你想几点提醒呢? 例如\"今晚八点\"或\"明天上午10点\"",
                    "A reminder needs a specific time. When should it fire? For example \"tonight 8pm\" or \"tomorrow 10am\"."
                ),
                errorCode: "DUE_MISSING"
            )
        }
        guard parsed.hasExplicitTime else {
            return reminderFailure(
                summary: tr(
                    "你想几点提醒呢? 例如\"\(dueRaw)上午10点\"",
                    "What time would you like? For example \"\(dueRaw) 10am\"."
                ),
                detail: tr(
                    "你说的\u{201C}\(dueRaw)\u{201D}没指定具体时间, 想几点提醒呢? 例如\"\(dueRaw)上午10点\"",
                    "\u{201C}\(dueRaw)\u{201D} didn't include a time of day. What time would you like? For example \"\(dueRaw) 10am\"."
                ),
                errorCode: "DUE_TIME_MISSING"
            )
        }

        let dueDate = parsed.date
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        #if !os(iOS)
        let summary = tr(
            "已设置：\(title)，\(displayDateTimeString(from: dueDate))。",
            "Set: \(title), \(displayDateTimeString(from: dueDate))."
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "calendarItemId": "mock-mac-\(UUID().uuidString)",
                "title": title,
                "due": iso8601String(from: dueDate),
                "notes": notes ?? "",
                "_macMock": true
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .reminders) else {
            return reminderFailure(
                summary: tr(
                    "请先在系统设置里允许提醒事项权限。",
                    "Please grant Reminders permission in System Settings first."
                ),
                detail: tr(
                    "未获得提醒事项权限",
                    "Reminders permission not granted."
                ),
                errorCode: "REMINDERS_PERMISSION_DENIED"
            )
        }

        guard let calendar = try ensureWritableReminderCalendar() else {
            return reminderFailure(
                summary: tr(
                    "当前没有可写的提醒列表，请先在系统提醒事项 App 中启用或创建一个列表。",
                    "No writable reminder list is available. Please enable or create one in the system Reminders app first."
                ),
                detail: tr(
                    "没有可用于新建提醒事项的可写列表，且无法自动创建提醒列表，请先在系统提醒事项 App 中启用或创建一个列表",
                    "No writable list is available for creating reminders, and automatic list creation failed. Please enable or create a list in the system Reminders app first."
                ),
                errorCode: "REMINDERS_NO_WRITABLE_LIST"
            )
        }

        let reminder = EKReminder(eventStore: SystemStores.event)
        reminder.calendar = calendar
        reminder.title = title
        reminder.dueDateComponents = reminderDateComponents(from: dueDate)
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        if let notes, !notes.isEmpty {
            reminder.notes = notes
        }

        try SystemStores.event.save(reminder, commit: true)

        let summary = tr(
            "已设置：\(title)，\(displayDateTimeString(from: dueDate))。",
            "Set: \(title), \(displayDateTimeString(from: dueDate))."
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "calendarItemId": reminder.calendarItemIdentifier,
                "title": title,
                "due": iso8601String(from: dueDate),
                "notes": notes ?? ""
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #endif
    }

    private static func reminderFailure(
        summary: String,
        detail: String,
        errorCode: String
    ) -> CanonicalToolResult {
        CanonicalToolResult(
            success: false,
            summary: summary,
            detail: failurePayload(error: detail, extras: ["error_code": errorCode]),
            errorCode: errorCode
        )
    }
}
