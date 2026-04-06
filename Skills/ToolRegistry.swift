import AVFoundation
import Contacts
import EventKit
import Foundation
import UIKit

// MARK: - 原生工具注册表
//
// 所有原生 API 封装集中注册在这里。
// SKILL.md 通过 allowed-tools 字段引用工具名。

enum AppPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case calendar
    case reminders
    case contacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .contacts: return "通讯录"
        }
    }

    var description: String {
        switch self {
        case .microphone: return "允许录音并采集实时音频输入"
        case .calendar: return "允许创建和写入日历事项"
        case .reminders: return "允许创建提醒和待办"
        case .contacts: return "允许查询、保存和删除联系人"
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .calendar: return "calendar"
        case .reminders: return "bell"
        case .contacts: return "person.crop.circle"
        }
    }
}

enum AppPermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted
    case granted

    var label: String {
        switch self {
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .granted: return "已授权"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined: return "首次使用时会弹出系统授权框"
        case .denied: return "请到系统设置里手动开启权限"
        case .restricted: return "当前设备限制了这项权限"
        case .granted: return "可以直接执行相关 Skill"
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

struct RegisteredTool {
    let name: String
    let description: String
    let parameters: String
    let execute: ([String: Any]) async throws -> String
}

class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: RegisteredTool] = [:]
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    private init() {
        registerBuiltInTools()
    }

    // MARK: - 公开接口

    func register(_ tool: RegisteredTool) {
        tools[tool.name] = tool
    }

    func find(name: String) -> RegisteredTool? {
        tools[name]
    }

    func execute(name: String, args: [String: Any]) async throws -> String {
        guard let tool = tools[name] else {
            return "{\"success\": false, \"error\": \"未知工具: \(name)\"}"
        }
        return try await tool.execute(args)
    }

    /// 根据名称列表获取工具（用于 SKILL.md 的 allowed-tools）
    func toolsFor(names: [String]) -> [RegisteredTool] {
        names.compactMap { tools[$0] }
    }

    /// 根据工具名反查：它属于哪些 allowed-tools 列表
    /// 返回 true 如果该工具已注册
    func hasToolNamed(_ name: String) -> Bool {
        tools[name] != nil
    }

    /// 所有已注册的工具名
    var allToolNames: [String] {
        Array(tools.keys).sorted()
    }

    func authorizationStatus(for kind: AppPermissionKind) -> AppPermissionStatus {
        switch kind {
        case .microphone:
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .notDetermined
            @unknown default:
                return .restricted
            }

        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .fullAccess, .writeOnly, .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .restricted
            }

        case .reminders:
            let status = EKEventStore.authorizationStatus(for: .reminder)
            switch status {
            case .fullAccess, .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted, .writeOnly:
                return .restricted
            @unknown default:
                return .restricted
            }

        case .contacts:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            switch status {
            case .authorized:
                return .granted
            case .limited:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            @unknown default:
                return .restricted
            }
        }
    }

    func allPermissionStatuses() -> [AppPermissionKind: AppPermissionStatus] {
        Dictionary(uniqueKeysWithValues: AppPermissionKind.allCases.map {
            ($0, authorizationStatus(for: $0))
        })
    }

    func requestAccess(for kind: AppPermissionKind) async throws -> Bool {
        switch kind {
        case .microphone:
            return try await requestMicrophoneAccess()
        case .calendar:
            return try await requestCalendarWriteAccess()
        case .reminders:
            return try await requestRemindersAccess()
        case .contacts:
            return try await requestContactsAccess()
        }
    }

    private func requestMicrophoneAccess() async throws -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestCalendarWriteAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestWriteOnlyAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestRemindersAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func requestContactsAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func parseISO8601Date(_ raw: String) -> Date? {
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

    private func writableEventCalendar() -> EKCalendar? {
        if let calendar = eventStore.defaultCalendarForNewEvents,
           calendar.allowsContentModifications {
            return calendar
        }

        return eventStore.calendars(for: .event)
            .first(where: \.allowsContentModifications)
    }

    private func writableReminderCalendar() -> EKCalendar? {
        if let calendar = eventStore.defaultCalendarForNewReminders(),
           calendar.allowsContentModifications {
            return calendar
        }

        return eventStore.calendars(for: .reminder)
            .first(where: \.allowsContentModifications)
    }

    private func newReminderListTitle() -> String {
        let prefersChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
        return prefersChinese ? "PhoneClaw 提醒事项" : "PhoneClaw Reminders"
    }

    private func reminderCalendarCreationSources() -> [EKSource] {
        let existingReminderSources = Set(
            eventStore.calendars(for: .reminder)
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

        let prioritizedSources: [(priority: Int, source: EKSource)] = eventStore.sources.compactMap { source -> (priority: Int, source: EKSource)? in
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

    private func ensureWritableReminderCalendar() throws -> EKCalendar? {
        if let calendar = writableReminderCalendar() {
            return calendar
        }

        var lastError: Error?
        for source in reminderCalendarCreationSources() {
            let reminderList = EKCalendar(for: .reminder, eventStore: eventStore)
            reminderList.title = newReminderListTitle()
            reminderList.source = source

            do {
                try eventStore.saveCalendar(reminderList, commit: true)
                if reminderList.allowsContentModifications {
                    return reminderList
                }
                if let saved = eventStore.calendar(withIdentifier: reminderList.calendarIdentifier),
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

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func reminderDateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            in: .current,
            from: date
        )
    }

    private func contactKeysToFetch() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
    }

    private func findExistingContact(phone: String) throws -> CNContact? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let predicate = CNContact.predicateForContacts(
            matching: CNPhoneNumber(stringValue: trimmed)
        )
        return try contactStore.unifiedContacts(
            matching: predicate,
            keysToFetch: contactKeysToFetch()
        ).first
    }

    private func allContacts() throws -> [CNContact] {
        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: contactKeysToFetch())
        request.sortOrder = .userDefault
        try contactStore.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    private func formattedContactName(_ contact: CNContact) -> String {
        let manual = [contact.familyName, contact.middleName, contact.givenName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()
        if !manual.isEmpty {
            return manual
        }

        let nickname = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty {
            return nickname
        }

        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty {
            return organization
        }

        return "未命名联系人"
    }

    private func clipboardTextPreview(
        from text: String,
        maxCharacters: Int = 500
    ) -> (preview: String, truncated: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let endIndex = trimmed.index(
            trimmed.startIndex,
            offsetBy: maxCharacters,
            limitedBy: trimmed.endIndex
        ) ?? trimmed.endIndex

        return (
            preview: String(trimmed[..<endIndex]),
            truncated: endIndex < trimmed.endIndex
        )
    }

    private func contactSearchTexts(_ contact: CNContact) -> [String] {
        [
            formattedContactName(contact),
            contact.familyName,
            contact.middleName,
            contact.givenName,
            contact.nickname,
            contact.organizationName,
            contact.jobTitle
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func relaxedSearchAliases(for raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var aliases = [trimmed]
        let suffixes = ["总经理", "经理", "总监", "老板", "老师", "医生", "主任", "总", "哥", "姐"]
        for suffix in suffixes where trimmed.hasSuffix(suffix) {
            let candidate = String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 2 {
                aliases.append(candidate)
            }
        }

        let prefixes = ["老", "小", "阿"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let candidate = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 2 {
                aliases.append(candidate)
            }
        }

        return Array(NSOrderedSet(array: aliases)) as? [String] ?? aliases
    }

    private func primaryPhone(_ contact: CNContact) -> String? {
        contact.phoneNumbers
            .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func primaryEmail(_ contact: CNContact) -> String? {
        contact.emailAddresses
            .map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func contactSummaryDictionary(_ contact: CNContact) -> [String: Any] {
        [
            "identifier": contact.identifier,
            "name": formattedContactName(contact),
            "phone": primaryPhone(contact) ?? "",
            "company": contact.organizationName,
            "email": primaryEmail(contact) ?? ""
        ]
    }

    private func contactSummaryText(_ contact: CNContact) -> String {
        var parts = [formattedContactName(contact)]
        if let phone = primaryPhone(contact) {
            parts.append("电话 \(phone)")
        }
        if let email = primaryEmail(contact) {
            parts.append("邮箱 \(email)")
        }
        let company = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty {
            parts.append("公司 \(company)")
        }
        return parts.joined(separator: "，")
    }

    private func searchContacts(
        identifier: String? = nil,
        name: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        query: String? = nil
    ) throws -> [CNContact] {
        let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates: [CNContact]
        if let identifier, !identifier.isEmpty {
            candidates = try contactStore.unifiedContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [identifier]),
                keysToFetch: contactKeysToFetch()
            )
        } else {
            candidates = try allContacts()
        }

        let matches = candidates.filter { contact in
            if let identifier, !identifier.isEmpty, contact.identifier != identifier {
                return false
            }

            if let name, !name.isEmpty {
                let aliases = relaxedSearchAliases(for: name)
                let searchTexts = contactSearchTexts(contact)
                let matched = aliases.contains { alias in
                    searchTexts.contains { $0.localizedCaseInsensitiveContains(alias) }
                }
                if !matched {
                    return false
                }
            }

            if let phone, !phone.isEmpty,
               !contact.phoneNumbers.contains(where: {
                   $0.value.stringValue.localizedCaseInsensitiveContains(phone)
               }) {
                return false
            }

            if let email, !email.isEmpty,
               !contact.emailAddresses.contains(where: {
                   String($0.value).localizedCaseInsensitiveContains(email)
               }) {
                return false
            }

            if let query, !query.isEmpty {
                let aliases = relaxedSearchAliases(for: query)
                let textMatch = aliases.contains { alias in
                    contactSearchTexts(contact).contains {
                        $0.localizedCaseInsensitiveContains(alias)
                    }
                }
                let phoneMatch = contact.phoneNumbers.contains {
                    $0.value.stringValue.localizedCaseInsensitiveContains(query)
                }
                let emailMatch = contact.emailAddresses.contains {
                    String($0.value).localizedCaseInsensitiveContains(query)
                }
                if !(textMatch || phoneMatch || emailMatch) {
                    return false
                }
            }

            return true
        }

        return matches.sorted {
            formattedContactName($0).localizedCaseInsensitiveCompare(formattedContactName($1)) == .orderedAscending
        }
    }

    // MARK: - 内置工具注册

    private func registerBuiltInTools() {
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

        func officialDevicePayload() async -> [String: Any] {
            let info = ProcessInfo.processInfo
            let device = await MainActor.run {
                (
                    UIDevice.current.name,
                    UIDevice.current.model,
                    UIDevice.current.localizedModel,
                    UIDevice.current.systemName,
                    UIDevice.current.systemVersion,
                    UIDevice.current.identifierForVendor?.uuidString
                )
            }

            var payload: [String: Any] = [
                "success": true,
                "name": device.0,
                "model": device.1,
                "localized_model": device.2,
                "system_name": device.3,
                "system_version": device.4,
                "memory_bytes": Double(info.physicalMemory),
                "memory_gb": Double(info.physicalMemory) / 1_073_741_824.0,
                "processor_count": info.processorCount
            ]

            if let identifierForVendor = device.5, !identifierForVendor.isEmpty {
                payload["identifier_for_vendor"] = identifierForVendor
            }

            return payload
        }

        // ── Clipboard ──
        register(RegisteredTool(
            name: "clipboard-read",
            description: "读取剪贴板当前内容",
            parameters: "无"
        ) { _ in
            let snapshot = await MainActor.run { () -> [String: Any] in
                let pasteboard = UIPasteboard.general

                if pasteboard.numberOfItems == 0 {
                    return ["kind": "empty"]
                }

                if pasteboard.hasImages {
                    return [
                        "kind": "image",
                        "item_count": pasteboard.numberOfItems
                    ]
                }

                if pasteboard.hasURLs,
                   let urlText = pasteboard.url?.absoluteString,
                   let preview = self.clipboardTextPreview(from: urlText, maxCharacters: 500) {
                    return [
                        "kind": "url",
                        "content": preview.preview,
                        "truncated": preview.truncated
                    ]
                }

                if pasteboard.hasStrings,
                   let raw = pasteboard.string,
                   let preview = self.clipboardTextPreview(from: raw, maxCharacters: 500) {
                    return [
                        "kind": "text",
                        "content": preview.preview,
                        "truncated": preview.truncated
                    ]
                }

                return [
                    "kind": "unsupported",
                    "item_count": pasteboard.numberOfItems
                ]
            }

            switch snapshot["kind"] as? String {
            case "text":
                let preview = snapshot["content"] as? String ?? ""
                let truncated = snapshot["truncated"] as? Bool ?? false
                let suffix = truncated ? "（内容较长，已截断显示）" : ""
                return successPayload(
                    result: "剪贴板当前文本内容是：\(preview)\(suffix)",
                    extras: [
                        "type": "text",
                        "content": preview,
                        "truncated": truncated
                    ]
                )

            case "url":
                let preview = snapshot["content"] as? String ?? ""
                let truncated = snapshot["truncated"] as? Bool ?? false
                let suffix = truncated ? "（内容较长，已截断显示）" : ""
                return successPayload(
                    result: "剪贴板当前是链接：\(preview)\(suffix)",
                    extras: [
                        "type": "url",
                        "content": preview,
                        "truncated": truncated
                    ]
                )

            case "image":
                let itemCount = snapshot["item_count"] as? Int ?? 1
                return successPayload(
                    result: "剪贴板当前是图片内容。为避免额外内存占用，暂不直接解码图片。",
                    extras: [
                        "type": "image",
                        "item_count": itemCount
                    ]
                )

            case "unsupported":
                let itemCount = snapshot["item_count"] as? Int ?? 1
                return successPayload(
                    result: "剪贴板当前包含 \(itemCount) 项非文本内容，暂不直接读取。",
                    extras: [
                        "type": "unsupported",
                        "item_count": itemCount
                    ]
                )

            default:
                return failurePayload(error: "剪贴板为空")
            }
        })

        register(RegisteredTool(
            name: "clipboard-write",
            description: "将文本写入剪贴板",
            parameters: "text: 要复制的文本内容"
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            await MainActor.run { UIPasteboard.general.string = text }
            return successPayload(
                result: "已写入剪贴板，共 \(text.count) 个字符。",
                extras: ["copied_length": text.count]
            )
        })

        // ── Device ──
        register(RegisteredTool(
            name: "device-info",
            description: "使用 iOS 官方公开 API 汇总获取当前设备名称、设备类型、系统版本、内存和处理器数量",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let name = payload["name"] as? String ?? ""
            let localizedModel = (payload["localized_model"] as? String)?.isEmpty == false
                ? (payload["localized_model"] as? String ?? "")
                : (payload["model"] as? String ?? "")
            let systemName = payload["system_name"] as? String ?? ""
            let systemVersion = payload["system_version"] as? String ?? ""
            let memoryGB = payload["memory_gb"] as? Double ?? 0
            let processorCount = payload["processor_count"] as? Int ?? 0

            let summary = [
                name.isEmpty ? nil : "设备名称：\(name)",
                localizedModel.isEmpty ? nil : "设备类型：\(localizedModel)",
                systemVersion.isEmpty ? nil : "系统版本：\(systemName.isEmpty ? "" : systemName + " ")\(systemVersion)",
                memoryGB > 0 ? String(format: "物理内存：%.1f GB", memoryGB) : nil,
                processorCount > 0 ? "处理器核心数：\(processorCount)" : nil
            ].compactMap { $0 }.joined(separator: "\n")

            var enriched = payload
            enriched["result"] = summary
            enriched["status"] = "succeeded"
            return jsonString(enriched)
        })

        register(RegisteredTool(
            name: "device-name",
            description: "使用 UIDevice.current.name 获取当前设备名称",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let name = payload["name"] as? String ?? ""
            return successPayload(
                result: "这台设备的名称是 \(name)。",
                extras: ["name": name]
            )
        })

        register(RegisteredTool(
            name: "device-model",
            description: "使用 UIDevice.current.model 和 localizedModel 获取当前设备类型",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let model = payload["model"] as? String ?? ""
            let localizedModel = payload["localized_model"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "这台设备的官方设备类型是 \((localizedModel.isEmpty ? model : localizedModel))。",
                "model": model,
                "localized_model": localizedModel
            ])
        })

        register(RegisteredTool(
            name: "device-system-version",
            description: "使用 UIDevice.current.systemName 和 systemVersion 获取系统版本",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let systemName = payload["system_name"] as? String ?? ""
            let systemVersion = payload["system_version"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "当前系统版本是 \(systemName) \(systemVersion)。",
                "system_name": systemName,
                "system_version": systemVersion
            ])
        })

        register(RegisteredTool(
            name: "device-memory",
            description: "使用 ProcessInfo.processInfo.physicalMemory 获取设备物理内存",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let memoryBytes = payload["memory_bytes"] as? Double ?? 0
            let memoryGB = payload["memory_gb"] as? Double ?? 0
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": String(format: "这台设备的物理内存约为 %.1f GB。", memoryGB),
                "memory_bytes": memoryBytes,
                "memory_gb": memoryGB
            ])
        })

        register(RegisteredTool(
            name: "device-processor-count",
            description: "使用 ProcessInfo.processInfo.processorCount 获取处理器核心数",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let processorCount = payload["processor_count"] as? Int ?? 0
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "这台设备的处理器核心数是 \(processorCount)。",
                "processor_count": processorCount
            ])
        })

        register(RegisteredTool(
            name: "device-identifier-for-vendor",
            description: "使用 UIDevice.current.identifierForVendor 获取当前 App 在该设备上的 vendor 标识",
            parameters: "无"
        ) { _ in
            let payload = await officialDevicePayload()
            let identifier = payload["identifier_for_vendor"] as? String ?? ""
            return jsonString([
                "success": true,
                "status": "succeeded",
                "result": "当前 App 在这台设备上的 identifierForVendor 是 \(identifier)。",
                "identifier_for_vendor": identifier
            ])
        })

        // ── Text ──
        register(RegisteredTool(
            name: "calculate-hash",
            description: "计算文本的哈希值",
            parameters: "text: 要计算哈希的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            let hash = text.hashValue
            return successPayload(
                result: "文本“\(text)”的哈希值是 \(hash)。",
                extras: [
                    "input": text,
                    "hash": hash
                ]
            )
        })

        register(RegisteredTool(
            name: "text-reverse",
            description: "翻转文本",
            parameters: "text: 要翻转的文本"
        ) { args in
            guard let text = args["text"] as? String else {
                return failurePayload(error: "缺少 text 参数")
            }
            let reversed = String(text.reversed())
            return successPayload(
                result: "翻转结果：\(reversed)",
                extras: [
                    "original": text,
                    "reversed": reversed
                ]
            )
        })

        // ── Calendar / Reminders / Contacts ──
        register(RegisteredTool(
            name: "calendar-create-event",
            description: "创建新的日历事项，可写入标题、开始时间、结束时间、地点和备注",
            parameters: "title: 事件标题, start: ISO 8601 开始时间, end: ISO 8601 结束时间（可选）, location: 地点（可选）, notes: 备注（可选）"
        ) { args in
            guard let rawTitle = args["title"] as? String else {
                return failurePayload(error: "缺少 title 参数")
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return failurePayload(error: "缺少 title 参数")
            }
            guard let startRaw = args["start"] as? String,
                  let startDate = self.parseISO8601Date(startRaw) else {
                return failurePayload(error: "缺少有效的 start 参数，必须是 ISO 8601 时间字符串")
            }

            let endRaw = (args["end"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let endDate = endRaw.flatMap(self.parseISO8601Date) ?? startDate.addingTimeInterval(3600)
            guard endDate >= startDate else {
                return failurePayload(error: "end 不能早于 start")
            }

            let location = (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                guard try await self.requestCalendarWriteAccess() else {
                    return failurePayload(error: "未获得日历写入权限")
                }

                guard let calendar = self.writableEventCalendar() else {
                    return failurePayload(error: "没有可用于新建事项的可写日历，请先在系统日历中启用或创建一个日历")
                }

                let event = EKEvent(eventStore: self.eventStore)
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

                try self.eventStore.save(event, span: .thisEvent, commit: true)

                return successPayload(
                    result: "已创建日历事项“\(title)”，开始时间为 \(self.iso8601String(from: startDate))。",
                    extras: [
                        "eventId": event.eventIdentifier ?? "",
                        "title": title,
                        "start": self.iso8601String(from: startDate),
                        "end": self.iso8601String(from: endDate),
                        "location": location ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "创建日历事项失败：\(error.localizedDescription)")
            }
        })

        register(RegisteredTool(
            name: "reminders-create",
            description: "创建新的提醒事项，可写入标题、到期时间和备注",
            parameters: "title: 提醒标题, due: ISO 8601 到期时间（可选）, notes: 备注（可选）"
        ) { args in
            guard let rawTitle = args["title"] as? String else {
                return failurePayload(error: "缺少 title 参数")
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return failurePayload(error: "缺少 title 参数")
            }

            let dueRaw = (args["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dueRaw, !dueRaw.isEmpty, self.parseISO8601Date(dueRaw) == nil {
                return failurePayload(error: "due 必须是有效的 ISO 8601 时间字符串")
            }

            let dueDate = dueRaw.flatMap(self.parseISO8601Date)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                guard try await self.requestRemindersAccess() else {
                    return failurePayload(error: "未获得提醒事项权限")
                }

                guard let calendar = try self.ensureWritableReminderCalendar() else {
                    return failurePayload(error: "没有可用于新建提醒事项的可写列表，且无法自动创建提醒列表，请先在系统提醒事项 App 中启用或创建一个列表")
                }

                let reminder = EKReminder(eventStore: self.eventStore)
                reminder.calendar = calendar
                reminder.title = title
                if let dueDate {
                    reminder.dueDateComponents = self.reminderDateComponents(from: dueDate)
                    reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
                }
                if let notes, !notes.isEmpty {
                    reminder.notes = notes
                }

                try self.eventStore.save(reminder, commit: true)

                return successPayload(
                    result: dueDate != nil
                        ? "已创建提醒事项“\(title)”，提醒时间为 \(self.iso8601String(from: dueDate!))。"
                        : "已创建提醒事项“\(title)”。",
                    extras: [
                        "calendarItemId": reminder.calendarItemIdentifier,
                        "title": title,
                        "due": dueDate.map { self.iso8601String(from: $0) } ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "创建提醒事项失败：\(error.localizedDescription)")
            }
        })

        register(RegisteredTool(
            name: "contacts-upsert",
            description: "创建或更新联系人；若提供手机号则优先按手机号查重再更新",
            parameters: "name: 联系人姓名, phone: 手机号（可选）, company: 公司（可选）, email: 邮箱（可选）, notes: 备注（可选）"
        ) { args in
            guard let rawName = args["name"] as? String else {
                return failurePayload(error: "缺少 name 参数")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return failurePayload(error: "缺少 name 参数")
            }

            let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let company = (args["company"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                guard try await self.requestContactsAccess() else {
                    return failurePayload(error: "未获得通讯录权限")
                }

                let existingContact = phone.flatMap { try? self.findExistingContact(phone: $0) }
                let mutableContact: CNMutableContact
                let action: String

                if let existingContact {
                    mutableContact = existingContact.mutableCopy() as! CNMutableContact
                    action = "updated"
                } else {
                    mutableContact = CNMutableContact()
                    action = "created"
                }

                mutableContact.givenName = name
                mutableContact.familyName = ""

                if let phone, !phone.isEmpty {
                    mutableContact.phoneNumbers = [
                        CNLabeledValue(
                            label: CNLabelPhoneNumberMobile,
                            value: CNPhoneNumber(stringValue: phone)
                        )
                    ]
                }
                if let company, !company.isEmpty {
                    mutableContact.organizationName = company
                }
                if let email, !email.isEmpty {
                    mutableContact.emailAddresses = [
                        CNLabeledValue(label: CNLabelWork, value: email as NSString)
                    ]
                }
                if let notes, !notes.isEmpty {
                    mutableContact.note = notes
                }

                let saveRequest = CNSaveRequest()
                if existingContact != nil {
                    saveRequest.update(mutableContact)
                } else {
                    saveRequest.add(mutableContact, toContainerWithIdentifier: nil)
                }
                try self.contactStore.execute(saveRequest)

                let actionText = action == "updated" ? "已更新" : "已创建"
                return successPayload(
                    result: "\(actionText)联系人“\(name)”。",
                    extras: [
                        "action": action,
                        "name": name,
                        "phone": phone ?? "",
                        "company": company ?? "",
                        "email": email ?? "",
                        "notes": notes ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "保存联系人失败：\(error.localizedDescription)")
            }
        })

        register(RegisteredTool(
            name: "contacts-search",
            description: "搜索联系人，可按姓名、手机号、邮箱、identifier 或关键词查询联系方式",
            parameters: "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）"
        ) { args in
            let identifier = (args["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard identifier?.isEmpty == false
                || name?.isEmpty == false
                || phone?.isEmpty == false
                || email?.isEmpty == false
                || query?.isEmpty == false else {
                return failurePayload(error: "请至少提供 query、name、phone、email 或 identifier 其中一个参数")
            }

            do {
                guard try await self.requestContactsAccess() else {
                    return failurePayload(error: "未获得通讯录权限")
                }

                let matches = Array(try self.searchContacts(
                    identifier: identifier,
                    name: name,
                    phone: phone,
                    email: email,
                    query: query
                ).prefix(5))

                let items = matches.map(self.contactSummaryDictionary)
                if matches.isEmpty {
                    return successPayload(
                        result: "未找到匹配的联系人。",
                        extras: [
                            "count": 0,
                            "items": items
                        ]
                    )
                }

                let lines = matches.map(self.contactSummaryText)
                return successPayload(
                    result: "找到 \(matches.count) 个联系人：\(lines.joined(separator: "；"))。",
                    extras: [
                        "count": matches.count,
                        "items": items
                    ]
                )
            } catch {
                return failurePayload(error: "搜索联系人失败：\(error.localizedDescription)")
            }
        })

        register(RegisteredTool(
            name: "contacts-delete",
            description: "删除联系人，可按姓名、手机号、邮箱、identifier 或关键词匹配后删除",
            parameters: "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）"
        ) { args in
            let identifier = (args["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName?
                .replacingOccurrences(of: "的电话", with: "")
                .replacingOccurrences(of: "电话", with: "")
                .replacingOccurrences(of: "手机号", with: "")
                .replacingOccurrences(of: "号码", with: "")
                .replacingOccurrences(of: "联系方式", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。,？！!? "))

            guard identifier?.isEmpty == false
                || name?.isEmpty == false
                || phone?.isEmpty == false
                || email?.isEmpty == false
                || query?.isEmpty == false else {
                return failurePayload(error: "请至少提供 query、name、phone、email 或 identifier 其中一个参数")
            }

            do {
                guard try await self.requestContactsAccess() else {
                    return failurePayload(error: "未获得通讯录权限")
                }

                let matches = try self.searchContacts(
                    identifier: identifier,
                    name: name,
                    phone: phone,
                    email: email,
                    query: query
                )

                if matches.isEmpty {
                    return failurePayload(error: "未找到匹配的联系人")
                }

                if matches.count > 1 {
                    let previews = matches.prefix(5).map(self.contactSummaryText).joined(separator: "；")
                    return failurePayload(error: "匹配到多个联系人，请提供更具体的信息：\(previews)")
                }

                let contact = matches[0]
                let mutableContact = contact.mutableCopy() as! CNMutableContact
                let saveRequest = CNSaveRequest()
                saveRequest.delete(mutableContact)
                try self.contactStore.execute(saveRequest)

                return successPayload(
                    result: "已删除联系人“\(self.formattedContactName(contact))”。",
                    extras: [
                        "identifier": contact.identifier,
                        "name": self.formattedContactName(contact),
                        "phone": self.primaryPhone(contact) ?? "",
                        "email": self.primaryEmail(contact) ?? ""
                    ]
                )
            } catch {
                return failurePayload(error: "删除联系人失败：\(error.localizedDescription)")
            }
        })
    }
}

// MARK: - Helpers

func jsonEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
       .replacingOccurrences(of: "\t", with: "\\t")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"success\": false, \"error\": \"JSON 编码失败\"}"
    }
    return string
}
