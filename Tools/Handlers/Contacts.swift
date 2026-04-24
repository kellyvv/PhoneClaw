import Contacts
import Foundation

enum ContactsTools {

    static func register(into registry: ToolRegistry) {

        // ── contacts-upsert ──
        registry.register(RegisteredTool(
            name: "contacts-upsert",
            description: tr(
                "创建或更新联系人；若提供手机号则优先按手机号查重再更新",
                "Create or update a contact; when a phone number is provided, dedupe by phone first and update the matching contact"
            ),
            parameters: tr(
                "name: 联系人姓名, phone: 手机号（可选）, company: 公司（可选）, email: 邮箱（可选）, notes: 备注（可选）",
                "name: contact name, phone: phone number (optional), company: company (optional), email: email address (optional), notes: notes (optional)"
            ),
            requiredParameters: ["name"],
            aliases: ["contacts_upsert"],
            execute: { args in
                try await upsertCanonical(args).detail
            },
            executeCanonical: { args in
                try await upsertCanonical(args)
            }
        ))

        // ── contacts-search ──
        registry.register(RegisteredTool(
            name: "contacts-search",
            description: tr(
                "搜索联系人，可按姓名、手机号、邮箱、identifier 或关键词查询联系方式",
                "Search contacts; look up contact info by name, phone, email, identifier or a free-text query"
            ),
            parameters: tr(
                "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）",
                "query: search keyword (optional), identifier: contact identifier (optional), name: name (optional), phone: phone number (optional), email: email address (optional)"
            ),
            requiredAnyOfParameters: ["query", "identifier", "name", "phone", "email"],
            aliases: ["contacts_search"],
            execute: { args in
                try await searchCanonical(args).detail
            },
            executeCanonical: { args in
                try await searchCanonical(args)
            }
        ))

        // ── contacts-delete ──
        registry.register(RegisteredTool(
            name: "contacts-delete",
            description: tr(
                "删除联系人，可按姓名、手机号、邮箱、identifier 或关键词匹配后删除；匹配多个时可传 all=true 批量删除",
                "Delete contacts matched by name, phone, email, identifier or a free-text query; when multiple matches are found, pass all=true to delete every match"
            ),
            parameters: tr(
                "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）, all: 多匹配时是否全部删除（可选，默认 false）",
                "query: search keyword (optional), identifier: contact identifier (optional), name: name (optional), phone: phone number (optional), email: email address (optional), all: whether to delete every match when more than one is found (optional, default false)"
            ),
            requiredAnyOfParameters: ["query", "identifier", "name", "phone", "email"],
            aliases: ["contacts_delete", "contacts-delete-contact"],
            execute: { args in
                try await deleteCanonical(args).detail
            },
            executeCanonical: { args in
                try await deleteCanonical(args)
            }
        ))
    }

    // MARK: - Private Helpers

    private static func contactKeysToFetch() -> [CNKeyDescriptor] {
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

    private static func findExistingContact(phone: String) throws -> CNContact? {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let predicate = CNContact.predicateForContacts(
            matching: CNPhoneNumber(stringValue: trimmed)
        )
        return try SystemStores.contacts.unifiedContacts(
            matching: predicate,
            keysToFetch: contactKeysToFetch()
        ).first
    }

    private static func allContacts() throws -> [CNContact] {
        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: contactKeysToFetch())
        request.sortOrder = .userDefault
        try SystemStores.contacts.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    private static func formattedContactName(_ contact: CNContact) -> String {
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

        return tr("未命名联系人", "Unnamed contact")
    }

    private static func contactSearchTexts(_ contact: CNContact) -> [String] {
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

    private static func relaxedSearchAliases(for raw: String) -> [String] {
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

    private static func primaryPhone(_ contact: CNContact) -> String? {
        contact.phoneNumbers
            .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func primaryEmail(_ contact: CNContact) -> String? {
        contact.emailAddresses
            .map { String($0.value).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func contactSummaryDictionary(_ contact: CNContact) -> [String: Any] {
        [
            "identifier": contact.identifier,
            "name": formattedContactName(contact),
            "phone": primaryPhone(contact) ?? "",
            "company": contact.organizationName,
            "email": primaryEmail(contact) ?? ""
        ]
    }

    private static func contactSummaryText(_ contact: CNContact) -> String {
        var parts = [formattedContactName(contact)]
        if let phone = primaryPhone(contact) {
            parts.append(tr("电话 \(phone)", "phone \(phone)"))
        }
        if let email = primaryEmail(contact) {
            parts.append(tr("邮箱 \(email)", "email \(email)"))
        }
        let company = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty {
            parts.append(tr("公司 \(company)", "company \(company)"))
        }
        return parts.joined(separator: tr("，", ", "))
    }

    private static func searchContacts(
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
            candidates = try SystemStores.contacts.unifiedContacts(
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

    // 约定:
    // - 业务失败不抛出, 统一返回 CanonicalToolResult(success: false, ...)
    // - 系统失败才 throw, 由上层 ToolChain / Planner 的 catch 统一兜底
    private static func upsertCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        guard let rawName = args["name"] as? String else {
            return contactsFailure(
                summary: tr("联系人叫什么名字?", "What is the contact's name?"),
                detail: tr("缺少 name 参数", "Missing 'name' parameter"),
                errorCode: "NAME_MISSING"
            )
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return contactsFailure(
                summary: tr("联系人叫什么名字?", "What is the contact's name?"),
                detail: tr("缺少 name 参数", "Missing 'name' parameter"),
                errorCode: "NAME_MISSING"
            )
        }

        let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = (args["company"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        #if !os(iOS)
        let result = MacContactsMock.upsert(name: name, phone: phone, company: company, email: email, notes: notes)
        let summary: String = {
            if result.action == "updated" {
                return tr("已更新联系人\u{201C}\(name)\u{201D}。", "Updated contact \u{201C}\(name)\u{201D}.")
            } else {
                return tr("已创建联系人\u{201C}\(name)\u{201D}。", "Created contact \u{201C}\(name)\u{201D}.")
            }
        }()
        let detail = successPayload(
            result: summary,
            extras: [
                "action": result.action,
                "name": result.entry.name,
                "phone": result.entry.phone,
                "company": result.entry.company,
                "email": result.entry.email,
                "notes": result.entry.notes,
                "_macMock": true
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
            return contactsFailure(
                summary: tr(
                    "请先在系统设置里允许通讯录权限。",
                    "Please grant Contacts access in System Settings first."
                ),
                detail: tr("未获得通讯录权限", "Contacts permission not granted"),
                errorCode: "CONTACTS_PERMISSION_DENIED"
            )
        }

        let existingContact: CNContact?
        if let phone, !phone.isEmpty {
            existingContact = try findExistingContact(phone: phone)
        } else {
            existingContact = nil
        }

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
        try SystemStores.contacts.execute(saveRequest)

        let summary: String = {
            if action == "updated" {
                return tr("已更新联系人\u{201C}\(name)\u{201D}。", "Updated contact \u{201C}\(name)\u{201D}.")
            } else {
                return tr("已创建联系人\u{201C}\(name)\u{201D}。", "Created contact \u{201C}\(name)\u{201D}.")
            }
        }()
        let detail = successPayload(
            result: summary,
            extras: [
                "action": action,
                "name": name,
                "phone": phone ?? "",
                "company": company ?? "",
                "email": email ?? "",
                "notes": notes ?? ""
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #endif
    }

    private static func searchCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
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
            return contactsFailure(
                summary: tr(
                    "您想查谁呢? 请提供姓名、电话、邮箱或关键词。",
                    "Who are you looking for? Please provide a name, phone, email, or keyword."
                ),
                detail: tr(
                    "请至少提供 query、name、phone、email 或 identifier 其中一个参数",
                    "Please supply at least one of query, name, phone, email, or identifier"
                ),
                errorCode: "CONTACTS_QUERY_MISSING"
            )
        }

        #if !os(iOS)
        let matches = Array(MacContactsMock.search(
            identifier: identifier,
            name: name,
            phone: phone,
            email: email,
            query: query
        ).prefix(5))
        let items = matches.map(MacContactsMock.summaryDict)
        if matches.isEmpty {
            let summary = tr("未找到匹配的联系人。", "No matching contact was found.")
            let detail = successPayload(
                result: summary,
                extras: ["count": 0, "items": items, "_macMock": true]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }
        let lines = matches.map(MacContactsMock.summaryText)
        let summary = tr(
            "找到 \(matches.count) 个联系人：\(lines.joined(separator: "；"))。",
            "Found \(matches.count) contact\(matches.count == 1 ? "" : "s"): \(lines.joined(separator: "; "))."
        )
        let detail = successPayload(
            result: summary,
            extras: ["count": matches.count, "items": items, "_macMock": true]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
            return contactsFailure(
                summary: tr(
                    "请先在系统设置里允许通讯录权限。",
                    "Please grant Contacts access in System Settings first."
                ),
                detail: tr("未获得通讯录权限", "Contacts permission not granted"),
                errorCode: "CONTACTS_PERMISSION_DENIED"
            )
        }

        let matches = Array(try searchContacts(
            identifier: identifier,
            name: name,
            phone: phone,
            email: email,
            query: query
        ).prefix(5))
        let items = matches.map(contactSummaryDictionary)
        if matches.isEmpty {
            let summary = tr("未找到匹配的联系人。", "No matching contact was found.")
            let detail = successPayload(
                result: summary,
                extras: ["count": 0, "items": items]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }

        let lines = matches.map(contactSummaryText)
        let summary = tr(
            "找到 \(matches.count) 个联系人：\(lines.joined(separator: "；"))。",
            "Found \(matches.count) contact\(matches.count == 1 ? "" : "s"): \(lines.joined(separator: "; "))."
        )
        let detail = successPayload(
            result: summary,
            extras: ["count": matches.count, "items": items]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #endif
    }

    private static func deleteCanonical(_ args: [String: Any]) async throws -> CanonicalToolResult {
        let identifier = (args["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName?.trimmingCharacters(in: CharacterSet(charactersIn: "，。,？！!? "))
        let deleteAll: Bool = {
            if let b = args["all"] as? Bool { return b }
            if let s = args["all"] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
            return false
        }()

        guard identifier?.isEmpty == false
            || name?.isEmpty == false
            || phone?.isEmpty == false
            || email?.isEmpty == false
            || query?.isEmpty == false else {
            return contactsFailure(
                summary: tr(
                    "您想删谁呢? 请提供姓名、电话、邮箱或关键词。",
                    "Who do you want to delete? Please provide a name, phone, email, or keyword."
                ),
                detail: tr(
                    "请至少提供 query、name、phone、email 或 identifier 其中一个参数",
                    "Please supply at least one of query, name, phone, email, or identifier"
                ),
                errorCode: "CONTACTS_QUERY_MISSING"
            )
        }

        #if !os(iOS)
        let matches = MacContactsMock.search(identifier: identifier, name: name, phone: phone, email: email, query: query)
        if matches.isEmpty {
            let summary = tr("未找到匹配的联系人。", "No matching contact was found.")
            let detail = successPayload(
                result: summary,
                extras: ["count": 0, "deletedCount": "0", "_macMock": true]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }
        if matches.count > 1 && !deleteAll {
            let previews = matches.prefix(5).map(MacContactsMock.summaryText).joined(separator: "；")
            return contactsFailure(
                summary: tr(
                    "匹配到多个联系人，请提供更具体的信息，或明确说全部删除。",
                    "Multiple contacts matched. Please narrow the query, or explicitly confirm deleting all of them."
                ),
                detail: tr(
                    "匹配到多个联系人，请提供更具体的信息，或传 all=true 全部删除：\(previews)",
                    "Multiple contacts matched. Please narrow the query, or pass all=true to delete every match: \(previews)"
                ),
                errorCode: "CONTACTS_AMBIGUOUS_MATCH"
            )
        }

        MacContactsMock.delete(matches)
        if matches.count == 1 {
            let contact = matches[0]
            let summary = tr(
                "已删除联系人\u{201C}\(contact.name)\u{201D}。",
                "Deleted contact \u{201C}\(contact.name)\u{201D}."
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "identifier": contact.identifier,
                    "name": contact.name,
                    "phone": contact.phone,
                    "email": contact.email,
                    "deletedCount": "1",
                    "_macMock": true
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }

        let names = matches.map(\.name)
        let summary = tr(
            "已删除 \(matches.count) 位联系人：\(names.joined(separator: "、"))。",
            "Deleted \(matches.count) contacts: \(names.joined(separator: ", "))."
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "deletedCount": "\(matches.count)",
                "deletedNames": names.joined(separator: ","),
                "_macMock": true
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #else
        guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
            return contactsFailure(
                summary: tr(
                    "请先在系统设置里允许通讯录权限。",
                    "Please grant Contacts access in System Settings first."
                ),
                detail: tr("未获得通讯录权限", "Contacts permission not granted"),
                errorCode: "CONTACTS_PERMISSION_DENIED"
            )
        }

        let matches = try searchContacts(
            identifier: identifier,
            name: name,
            phone: phone,
            email: email,
            query: query
        )

        if matches.isEmpty {
            let summary = tr("未找到匹配的联系人。", "No matching contact was found.")
            let detail = successPayload(
                result: summary,
                extras: ["count": 0, "deletedCount": "0"]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }

        if matches.count > 1 && !deleteAll {
            let previews = matches.prefix(5).map(contactSummaryText).joined(separator: "；")
            return contactsFailure(
                summary: tr(
                    "匹配到多个联系人，请提供更具体的信息，或明确说全部删除。",
                    "Multiple contacts matched. Please narrow the query, or explicitly confirm deleting all of them."
                ),
                detail: tr(
                    "匹配到多个联系人，请提供更具体的信息，或传 all=true 全部删除：\(previews)",
                    "Multiple contacts matched. Please narrow the query, or pass all=true to delete every match: \(previews)"
                ),
                errorCode: "CONTACTS_AMBIGUOUS_MATCH"
            )
        }

        let saveRequest = CNSaveRequest()
        var deletedNames: [String] = []
        for contact in matches {
            let mutableContact = contact.mutableCopy() as! CNMutableContact
            saveRequest.delete(mutableContact)
            deletedNames.append(formattedContactName(contact))
        }
        try SystemStores.contacts.execute(saveRequest)

        if matches.count == 1 {
            let contact = matches[0]
            let summary = tr(
                "已删除联系人\u{201C}\(formattedContactName(contact))\u{201D}。",
                "Deleted contact \u{201C}\(formattedContactName(contact))\u{201D}."
            )
            let detail = successPayload(
                result: summary,
                extras: [
                    "identifier": contact.identifier,
                    "name": formattedContactName(contact),
                    "phone": primaryPhone(contact) ?? "",
                    "email": primaryEmail(contact) ?? "",
                    "deletedCount": "1"
                ]
            )
            return CanonicalToolResult(success: true, summary: summary, detail: detail)
        }

        let summary = tr(
            "已删除 \(matches.count) 位联系人：\(deletedNames.joined(separator: "、"))。",
            "Deleted \(matches.count) contacts: \(deletedNames.joined(separator: ", "))."
        )
        let detail = successPayload(
            result: summary,
            extras: [
                "deletedCount": "\(matches.count)",
                "deletedNames": deletedNames.joined(separator: ",")
            ]
        )
        return CanonicalToolResult(success: true, summary: summary, detail: detail)
        #endif
    }

    private static func contactsFailure(
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

#if !os(iOS)
// Mac CLI 上 CNContactStore 因 TCC 不可用. 上层 SKILL flow 仍真跑, 系统副作用层
// (CNSaveRequest.execute / CNContactStore.unifiedContacts) 走这个内存 mock —
// 跨工具状态保留 (upsert 写入, 后续 search/delete 能找到), harness scenario 端到端
// 行为跟 iOS 真机一致. 真实写入 Contacts.app 由 iOS 真机测兜底.
enum MacContactsMock {
    struct Entry {
        var identifier: String
        var name: String
        var phone: String
        var company: String
        var email: String
        var notes: String
    }
    static var entries: [Entry] = []

    static func upsert(name: String, phone: String?, company: String?, email: String?, notes: String?) -> (action: String, entry: Entry) {
        // phone 匹配 → 视为更新; 否则新建
        if let phone, !phone.isEmpty,
           let idx = entries.firstIndex(where: { $0.phone == phone }) {
            entries[idx].name = name
            if let company { entries[idx].company = company }
            if let email   { entries[idx].email   = email   }
            if let notes   { entries[idx].notes   = notes   }
            return ("updated", entries[idx])
        }
        let entry = Entry(
            identifier: "mock-mac-\(UUID().uuidString)",
            name: name,
            phone: phone ?? "",
            company: company ?? "",
            email: email ?? "",
            notes: notes ?? ""
        )
        entries.append(entry)
        return ("created", entry)
    }

    static func search(identifier: String?, name: String?, phone: String?, email: String?, query: String?) -> [Entry] {
        entries.filter { e in
            if let identifier, !identifier.isEmpty, e.identifier == identifier { return true }
            if let phone, !phone.isEmpty, e.phone == phone { return true }
            if let email, !email.isEmpty, !e.email.isEmpty, e.email == email { return true }
            if let name, !name.isEmpty, e.name.contains(name) { return true }
            if let query, !query.isEmpty,
               e.name.contains(query) || e.phone.contains(query) || e.company.contains(query) {
                return true
            }
            return false
        }
    }

    static func delete(_ targets: [Entry]) {
        let ids = Set(targets.map(\.identifier))
        entries.removeAll { ids.contains($0.identifier) }
    }

    static func summaryDict(_ e: Entry) -> [String: String] {
        ["identifier": e.identifier, "name": e.name, "phone": e.phone, "company": e.company, "email": e.email]
    }
    static func summaryText(_ e: Entry) -> String {
        var parts = [e.name]
        if !e.phone.isEmpty { parts.append(e.phone) }
        if !e.company.isEmpty { parts.append(e.company) }
        return parts.joined(separator: " ")
    }
}
#endif
