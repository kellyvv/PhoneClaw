import SwiftUI
import Foundation

// MARK: - AI 回复

struct AIResponseView: View {
    let block: ResponseBlock
    let expandedSkills: Set<UUID>
    let isThinkingExpanded: Bool
    let onToggle: (UUID) -> Void
    let onToggleThinking: () -> Void
    let onRetry: (() -> Void)?

    private var hasSkill: Bool { !block.skills.isEmpty }
    private var hasThinkingText: Bool {
        guard let thinking = block.thinkingText else { return false }
        return !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isPureThinking: Bool {
        !hasSkill && !hasThinkingText && block.responseText == nil && block.isThinking
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 12) {
                if isPureThinking {
                    ThinkingIndicator()
                        .padding(.vertical, 10)
                }

                ForEach(block.skills) { card in
                    SkillCardView(
                        card: card,
                        isExpanded: expandedSkills.contains(card.id),
                        onToggle: { onToggle(card.id) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if let thinking = block.thinkingText, !thinking.isEmpty {
                    ThinkingCardView(
                        text: thinking,
                        isExpanded: isThinkingExpanded,
                        onToggle: onToggleThinking
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if hasSkill && block.isThinking && block.responseText == nil {
                    ThinkingIndicator()
                }

                if let text = block.responseText {
                    StreamingMarkdownView(
                        content: text,
                        isStreaming: block.isThinking
                    )
                    .padding(.trailing, 12)
                }

                if let onRetry, !block.isThinking {
                    Button(action: onRetry) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .regular))
                            Text(tr("重新生成", "Regenerate"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.quietAction)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: block.skills.count)

            Spacer(minLength: Theme.aiMinSpacer)
        }
    }
}

// MARK: - Streaming Markdown

/// Lightweight assistant text renderer.
/// MarkdownUI's default list typography is too document-like for the floating chat UI,
/// so plain text / lists / code blocks are mapped to a quieter local rhythm.
private struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AssistantTextBlock.parse(content)) { block in
                switch block.kind {
                case .paragraph(let text, let isLead):
                    Text(text)
                        .font(.system(size: isLead ? 14 : 14.5, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.assistantText.opacity(isLead ? 0.86 : 0.9))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)

                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(number)
                            .font(.system(size: 11.5, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary.opacity(0.5))
                            .frame(width: 13, alignment: .trailing)
                        Text(text)
                            .font(.system(size: 14.25, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.assistantText.opacity(0.86))
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.accentMuted.opacity(0.38))
                            .frame(width: 3.5, height: 3.5)
                            .padding(.top, 8.5)
                            .frame(width: 10)
                        Text(text)
                            .font(.system(size: 14.25, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.assistantText.opacity(0.86))
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .codeBlock(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .background(Theme.bgHover.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.vertical, 2)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(nil, value: content)
    }

    private var assistantTextMaxWidth: CGFloat {
        #if os(macOS)
        return 620
        #else
        return 322
        #endif
    }
}

private struct AssistantTextBlock: Identifiable {
    enum Kind {
        case paragraph(String, isLead: Bool)
        case numbered(String, String)
        case bullet(String)
        case codeBlock(String)
    }

    let id: Int
    var kind: Kind

    static func parse(_ source: String) -> [AssistantTextBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [AssistantTextBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            let text = clean(paragraph.joined(separator: " "))
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            let isLead = text.count <= 16 && text.hasSuffix("：")
            blocks.append(.init(id: blocks.count, kind: .paragraph(text, isLead: isLead)))
        }

        func flushCodeBlock() {
            let text = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            codeLines.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.init(id: blocks.count, kind: .codeBlock(text)))
        }

        func appendToLastList(_ text: String) -> Bool {
            let text = clean(text)
            guard !text.isEmpty, let lastIndex = blocks.indices.last else { return false }
            switch blocks[lastIndex].kind {
            case .numbered(let number, let existing):
                blocks[lastIndex].kind = .numbered(number, clean(existing + " " + text))
                return true
            case .bullet(let existing):
                blocks[lastIndex].kind = .bullet(clean(existing + " " + text))
                return true
            case .paragraph, .codeBlock:
                return false
            }
        }

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") {
                if isInCodeBlock {
                    flushCodeBlock()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flushParagraph()
                continue
            }

            if rawLine.first?.isWhitespace == true, appendToLastList(rawLine) {
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let item = numberedItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .numbered(item.number, clean(item.text))))
                continue
            }

            if let item = bulletItem(from: line) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .bullet(clean(item))))
                continue
            }

            paragraph.append(line)
        }

        flushParagraph()
        flushCodeBlock()
        return blocks
    }

    private static func numberedItem(from line: String) -> (number: String, text: String)? {
        var index = line.startIndex
        var number = ""
        while index < line.endIndex, line[index].isNumber {
            number.append(line[index])
            index = line.index(after: index)
        }
        guard !number.isEmpty, index < line.endIndex else { return nil }
        let marker = line[index]
        guard marker == "." || marker == "、" || marker == ")" || marker == "）" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index].isWhitespace else { return nil }
        let text = line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, text)
    }

    private static func bulletItem(from line: String) -> String? {
        let markers = ["- ", "* ", "• ", "· "]
        for marker in markers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func clean(_ raw: String) -> String {
        var text = raw
        for token in [
            "**", "__", "`",
            "(DEVICE_SKILLS)", "（DEVICE_SKILLS）",
            "(CONTENT_SKILLS)", "（CONTENT_SKILLS）"
        ] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "：  ", with: "：")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ,", with: ",")
        text = text.replacingOccurrences(of: " .", with: ".")
        text = text.replacingOccurrences(of: " :", with: ":")
        text = text.replacingOccurrences(of: " ：", with: "：")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Thinking Card

struct ThinkingCardView: View {
    let text: String
    let isExpanded: Bool
    let onToggle: () -> Void

    private var lineCount: Int {
        max(1, text.components(separatedBy: .newlines).count)
    }

    private var previewText: String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return tr("已捕获思考内容", "Captured thinking content") }
        return String(compact.prefix(72)) + (compact.count > 72 ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("思考", "Think"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if !isExpanded {
                        Text(previewText)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(tr("\(lineCount) 行", "\(lineCount) lines"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                Rectangle().fill(Theme.borderSubtle).frame(height: 1)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Skill Card

struct SkillCardView: View {
    let card: SkillCard
    let isExpanded: Bool
    let onToggle: () -> Void

    private var isSkillDone: Bool { card.skillStatus == "done" }

    private var toolKey: String {
        (card.toolName ?? "").lowercased()
    }

    private func toolNameContains(_ fragments: String...) -> Bool {
        fragments.contains { toolKey.contains($0) }
    }

    private enum SkillKind {
        case calendar
        case reminders
        case contacts
        case health
        case clipboard
        case translate
        case generic
    }

    private var skillKind: SkillKind {
        let key = "\(card.skillName) \(card.toolName ?? "")".lowercased()
        if key.contains("health") || key.contains("健康") || key.contains("步数") {
            return .health
        }
        if key.contains("calendar") || key.contains("日历") || key.contains("日程") {
            return .calendar
        }
        if key.contains("reminder") || key.contains("提醒") || key.contains("待办") {
            return .reminders
        }
        if key.contains("contact") || key.contains("通讯录") || key.contains("联系人") {
            return .contacts
        }
        if key.contains("clipboard") || key.contains("剪贴板") {
            return .clipboard
        }
        if key.contains("translate") || key.contains("翻译") {
            return .translate
        }
        return .generic
    }

    private var iconName: String {
        if toolNameContains("contacts-search") {
            return "magnifyingglass"
        }
        if toolNameContains("contacts-upsert") {
            return "person.badge.plus"
        }
        if toolNameContains("contacts-delete") {
            return "trash"
        }
        if toolNameContains("health-sleep") {
            return "moon"
        }
        if toolNameContains("health-workout") {
            return "figure.run"
        }
        if toolNameContains("health-active-energy") {
            return "flame"
        }
        if toolNameContains("health-heart") {
            return "heart"
        }

        switch skillKind {
        case .calendar: return "calendar"
        case .reminders: return "bell"
        case .contacts: return "person.crop.circle"
        case .health: return "figure.walk"
        case .clipboard: return "doc.on.clipboard"
        case .translate: return "character.bubble"
        case .generic: return "sparkles"
        }
    }

    private var statusTitle: String {
        if isSkillDone {
            if toolNameContains("calendar-create") {
                return tr("创建了日程", "Created Event")
            }
            if toolNameContains("reminders-create") {
                return tr("创建了提醒", "Created Reminder")
            }
            if toolNameContains("contacts-search") {
                return tr("查找了联系人", "Searched Contacts")
            }
            if toolNameContains("contacts-upsert") {
                return tr("保存了联系人", "Saved Contact")
            }
            if toolNameContains("contacts-delete") {
                return tr("删除了联系人", "Deleted Contact")
            }
            if toolNameContains("clipboard-write") {
                return tr("写入了剪贴板", "Updated Clipboard")
            }
            if toolNameContains("clipboard-read") {
                return tr("读取了剪贴板", "Read Clipboard")
            }
            if toolNameContains("health-sleep") {
                return tr("读取了睡眠", "Read Sleep")
            }
            if toolNameContains("health-workout") {
                return tr("读取了运动记录", "Read Workouts")
            }
            if toolNameContains("health-distance") {
                return tr("读取了距离", "Read Distance")
            }
            if toolNameContains("health-active-energy") {
                return tr("读取了活动消耗", "Read Active Energy")
            }
            if toolNameContains("health-heart") {
                return tr("读取了心率", "Read Heart Rate")
            }
            if toolNameContains("health-steps") {
                return tr("读取了步数", "Read Steps")
            }
            if skillKind == .translate {
                return tr("翻译完成", "Translation Ready")
            }

            switch skillKind {
            case .calendar: return tr("处理了日程", "Used Calendar")
            case .reminders: return tr("处理了提醒", "Used Reminders")
            case .contacts: return tr("处理了联系人", "Used Contacts")
            case .health: return tr("读取了健康数据", "Read Health Data")
            case .clipboard: return tr("读取了剪贴板", "Read Clipboard")
            case .translate: return tr("翻译完成", "Translation Ready")
            case .generic: return tr("使用了\(card.skillName)", "Used \(card.skillName)")
            }
        }

        if toolNameContains("calendar-create") {
            return tr("正在创建日程…", "Creating Event…")
        }
        if toolNameContains("reminders-create") {
            return tr("正在创建提醒…", "Creating Reminder…")
        }
        if toolNameContains("contacts-search") {
            return tr("正在查找联系人…", "Searching Contacts…")
        }
        if toolNameContains("contacts-upsert") {
            return tr("正在保存联系人…", "Saving Contact…")
        }
        if toolNameContains("contacts-delete") {
            return tr("正在删除联系人…", "Deleting Contact…")
        }
        if toolNameContains("clipboard-write") {
            return tr("正在写入剪贴板…", "Updating Clipboard…")
        }
        if toolNameContains("clipboard-read") {
            return tr("正在读取剪贴板…", "Reading Clipboard…")
        }
        if toolNameContains("health-sleep") {
            return tr("正在读取睡眠…", "Reading Sleep…")
        }
        if toolNameContains("health-workout") {
            return tr("正在读取运动记录…", "Reading Workouts…")
        }
        if toolNameContains("health-distance") {
            return tr("正在读取距离…", "Reading Distance…")
        }
        if toolNameContains("health-active-energy") {
            return tr("正在读取活动消耗…", "Reading Active Energy…")
        }
        if toolNameContains("health-heart") {
            return tr("正在读取心率…", "Reading Heart Rate…")
        }
        if toolNameContains("health-steps") {
            return tr("正在读取步数…", "Reading Steps…")
        }

        switch skillKind {
        case .calendar: return tr("正在处理日程…", "Using Calendar…")
        case .reminders: return tr("正在处理提醒…", "Using Reminders…")
        case .contacts: return tr("正在处理联系人…", "Using Contacts…")
        case .health: return tr("正在读取健康数据…", "Reading Health Data…")
        case .clipboard: return tr("正在读取剪贴板…", "Reading Clipboard…")
        case .translate: return tr("正在翻译…", "Translating…")
        case .generic: return tr("正在使用\(card.skillName)…", "Using \(card.skillName)…")
        }
    }

    private var currentStep: Int {
        switch card.skillStatus {
        case "identified": return 0
        case "loaded":     return 1
        case let s where s?.hasPrefix("executing") == true: return 2
        case "done":       return 3
        default:           return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ZStack {
                    Image(systemName: iconName)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.textTertiary.opacity(0.76))
                        .frame(width: 16, height: 16)
                        .opacity(isSkillDone ? 1 : 0)

                    SpinnerIcon()
                        .frame(width: 16, height: 16)
                        .opacity(isSkillDone ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.3), value: isSkillDone)

                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.78))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isSkillDone)

                Text(isExpanded ? tr("收起", "Hide") : tr("查看", "View"))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textTertiary.opacity(0.52))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.52))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .padding(.vertical, isExpanded ? 10 : 2)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                Rectangle().fill(Theme.borderSubtle).frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    stepRow(label: tr("理解需求", "Understand request"),
                            done: currentStep > 0,
                            active: currentStep == 0)
                    stepRow(label: tr("准备能力", "Prepare skill"),
                            done: currentStep > 1,
                            active: currentStep == 1)
                    stepRow(label: tr("执行能力", "Run skill"),
                            done: currentStep > 2,
                            active: currentStep == 2)
                    stepRow(label: tr("整理回复", "Compose reply"),
                            done: isSkillDone,
                            active: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.2), value: currentStep)
            }
        }
        .frame(maxWidth: isExpanded ? 322 : nil, alignment: .leading)
        .background(
            isExpanded ? Theme.bgHover.opacity(0.24) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.borderSubtle.opacity(0.9), lineWidth: 1)
            }
        }
    }

    private func stepRow(label: String, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 7) {
            Group {
                if done {
                    Circle()
                        .fill(Theme.accentMuted.opacity(0.58))
                        .frame(width: 5, height: 5)
                } else if active {
                    ProgressView().controlSize(.mini).tint(Theme.textTertiary)
                } else {
                    Circle()
                        .fill(Theme.textTertiary.opacity(0.24))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 12, height: 12)

            Text(label)
                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                .foregroundStyle(done ? Theme.textSecondary.opacity(0.74) : Theme.textTertiary.opacity(0.72))
        }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (time * 1.35 + Double(index) * 0.22)
                        .truncatingRemainder(dividingBy: 1.0)
                    let wave = (sin(phase * .pi * 2.0) + 1.0) / 2.0

                    Circle()
                        .fill(Theme.textTertiary)
                        .frame(width: 6, height: 6)
                        .opacity(0.28 + wave * 0.52)
                        .scaleEffect(0.72 + wave * 0.28)
                }
            }
            .frame(height: 20)
        }
    }
}
