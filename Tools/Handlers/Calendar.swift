import EventKit
import Foundation

enum CalendarTools {

    static func register(into registry: ToolRegistry) {

        // ── calendar-create-event ──
        registry.register(RegisteredTool(
            name: "calendar-create-event",
            description: tr(
                "创建新的日历事项，可写入标题、开始时间、结束时间、地点和备注",
                "Create a new calendar event with title, start time, end time, location, and notes.",
                "タイトル・開始時刻・終了時刻・場所・メモを指定して、新しいカレンダー予定を作成します。"
            ),
            // 设计原则: SKILL/TOOL 契约按最低能力的模型 (E2B 2B) 来. 不要求 LLM 把
            // 中文相对时间转成 ISO 8601 — handler 自己解析任何合理时间表达式.
            parameters: tr(
                "title: 事件标题（可选, 没说就用用户原话里的事件名）, start: 开始时间 (ISO 8601 / 中文相对时间如\"明天下午两点\" / 中文绝对时间如\"5月3日15:00\" 都可), end: 结束时间（可选, 同 start 格式）, location: 地点（可选）, notes: 备注（可选）",
                "title: event title (optional, falls back to the event name from the user's phrasing), start: start time (ISO 8601, or natural language like \"tomorrow 2pm\" / \"May 3 15:00\"), end: end time (optional, same format as start), location: location (optional), notes: notes (optional)",
                "title: 予定のタイトル（任意。指定がなければユーザーの発話にある予定名を使う）, start: 開始時刻（ISO 8601、または\"明日の午後2時\"のような自然な相対表現や\"5月3日15:00\"のような絶対表現も可）, end: 終了時刻（任意。start と同じ形式）, location: 場所（任意）, notes: メモ（任意）"
            ),
            requiredParameters: ["start"],
            execute: { args in
                try await createEventCanonical(args).detail
            },
            executeCanonical: { args in
                try await createEventCanonical(args)
            }
        ))

        // ── calendar-query-events ──
        registry.register(RegisteredTool(
            name: "calendar-query-events",
            description: tr(
                "读取指定时间范围内的日历事项，用于日程总结、忙闲分析和空闲时间查询",
                "Read calendar events in a time range for schedule summaries, availability checks, and local planning analysis.",
                "指定した期間のカレンダー予定を読み取り、予定のまとめ・空き状況の確認・空き時間の検索に使います。"
            ),
            parameters: tr(
                "period: 预设范围（可选: today/tomorrow/this_week/next_week/next_7_days）, start: 开始时间或日期范围表达（可选, 例如\"今天\"/\"明天下午\"）, end: 结束时间（可选）, days: 从 start 起查询天数（可选）, calendar: 日历名称过滤（可选）, limit: 最大返回数量（可选, 默认 20, 最多 50）, include_notes: 是否包含备注（可选, 默认 false）",
                "period: preset range (optional: today/tomorrow/this_week/next_week/next_7_days), start: start time or range expression (optional, e.g. \"today\" / \"tomorrow afternoon\"), end: end time (optional), days: number of days from start (optional), calendar: calendar title filter (optional), limit: max events to return (optional, default 20, max 50), include_notes: include event notes (optional, default false)",
                "period: プリセット範囲（任意: today/tomorrow/this_week/next_week/next_7_days）, start: 開始時刻または範囲の表現（任意。例:\"今日\"/\"明日の午後\"）, end: 終了時刻（任意）, days: start からの日数（任意）, calendar: カレンダー名でのフィルタ（任意）, limit: 返す予定の最大件数（任意。既定20、最大50）, include_notes: メモを含めるか（任意。既定false）"
            ),
            aliases: ["calendar-query", "calendar-list-events", "calendar-read-events"],
            execute: { args in
                try await queryEventsCanonical(args).detail
            },
            executeCanonical: { args in
                try await queryEventsCanonical(args)
            }
        ))
    }

    // MARK: - Private Helpers

    private struct CalendarQueryRange {
        let start: Date
        let end: Date
        let label: String
    }

    private struct CalendarEventSnapshot {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
        let calendarTitle: String
        let availability: String
    }

    private struct CalendarBusyStats {
        let busyMinutes: Int
        let allDayCount: Int
        let freeWindows: [[String: Any]]
    }

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
        let title = rawTitle.isEmpty ? tr("新日历事项", "New calendar event", "新しいカレンダー予定") : rawTitle

        guard let startRaw = args["start"] as? String,
              let parsed = parseToolDateTimeDetailed(startRaw) else {
            return calendarFailure(
                summary: tr(
                    "什么时候开始? 例如\"明天下午两点\"或\"5月3日15:00\"",
                    "When should it start? For example \"tomorrow 2pm\" or \"May 3 15:00\".",
                    "いつ始めますか? 例えば\"明日の午後2時\"や\"5月3日15:00\"のように。"
                ),
                detail: tr(
                    "没听清开始时间, 可以再说一次吗? 例如\"明天下午两点\"或\"5月3日15:00\"",
                    "I didn't catch the start time. Could you say it again? For example \"tomorrow 2pm\" or \"May 3 15:00\".",
                    "開始時刻が聞き取れませんでした。もう一度言ってもらえますか? 例えば\"明日の午後2時\"や\"5月3日15:00\"のように。"
                ),
                errorCode: "TIME_UNPARSEABLE"
            )
        }
        guard parsed.hasExplicitTime else {
            return calendarFailure(
                summary: tr(
                    "想约什么时间呢? 例如\"\(startRaw)下午两点\"",
                    "What time would you like? For example \"\(startRaw) 2pm\".",
                    "何時にしますか? 例えば\"\(startRaw)の午後2時\"のように。"
                ),
                detail: tr(
                    "\u{201C}\(startRaw)\u{201D}没说几点, 想约什么时间呢? 例如\"\(startRaw)下午两点\"",
                    "\u{201C}\(startRaw)\u{201D} didn't include a time of day. What time would you like? For example \"\(startRaw) 2pm\".",
                    "\u{201C}\(startRaw)\u{201D}には時刻が含まれていません。何時にしますか? 例えば\"\(startRaw)の午後2時\"のように。"
                ),
                errorCode: "TIME_MISSING"
            )
        }
        let startDate = parsed.date

        let endRaw = (args["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endDate = endRaw.flatMap { parseToolDateTime($0) } ?? startDate.addingTimeInterval(3600)
        guard endDate >= startDate else {
            return calendarFailure(
                summary: tr(
                    "结束时间不能早于开始时间，请再确认一下。",
                    "The end time can't be earlier than the start time — please double-check.",
                    "終了時刻を開始時刻より前にはできません。もう一度ご確認ください。"
                ),
                detail: tr(
                    "end 不能早于 start",
                    "end must not be earlier than start",
                    "end は start より前にできません"
                ),
                errorCode: "END_BEFORE_START"
            )
        }

        let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = tr(
            "已创建：\(title)，\(displayDateTimeString(from: startDate))。",
            "Created: \(title), \(displayDateTimeString(from: startDate)).",
            "作成しました：\(title)、\(displayDateTimeString(from: startDate))。"
        )

        #if !os(iOS)
        let eventId = MacCalendarMock.create(
            title: title,
            start: startDate,
            end: endDate,
            location: location,
            notes: notes
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "eventId": eventId,
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
                summary: tr(
                    "请先在系统设置里允许日历权限。",
                    "Please enable Calendar access in System Settings first.",
                    "先にシステム設定でカレンダーへのアクセスを許可してください。"
                ),
                detail: tr(
                    "未获得日历写入权限",
                    "Calendar write permission not granted",
                    "カレンダーへの書き込み権限がありません"
                ),
                errorCode: "CALENDAR_PERMISSION_DENIED"
            )
        }

        guard let calendar = writableEventCalendar() else {
            return calendarFailure(
                summary: tr(
                    "当前没有可写的日历，请先在系统日历 App 中启用或创建一个日历。",
                    "No writable calendar is available. Please enable or create one in the system Calendar app first.",
                    "書き込み可能なカレンダーがありません。先にシステムのカレンダーAppで有効化するか、新しく作成してください。"
                ),
                detail: tr(
                    "没有可用于新建事项的可写日历，请先在系统日历中启用或创建一个日历",
                    "No writable calendar available for new events — enable or create one in the system Calendar app first",
                    "新規予定に使える書き込み可能なカレンダーがありません。先にシステムのカレンダーで有効化するか作成してください"
                ),
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

    private static func queryEventsCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        guard let range = parseCalendarQueryRange(args) else {
            return calendarFailure(
                summary: tr(
                    "没听清要查询哪个时间范围，可以说“今天”“明天”或“本周”。",
                    "I couldn't tell which date range to check. Try \"today\", \"tomorrow\", or \"this week\".",
                    "どの期間を調べればよいか聞き取れませんでした。\"今日\"\"明日\"\"今週\"などと言ってみてください。"
                ),
                detail: tr(
                    "无法解析日历查询时间范围",
                    "Unable to parse calendar query range",
                    "カレンダーの照会期間を解釈できません"
                ),
                errorCode: "CALENDAR_QUERY_RANGE_UNPARSEABLE"
            )
        }

        let limit = boundedInt(args["limit"], defaultValue: 20, min: 1, max: 50)
        let includeNotes = boolArg(args["include_notes"]) ?? boolArg(args["includeNotes"]) ?? false
        let calendarFilter = stringArg(args["calendar"])

        #if !os(iOS)
        let events = MacCalendarMock.query(
            start: range.start,
            end: range.end,
            calendarFilter: calendarFilter,
            limit: limit
        )
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .calendarRead) else {
            return calendarFailure(
                summary: tr(
                    "请先允许日历读取权限。",
                    "Please allow Calendar read access first.",
                    "先にカレンダーの読み取りアクセスを許可してください。"
                ),
                detail: tr(
                    "未获得日历读取权限",
                    "Calendar read permission not granted",
                    "カレンダーの読み取り権限がありません"
                ),
                errorCode: "CALENDAR_READ_PERMISSION_DENIED"
            )
        }

        let calendars = SystemStores.event.calendars(for: .event)
        let filteredCalendars: [EKCalendar]? = {
            guard let calendarFilter, !calendarFilter.isEmpty else { return nil }
            let needle = calendarFilter.lowercased()
            let matches = calendars.filter { $0.title.lowercased().contains(needle) }
            return matches.isEmpty ? nil : matches
        }()
        let predicate = SystemStores.event.predicateForEvents(
            withStart: range.start,
            end: range.end,
            calendars: filteredCalendars
        )
        let events = SystemStores.event.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event -> CalendarEventSnapshot in
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return CalendarEventSnapshot(
                    id: event.eventIdentifier ?? "",
                    title: title.isEmpty ? tr("未命名日程", "Untitled event", "名称未設定の予定") : title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    notes: includeNotes ? event.notes : nil,
                    calendarTitle: event.calendar.title,
                    availability: availabilityLabel(event.availability)
                )
            }
        #endif

        let eventList = Array(events)
        let stats = busyStats(for: eventList, in: range)
        let summary = calendarQuerySummary(
            range: range,
            events: eventList,
            stats: stats
        )
        let payloadEvents = eventList.map { eventPayload($0, includeNotes: includeNotes) }
        let detail = successPayload(
            result: summary,
            extras: [
                "start": iso8601String(from: range.start),
                "end": iso8601String(from: range.end),
                "range_label": range.label,
                "event_count": payloadEvents.count,
                "busy_minutes": stats.busyMinutes,
                "all_day_count": stats.allDayCount,
                "free_windows": stats.freeWindows,
                "events": payloadEvents
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
    }

    private static func parseCalendarQueryRange(_ args: [String: Any]) -> CalendarQueryRange? {
        let now = Date()
        var calendar = Foundation.Calendar.current
        calendar.timeZone = .current

        if let period = stringArg(args["period"]),
           let preset = presetRange(for: period, now: now, calendar: calendar) {
            return preset
        }

        let startRaw = stringArg(args["start"])
        let endRaw = stringArg(args["end"])
        let days = boundedInt(args["days"], defaultValue: 0, min: 0, max: 366)

        if let startRaw,
           let preset = presetRange(for: startRaw, now: now, calendar: calendar),
           endRaw == nil {
            return preset
        }

        let startInfo = startRaw.flatMap { parseToolDateTimeDetailed($0, anchor: now) }
        let dayPart = startRaw.flatMap { dayPartRange(for: $0, parsedDate: startInfo?.date ?? now, calendar: calendar) }
        let startDate: Date
        let inferredEnd: Date
        let label: String

        if let dayPart {
            startDate = dayPart.start
            inferredEnd = dayPart.end
            label = startRaw ?? displayDateRangeLabel(start: dayPart.start, end: dayPart.end)
        } else if let startInfo {
            startDate = startInfo.hasExplicitTime ? startInfo.date : calendar.startOfDay(for: startInfo.date)
            let defaultDays = days > 0 ? days : (startInfo.hasExplicitTime ? 0 : 1)
            inferredEnd = defaultDays > 0
                ? calendar.date(byAdding: .day, value: defaultDays, to: startDate) ?? startDate.addingTimeInterval(86_400)
                : startDate.addingTimeInterval(3600)
            label = startRaw ?? displayDateRangeLabel(start: startDate, end: inferredEnd)
        } else {
            startDate = calendar.startOfDay(for: now)
            let defaultDays = days > 0 ? days : 1
            inferredEnd = calendar.date(byAdding: .day, value: defaultDays, to: startDate) ?? startDate.addingTimeInterval(86_400)
            label = days > 0
                ? tr("未来 \(defaultDays) 天", "Next \(defaultDays) days", "今後 \(defaultDays) 日間")
                : tr("今天", "Today", "今日")
        }

        let endDate: Date
        if let endRaw, let endInfo = parseToolDateTimeDetailed(endRaw, anchor: now) {
            if let endDayPart = dayPartRange(for: endRaw, parsedDate: endInfo.date, calendar: calendar) {
                endDate = endDayPart.end
            } else {
                let rawEnd = endInfo.hasExplicitTime
                    ? endInfo.date
                    : (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endInfo.date)) ?? endInfo.date)
                endDate = rawEnd
            }
        } else {
            endDate = inferredEnd
        }

        guard endDate > startDate else { return nil }
        return CalendarQueryRange(
            start: startDate,
            end: endDate,
            label: label
        )
    }

    private static func presetRange(
        for raw: String,
        now: Date,
        calendar: Foundation.Calendar
    ) -> CalendarQueryRange? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { return nil }

        let today = calendar.startOfDay(for: now)
        func daysFromToday(_ offset: Int, label: String) -> CalendarQueryRange {
            let start = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return CalendarQueryRange(start: start, end: end, label: label)
        }

        if ["today", "今天", "今日"].contains(normalized) {
            return daysFromToday(0, label: tr("今天", "Today", "今日"))
        }
        if ["tomorrow", "明天", "明日"].contains(normalized) {
            return daysFromToday(1, label: tr("明天", "Tomorrow", "明日"))
        }
        if ["yesterday", "昨天", "昨日"].contains(normalized) {
            return daysFromToday(-1, label: tr("昨天", "Yesterday", "昨日"))
        }
        if normalized.contains("后天") {
            return daysFromToday(2, label: tr("后天", "The day after tomorrow", "明後日"))
        }

        if normalized.contains("thisweek") || normalized.contains("本周") || normalized.contains("这周") {
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return CalendarQueryRange(
                start: interval.start,
                end: interval.end,
                label: tr("本周", "This week", "今週")
            )
        }
        if normalized.contains("nextweek") || normalized.contains("下周") || normalized.contains("下星期") {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .weekOfYear, value: 1, to: week.start),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: week.end) else {
                return nil
            }
            return CalendarQueryRange(
                start: start,
                end: end,
                label: tr("下周", "Next week", "来週")
            )
        }
        if normalized.contains("next7days")
            || normalized.contains("未来7天")
            || normalized.contains("最近7天")
            || normalized.contains("一周内") {
            let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today.addingTimeInterval(7 * 86_400)
            return CalendarQueryRange(start: today, end: end, label: tr("未来 7 天", "Next 7 days", "今後 7 日間"))
        }

        return nil
    }

    private static func dayPartRange(
        for raw: String,
        parsedDate: Date,
        calendar: Foundation.Calendar
    ) -> (start: Date, end: Date)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let base = calendar.startOfDay(for: parsedDate)

        func range(_ startHour: Int, _ endHour: Int) -> (Date, Date)? {
            guard let start = calendar.date(byAdding: .hour, value: startHour, to: base),
                  let end = calendar.date(byAdding: .hour, value: endHour, to: base) else {
                return nil
            }
            return (start, end)
        }

        if text.contains("凌晨") {
            return range(0, 6)
        }
        if text.contains("早上") || text.contains("上午") || text.contains("morning") {
            return range(8, 12)
        }
        if text.contains("中午") || text.contains("noon") {
            return range(11, 13)
        }
        if text.contains("下午") || text.contains("afternoon") {
            return range(12, 18)
        }
        if text.contains("晚上") || text.contains("今晚") || text.contains("evening") || text.contains("tonight") {
            return range(18, 22)
        }
        return nil
    }

    private static func busyStats(
        for events: [CalendarEventSnapshot],
        in range: CalendarQueryRange
    ) -> CalendarBusyStats {
        let allDayCount = events.filter(\.isAllDay).count
        let busyIntervals = events
            .filter { event in
                guard event.availability != "free" else { return false }
                if event.isAllDay {
                    return event.availability == "busy" || event.availability == "unavailable"
                }
                return true
            }
            .compactMap { event -> (Date, Date)? in
                let start = max(event.start, range.start)
                let end = min(event.end, range.end)
                return end > start ? (start, end) : nil
            }
            .sorted { $0.0 < $1.0 }

        let merged = mergeIntervals(busyIntervals)
        let busyMinutes = merged.reduce(0) { partial, interval in
            partial + max(0, Int(interval.1.timeIntervalSince(interval.0) / 60))
        }
        let freeWindows = freeWindows(in: range, busyIntervals: merged)
        return CalendarBusyStats(
            busyMinutes: busyMinutes,
            allDayCount: allDayCount,
            freeWindows: freeWindows
        )
    }

    private static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        var result: [(Date, Date)] = []
        for interval in intervals {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.0 <= last.1 {
                result[result.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func freeWindows(
        in range: CalendarQueryRange,
        busyIntervals: [(Date, Date)]
    ) -> [[String: Any]] {
        var cursor = range.start
        var windows: [[String: Any]] = []
        for interval in busyIntervals {
            if interval.0 > cursor {
                appendFreeWindow(start: cursor, end: interval.0, into: &windows)
            }
            cursor = max(cursor, interval.1)
        }
        if cursor < range.end {
            appendFreeWindow(start: cursor, end: range.end, into: &windows)
        }
        return Array(windows.prefix(8))
    }

    private static func appendFreeWindow(
        start: Date,
        end: Date,
        into windows: inout [[String: Any]]
    ) {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        guard minutes >= 15 else { return }
        windows.append([
            "start": iso8601String(from: start),
            "end": iso8601String(from: end),
            "duration_minutes": minutes
        ])
    }

    private static func eventPayload(
        _ event: CalendarEventSnapshot,
        includeNotes: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": event.id,
            "title": event.title,
            "start": iso8601String(from: event.start),
            "end": iso8601String(from: event.end),
            "is_all_day": event.isAllDay,
            "calendar": event.calendarTitle,
            "availability": event.availability
        ]
        if let location = event.location, !location.isEmpty {
            payload["location"] = location
        }
        if includeNotes, let notes = event.notes, !notes.isEmpty {
            payload["notes"] = notes
        }
        return payload
    }

    private static func calendarQuerySummary(
        range: CalendarQueryRange,
        events: [CalendarEventSnapshot],
        stats: CalendarBusyStats
    ) -> String {
        let label = range.label
        guard !events.isEmpty else {
            return tr("\(label)没有日程。", "No calendar events for \(label).", "\(label)は予定がありません。")
        }

        let preview = events.prefix(3)
            .map { "\($0.title) \(displayEventTime($0))" }
            .joined(separator: tr("；", "; ", "、"))
        let extra = events.count > 3
            ? tr(" 等", " and more", " ほか")
            : ""
        let busyText = stats.busyMinutes > 0
            ? tr("，忙碌约 \(formatMinutes(stats.busyMinutes))", ", about \(formatMinutes(stats.busyMinutes)) busy", "、うち約 \(formatMinutes(stats.busyMinutes)) は予定あり")
            : ""
        return tr(
            "\(label)有 \(events.count) 个日程\(busyText)：\(preview)\(extra)。",
            "\(label) has \(events.count) calendar events\(busyText): \(preview)\(extra).",
            "\(label)は \(events.count) 件の予定があります\(busyText)：\(preview)\(extra)。"
        )
    }

    private static func displayEventTime(_ event: CalendarEventSnapshot) -> String {
        if event.isAllDay {
            return tr("全天", "all day", "終日")
        }
        let formatter = DateFormatter()
        formatter.locale = LanguageService.shared.current.isJapanese
            ? Locale(identifier: "ja_JP")
            : (LanguageService.shared.current.isChinese
                ? Locale(identifier: "zh_Hans_CN")
                : Locale(identifier: "en_US"))
        formatter.timeZone = .current
        formatter.timeStyle = .short
        formatter.dateStyle = Foundation.Calendar.current.isDate(event.start, inSameDayAs: event.end)
            ? .none
            : .short
        return "\(formatter.string(from: event.start))-\(formatter.string(from: event.end))"
    }

    private static func displayDateRangeLabel(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageService.shared.current.isJapanese
            ? Locale(identifier: "ja_JP")
            : (LanguageService.shared.current.isChinese
                ? Locale(identifier: "zh_Hans_CN")
                : Locale(identifier: "en_US"))
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return tr("\(minutes) 分钟", "\(minutes) minutes", "\(minutes) 分")
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return tr("\(hours) 小时", "\(hours) hours", "\(hours) 時間")
        }
        return tr("\(hours) 小时 \(rest) 分钟", "\(hours) hours \(rest) minutes", "\(hours) 時間 \(rest) 分")
    }

    private static func stringArg(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boundedInt(_ value: Any?, defaultValue: Int, min: Int, max: Int) -> Int {
        let raw: Int?
        switch value {
        case let int as Int:
            raw = int
        case let double as Double:
            raw = Int(double)
        case let number as NSNumber:
            raw = number.intValue
        case let string as String:
            raw = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            raw = nil
        }
        let resolved = raw ?? defaultValue
        return Swift.max(min, Swift.min(max, resolved))
    }

    private static func boolArg(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1", "是", "包含"].contains(normalized) { return true }
            if ["false", "no", "0", "否", "不包含"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    #if os(iOS)
    private static func availabilityLabel(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .busy:
            return "busy"
        case .free:
            return "free"
        case .tentative:
            return "tentative"
        case .unavailable:
            return "unavailable"
        case .notSupported:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
    #else
    private enum MacCalendarMock {
        private static var seededEvents: [CalendarEventSnapshot]?

        private static var events: [CalendarEventSnapshot] {
            get {
                if let seededEvents {
                    return seededEvents
                }
                let generated = defaultEvents()
                seededEvents = generated
                return generated
            }
            set {
                seededEvents = newValue
            }
        }

        static func create(
            title: String,
            start: Date,
            end: Date,
            location: String?,
            notes: String?
        ) -> String {
            let id = "mock-mac-\(UUID().uuidString)"
            events.append(CalendarEventSnapshot(
                id: id,
                title: title,
                start: start,
                end: end,
                isAllDay: false,
                location: location,
                notes: notes,
                calendarTitle: "PhoneClaw Mock",
                availability: "busy"
            ))
            events.sort { $0.start < $1.start }
            return id
        }

        static func query(
            start: Date,
            end: Date,
            calendarFilter: String?,
            limit: Int
        ) -> [CalendarEventSnapshot] {
            let needle = calendarFilter?.lowercased()
            return Array(events
                .filter { $0.end > start && $0.start < end }
                .filter { event in
                    guard let needle, !needle.isEmpty else { return true }
                    return event.calendarTitle.lowercased().contains(needle)
                }
                .sorted { $0.start < $1.start }
                .prefix(limit))
        }

        private static func defaultEvents() -> [CalendarEventSnapshot] {
            var calendar = Foundation.Calendar.current
            calendar.timeZone = .current
            let today = calendar.startOfDay(for: Date())
            func date(dayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
                let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            }
            return [
                CalendarEventSnapshot(
                    id: "mock-calendar-standup",
                    title: tr("晨会", "Standup", "朝会"),
                    start: date(hour: 9, minute: 30),
                    end: date(hour: 10),
                    isAllDay: false,
                    location: nil,
                    notes: nil,
                    calendarTitle: "PhoneClaw Mock",
                    availability: "busy"
                ),
                CalendarEventSnapshot(
                    id: "mock-calendar-review",
                    title: tr("产品评审", "Product review", "プロダクトレビュー"),
                    start: date(hour: 14),
                    end: date(hour: 15),
                    isAllDay: false,
                    location: tr("3 楼会议室", "3F Meeting Room", "3階 会議室"),
                    notes: nil,
                    calendarTitle: "PhoneClaw Mock",
                    availability: "busy"
                ),
                CalendarEventSnapshot(
                    id: "mock-calendar-tomorrow",
                    title: tr("客户沟通", "Customer sync", "顧客との打ち合わせ"),
                    start: date(dayOffset: 1, hour: 16),
                    end: date(dayOffset: 1, hour: 17),
                    isAllDay: false,
                    location: nil,
                    notes: nil,
                    calendarTitle: "PhoneClaw Mock",
                    availability: "busy"
                )
            ]
        }
    }
    #endif

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
