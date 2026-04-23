import EventKit
import Foundation

enum CalendarTools {

    static func register(into registry: ToolRegistry) {

        // ── calendar-create-event ──
        registry.register(RegisteredTool(
            name: "calendar-create-event",
            description: "创建新的日历事项，可写入标题、开始时间、结束时间、地点和备注",
            // 设计原则: SKILL/TOOL 契约按最低能力的模型 (E2B 2B) 来. 不要求 LLM 把
            // 中文相对时间转成 ISO 8601 — handler 自己解析任何合理时间表达式.
            parameters: "title: 事件标题（可选, 没说就用用户原话里的事件名）, start: 开始时间 (ISO 8601 / 中文相对时间如\"明天下午两点\" / 中文绝对时间如\"5月3日15:00\" 都可), end: 结束时间（可选, 同 start 格式）, location: 地点（可选）, notes: 备注（可选）",
            requiredParameters: ["start"],
            execute: { args in
                try await createEventCanonical(args).detail
            },
            executeCanonical: { args in
                try await createEventCanonical(args)
            }
        ))
    }

    // MARK: - Private Helpers

    private static func writableEventCalendar() -> EKCalendar? {
        if let calendar = SystemStores.event.defaultCalendarForNewEvents,
           calendar.allowsContentModifications {
            return calendar
        }

        return SystemStores.event.calendars(for: .event)
            .first(where: \.allowsContentModifications)
    }

    // 约定:
    // - 业务失败不抛出, 统一返回 CanonicalToolResult(success: false, ...)
    // - 系统失败才 throw, 由上层 ToolChain / Planner 的 catch 统一兜底
    private static func createEventCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let rawTitle = (args["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? "新日历事项" : rawTitle

        guard let startRaw = args["start"] as? String,
              let parsed = parseToolDateTimeDetailed(startRaw) else {
            return calendarFailure(
                summary: "什么时候开始? 例如\"明天下午两点\"或\"5月3日15:00\"",
                detail: "没听清开始时间, 可以再说一次吗? 例如\"明天下午两点\"或\"5月3日15:00\"",
                errorCode: "TIME_UNPARSEABLE"
            )
        }
        guard parsed.hasExplicitTime else {
            return calendarFailure(
                summary: "想约什么时间呢? 例如\"\(startRaw)下午两点\"",
                detail: "\u{201C}\(startRaw)\u{201D}没说几点, 想约什么时间呢? 例如\"\(startRaw)下午两点\"",
                errorCode: "TIME_MISSING"
            )
        }
        let startDate = parsed.date

        let endRaw = (args["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endDate = endRaw.flatMap { parseToolDateTime($0) } ?? startDate.addingTimeInterval(3600)
        guard endDate >= startDate else {
            return calendarFailure(
                summary: "结束时间不能早于开始时间，请再确认一下。",
                detail: "end 不能早于 start",
                errorCode: "END_BEFORE_START"
            )
        }

        let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "已创建日历事项\u{201C}\(title)\u{201D}，开始时间为 \(iso8601String(from: startDate))。"

        #if !os(iOS)
        let detail = successPayload(
            result: summary,
            extras: [
                "eventId": "mock-mac-\(UUID().uuidString)",
                "title": title,
                "start": iso8601String(from: startDate),
                "end": iso8601String(from: endDate),
                "location": location ?? "",
                "notes": notes ?? "",
                "_macMock": true
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .calendar) else {
            return calendarFailure(
                summary: "请先在系统设置里允许日历权限。",
                detail: "未获得日历写入权限",
                errorCode: "CALENDAR_PERMISSION_DENIED"
            )
        }

        guard let calendar = writableEventCalendar() else {
            return calendarFailure(
                summary: "当前没有可写的日历，请先在系统日历 App 中启用或创建一个日历。",
                detail: "没有可用于新建事项的可写日历，请先在系统日历中启用或创建一个日历",
                errorCode: "CALENDAR_NO_WRITABLE"
            )
        }

        let event = EKEvent(eventStore: SystemStores.event)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        if let location, !location.isEmpty {
            event.location = location
        }
        if let notes, !notes.isEmpty {
            event.notes = notes
        }

        try SystemStores.event.save(event, span: .thisEvent, commit: true)

        let detail = successPayload(
            result: summary,
            extras: [
                "eventId": event.eventIdentifier ?? "",
                "title": title,
                "start": iso8601String(from: startDate),
                "end": iso8601String(from: endDate),
                "location": location ?? "",
                "notes": notes ?? ""
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #endif
    }

    private static func calendarFailure(
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
