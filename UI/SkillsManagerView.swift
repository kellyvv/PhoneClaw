import SwiftUI

// MARK: - Skills 管理面板（iOS 版）

struct SkillsManagerView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSkills: Set<String> = []
    @State private var activeInfoTopic: SkillsInfoTopic?

    private var enabledCount: Int { engine.skillEntries.filter(\.isEnabled).count }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        heroSection
                        skillsList
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)

                bottomBar
            }

            if let topic = activeInfoTopic {
                InfoDisclosureOverlay(
                    title: topic.title,
                    message: topic.message
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeInfoTopic = nil
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(10)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle()
                        .fill(SkillsStyle.controlFill)
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SkillsStyle.secondary)
                        .opacity(0.58)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(tr("技能", "Skills"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SkillsStyle.muted)

            Spacer()

            Button {
                engine.reloadSkills()
            } label: {
                ZStack {
                    Circle()
                        .fill(SkillsStyle.controlFill)
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SkillsStyle.secondary)
                        .opacity(0.64)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            labelWithInfo(tr("已启用", "Enabled"), topic: .enabled)

            Text(tr("\(enabledCount) 项已启用", "\(enabledCount) enabled"))
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(SkillsStyle.ink)
                .monospacedDigit()

            Text(skillStateLine)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SkillsStyle.secondary)
        }
        .padding(.top, 34)
    }

    private var skillStateLine: String {
        let total = engine.skillEntries.count
        if total == 0 {
            return tr("暂无可用技能", "No skills available")
        }
        if enabledCount == total {
            return tr("全部技能已开启", "All skills are enabled")
        }
        if enabledCount == 0 {
            return tr("所有技能已关闭", "All skills are disabled")
        }
        return tr("共 \(total) 项技能", "\(total) skills total")
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                labelWithInfo(tr("技能", "Skills"), topic: .skills)

                Spacer()

                Menu {
                    Button(tr("全部开启", "Enable All")) {
                        engine.setAllSkills(enabled: true)
                    }

                    Button(tr("全部关闭", "Disable All")) {
                        engine.setAllSkills(enabled: false)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SkillsStyle.tertiary)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tr("批量操作", "Bulk Actions")))
            }

            VStack(spacing: 0) {
                ForEach(engine.skillEntries.indices, id: \.self) { i in
                    SkillDetailCard(
                        entry: $engine.skillEntries[i],
                        isExpanded: expandedSkills.contains(engine.skillEntries[i].id),
                        onToggleExpand: { toggleExpand(engine.skillEntries[i].id) },
                        onEnabledChange: { enabled in
                            engine.setSkill(id: engine.skillEntries[i].id, enabled: enabled)
                        },
                        onSave: { content in
                            try engine.skillRegistry.saveSkill(skillId: engine.skillEntries[i].id, content: content)
                            engine.reloadSkills()
                        }
                    )

                    if i < engine.skillEntries.count - 1 {
                        Rectangle()
                            .fill(SkillsStyle.hairline)
                            .frame(height: 1)
                            .padding(.vertical, expandedSkills.contains(engine.skillEntries[i].id) ? 14 : 12)
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Label(tr("技能", "Skills"), systemImage: "puzzlepiece.extension")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SkillsStyle.secondary)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text(tr("完成", "Done"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SkillsStyle.onPrimary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 11)
                    .background(SkillsStyle.primary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 34)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(Theme.bg)
    }

    private func labelWithInfo(_ title: String, topic: SkillsInfoTopic) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SkillsStyle.secondary)

            Button {
                activeInfoTopic = topic
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(SkillsStyle.tertiary.opacity(0.78), lineWidth: 1)
                        .frame(width: 16, height: 16)
                    Text("!")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SkillsStyle.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleExpand(_ id: String) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if expandedSkills.contains(id) {
                expandedSkills.remove(id)
            } else {
                expandedSkills.insert(id)
            }
        }
    }
}

// MARK: - 单个 Skill 详情卡片（三层架构展示 + 编辑）

struct SkillDetailCard: View {
    @Binding var entry: SkillEntry
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onEnabledChange: (Bool) -> Void
    let onSave: (String) throws -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @State private var showSource = false
    @State private var saveFlash = false
    @State private var saveError: String?

    /// L2: SKILL.md 的 Markdown body（指令体，注入 LLM）
    private var skillBody: String? {
        guard let url = entry.filePath,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(
            pattern: "^---\\s*\\n.*?\\n---\\s*\\n(.*)$",
            options: .dotMatchesLineSeparators
        ) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range),
           let bodyRange = Range(match.range(at: 1), in: content) {
            return String(content[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// 完整 SKILL.md 原始内容
    private var rawContent: String {
        guard let url = entry.filePath,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 头部 ──
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(entry.isEnabled ? SkillsStyle.ink : SkillsStyle.tertiary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: entry.isEnabled ? .medium : .regular))
                        .foregroundStyle(entry.isEnabled ? SkillsStyle.ink : SkillsStyle.secondary)
                    Text(entry.description)
                        .font(.system(size: 11))
                        .foregroundStyle(SkillsStyle.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { entry.isEnabled },
                        set: { onEnabledChange($0) }
                    )
                )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(SkillsStyle.ink)
                    .labelsHidden()

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SkillsStyle.tertiary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            // ── 展开详情：三层架构 ──
            if isExpanded {
                Rectangle().fill(SkillsStyle.hairline).frame(height: 1)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 14) {

                    // ━━ L1: TOOLS（原生工具 · ToolRegistry） ━━
                    if !entry.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(tr("工具", "Tools"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(SkillsStyle.tertiary)
                                    .kerning(1)
                                Text("· Registry")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(SkillsStyle.tertiary.opacity(0.6))
                            }

                            ForEach(entry.tools, id: \.name) { tool in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: ToolRegistry.shared.hasToolNamed(tool.name) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(ToolRegistry.shared.hasToolNamed(tool.name) ? SkillsStyle.secondary : SkillsStyle.danger)
                                        .frame(width: 14)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(tool.name)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(SkillsStyle.ink)
                                            Text(ToolRegistry.shared.hasToolNamed(tool.name) ? tr("可用", "Ready") : tr("缺失", "Missing"))
                                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(ToolRegistry.shared.hasToolNamed(tool.name) ? SkillsStyle.secondary : SkillsStyle.danger)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    (ToolRegistry.shared.hasToolNamed(tool.name) ? SkillsStyle.controlFill : SkillsStyle.danger.opacity(0.12)),
                                                    in: Capsule()
                                                )
                                        }
                                        Text(tool.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(SkillsStyle.secondary)
                                        // "no params" 哨兵跨两种 locale 都要识别 — Health/Clipboard
                                        // 的 parameters: tr("无", "None") 两种值都算空
                                        if tool.parameters != "无" && tool.parameters != "None" {
                                            HStack(spacing: 4) {
                                                Text(tr("参数:", "Parameters:"))
                                                    .foregroundStyle(SkillsStyle.tertiary)
                                                Text(tool.parameters)
                                                    .foregroundStyle(SkillsStyle.secondary)
                                            }
                                            .font(.system(size: 10))
                                        }
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(SkillsStyle.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    // ━━ EXAMPLE ━━
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("示例", "Example"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SkillsStyle.tertiary)
                            .kerning(1)

                        Text("\"\(entry.samplePrompt)\"")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(SkillsStyle.secondary)
                            .italic()
                    }

                    // ━━ L2: INSTRUCTIONS（Markdown body · 注入 LLM 上下文） ━━
                    if let body = skillBody {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(tr("指令", "Instructions"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(SkillsStyle.tertiary)
                                    .kerning(1)
                                Text("· Context")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(SkillsStyle.tertiary.opacity(0.6))
                            }

                            Text(body)
                                .font(.system(size: 11))
                                .foregroundStyle(SkillsStyle.secondary)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(SkillsStyle.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    // ━━ SKILL.MD 源文件（查看 / 编辑 / 保存 / 热重载） ━━
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(tr("源文件", "Source"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SkillsStyle.tertiary)
                                .kerning(1)

                            if let path = entry.filePath?.path {
                                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(SkillsStyle.tertiary.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if isEditing {
                                Button(tr("取消", "Cancel")) {
                                    isEditing = false
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(SkillsStyle.tertiary)

                                Button {
                                    do {
                                        try onSave(editText)
                                        isEditing = false
                                        showSource = true
                                        saveError = nil
                                        saveFlash = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            saveFlash = false
                                        }
                                    } catch {
                                        saveFlash = false
                                        saveError = error.localizedDescription
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.down.doc")
                                            .font(.system(size: 9))
                                        Text(tr("保存", "Save"))
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(SkillsStyle.onPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(SkillsStyle.primary, in: Capsule())
                                }
                            } else {
                                Button {
                                    editText = rawContent
                                    isEditing = true
                                    showSource = true
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 9))
                                        Text(tr("编辑", "Edit"))
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(SkillsStyle.ink)
                                }

                                Button {
                                    if !showSource { editText = rawContent }
                                    showSource.toggle()
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: showSource ? "eye.slash" : "eye")
                                            .font(.system(size: 9))
                                        Text(showSource ? tr("收起", "Hide") : tr("查看", "View"))
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(SkillsStyle.secondary)
                                }
                            }
                        }

                        if saveFlash {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                Text(tr("已保存", "Saved"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(SkillsStyle.secondary)
                            .transition(.opacity)
                        }

                        if let saveError {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.top, 1)
                                Text(saveError)
                                    .font(.system(size: 11, weight: .regular))
                                    .lineLimit(2)
                            }
                            .foregroundStyle(SkillsStyle.danger)
                            .transition(.opacity)
                        }

                        if showSource || isEditing {
                            if isEditing {
                                TextEditor(text: $editText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(SkillsStyle.ink)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 180, maxHeight: 300)
                                    .padding(6)
                                    .background(SkillsStyle.selectedFill, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(SkillsStyle.hairline, lineWidth: 1)
                                    )
                            } else {
                                ScrollView {
                                    Text(editText)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(SkillsStyle.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 200)
                                .padding(6)
                                .background(SkillsStyle.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
        .opacity(entry.isEnabled ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: entry.isEnabled)
        .animation(.easeInOut(duration: 0.3), value: saveFlash)
    }
}

private enum SkillsInfoTopic: Identifiable {
    case enabled
    case skills

    var id: String {
        switch self {
        case .enabled: return "enabled"
        case .skills: return "skills"
        }
    }

    var title: String {
        switch self {
        case .enabled:
            return tr("已启用", "Enabled")
        case .skills:
            return tr("技能", "Skills")
        }
    }

    var message: String {
        switch self {
        case .enabled:
            return tr("开启的技能会进入助手可用能力范围。", "Enabled skills are available to the assistant.")
        case .skills:
            return tr("按需开启技能，列表越干净，助手越容易聚焦。", "Enable only what you need so the assistant stays focused.")
        }
    }
}

private enum SkillsStyle {
    static let ink = Color(light: "303033", dark: "EEE9DF")
    static let primary = Color(light: "2F3033", dark: "EEE9DF")
    static let onPrimary = Color(light: "FFFFFF", dark: "1D1A16")
    static let secondary = Color(light: "7A756E", dark: "B9AFA3")
    static let muted = Color(light: "8B857C", dark: "A89F94")
    static let tertiary = Color(light: "B9B0A5", dark: "7F766A")
    static let hairline = Color(light: "E8E2D8", dark: "373128")
    static let controlFill = Color(light: "ECE8E0", dark: "2C2821").opacity(0.76)
    static let selectedFill = Color(light: "FFFFFF", dark: "211E19").opacity(0.72)
    static let danger = Color(light: "9E554D", dark: "E08B80")
}
