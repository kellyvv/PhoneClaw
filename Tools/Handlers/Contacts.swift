import Contacts
import Foundation

enum ContactsTools {

    static func register(into registry: ToolRegistry) {

        // ── contacts-upsert ──
        registry.register(RegisteredTool(
            name: "contacts-upsert",
            description: "创建或更新联系人；若提供手机号则优先按手机号查重再更新",
            parameters: "name: 联系人姓名, phone: 手机号（可选）, company: 公司（可选）, email: 邮箱（可选）, notes: 备注（可选）",
            requiredParameters: ["name"],
            aliases: ["contacts_upsert"]
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
                guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
                    return failurePayload(error: "未获得通讯录权限")
                }

                let existingContact = phone.flatMap { try? findExistingContact(phone: $0) }
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

                let actionText = action == "updated" ? "已更新" : "已创建"
                return successPayload(
                    result: "\(actionText)联系人\u{201C}\(name)\u{201D}。",
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

        // ── contacts-search ──
        registry.register(RegisteredTool(
            name: "contacts-search",
            description: "搜索联系人，可按姓名、手机号、邮箱、identifier 或关键词查询联系方式",
            parameters: "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）",
            requiredAnyOfParameters: ["query", "identifier", "name", "phone", "email"],
            aliases: ["contacts_search"]
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
                guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
                    return failurePayload(error: "未获得通讯录权限")
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
                    return successPayload(
                        result: "未找到匹配的联系人。",
                        extras: [
                            "count": 0,
                            "items": items
                        ]
                    )
                }

                let lines = matches.map(contactSummaryText)
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

        // ── contacts-delete ──
        registry.register(RegisteredTool(
            name: "contacts-delete",
            description: "删除联系人，可按姓名、手机号、邮箱、identifier 或关键词匹配后删除；匹配多个时可传 all=true 批量删除",
            parameters: "query: 搜索关键词（可选）, identifier: 联系人标识（可选）, name: 姓名（可选）, phone: 手机号（可选）, email: 邮箱（可选）, all: 多匹配时是否全部删除（可选，默认 false）",
            requiredAnyOfParameters: ["query", "identifier", "name", "phone", "email"],
            aliases: ["contacts_delete", "contacts-delete-contact"]
        ) { args in
            let identifier = (args["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = (args["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName?.trimmingCharacters(in: CharacterSet(charactersIn: "，。,？！!? "))
            // `all` 支持 bool 或字符串形式 (LLM 常出 "true" 字符串)
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
                return failurePayload(error: "请至少提供 query、name、phone、email 或 identifier 其中一个参数")
            }

            do {
                guard try await ToolRegistry.shared.requestAccess(for: .contacts) else {
                    return failurePayload(error: "未获得通讯录权限")
                }

                let matches = try searchContacts(
                    identifier: identifier,
                    name: name,
                    phone: phone,
                    email: email,
                    query: query
                )

                if matches.isEmpty {
                    return failurePayload(error: "未找到匹配的联系人")
                }

                // 多匹配: 未指定 all 时拒绝并列候选; 指定 all=true 时批量删除
                if matches.count > 1 && !deleteAll {
                    let previews = matches.prefix(5).map(contactSummaryText).joined(separator: "；")
                    return failurePayload(error: "匹配到多个联系人，请提供更具体的信息，或传 all=true 全部删除：\(previews)")
                }

                // 批量 / 单删统一走 CNSaveRequest 一次 commit
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
                    return successPayload(
                        result: "已删除联系人\u{201C}\(formattedContactName(contact))\u{201D}。",
                        extras: [
                            "identifier": contact.identifier,
                            "name": formattedContactName(contact),
                            "phone": primaryPhone(contact) ?? "",
                            "email": primaryEmail(contact) ?? "",
                            "deletedCount": "1"
                        ]
                    )
                } else {
                    return successPayload(
                        result: "已删除 \(matches.count) 位联系人：\(deletedNames.joined(separator: "、"))。",
                        extras: [
                            "deletedCount": "\(matches.count)",
                            "deletedNames": deletedNames.joined(separator: ",")
                        ]
                    )
                }
            } catch {
                return failurePayload(error: "删除联系人失败：\(error.localizedDescription)")
            }
        })
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

        return "未命名联系人"
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
}
