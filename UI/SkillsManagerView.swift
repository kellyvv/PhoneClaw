import SwiftUI

// MARK: - Skills 管理面板（iOS 版）

struct SkillsManagerView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSkills: Set<String> = []

    private var enabledCount: Int { engine.skillEntries.filter(\.isEnabled).count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部操作栏
                HStack(spacing: 12) {
                    Button { engine.reloadSkills() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }

                    Spacer()

                    Button("Enable all") { engine.setAllSkills(enabled: true) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Button("Disable all") { engine.setAllSkills(enabled: false) }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Rectangle().fill(Theme.border).frame(height: 1)

                // Skill 列表
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(engine.skillEntries.indices, id: \.self) { i in
                            SkillDetailCard(
                                entry: $engine.skillEntries[i],
                                isExpanded: expandedSkills.contains(engine.skillEntries[i].id),
                                onToggleExpand: { toggleExpand(engine.skillEntries[i].id) },
                                onSave: { content in
                                    try? engine.skillLoader.saveSkill(skillId: engine.skillEntries[i].id, content: content)
                                    engine.reloadSkills()
                                }
                            )
                        }
                    }
                    .padding(16)
                }

                Rectangle().fill(Theme.border).frame(height: 1)

                // 底部
                HStack {
                    Text("\(enabledCount)/\(engine.skillEntries.count) enabled")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Theme.bg)
        }
        .preferredColorScheme(.dark)
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
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @State private var showSource = false
    @State private var saveFlash = false

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
                    .font(.system(size: 15))
                    .foregroundStyle(entry.isEnabled ? Theme.accent : Theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(
                        entry.isEnabled ? Theme.accentSubtle : Theme.textTertiary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(entry.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: $entry.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            // ── 展开详情：三层架构 ──
            if isExpanded {
                Rectangle().fill(Theme.border).frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {

                    // ━━ L1: TOOLS（原生工具 · ToolRegistry） ━━
                    if !entry.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("TOOLS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .kerning(1)
                                Text("· ToolRegistry")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
                            }

                            ForEach(entry.tools, id: \.name) { tool in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: ToolRegistry.shared.hasToolNamed(tool.name) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(ToolRegistry.shared.hasToolNamed(tool.name) ? Theme.accentGreen : .orange)
                                        .frame(width: 14)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(tool.name)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(ToolRegistry.shared.hasToolNamed(tool.name) ? "registered" : "missing")
                                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(ToolRegistry.shared.hasToolNamed(tool.name) ? Theme.accentGreen : .orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    (ToolRegistry.shared.hasToolNamed(tool.name) ? Theme.accentGreen : Color.orange).opacity(0.12),
                                                    in: Capsule()
                                                )
                                        }
                                        Text(tool.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textSecondary)
                                        if tool.parameters != "无" {
                                            HStack(spacing: 4) {
                                                Text("参数:")
                                                    .foregroundStyle(Theme.textTertiary)
                                                Text(tool.parameters)
                                                    .foregroundStyle(Theme.textSecondary)
                                            }
                                            .font(.system(size: 10))
                                        }
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    // ━━ EXAMPLE ━━
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EXAMPLE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .kerning(1)

                        Text("\"\(entry.samplePrompt)\"")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .italic()
                    }

                    // ━━ L2: INSTRUCTIONS（Markdown body · 注入 LLM 上下文） ━━
                    if let body = skillBody {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("INSTRUCTIONS")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .kerning(1)
                                Text("· LLM Context")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
                            }

                            Text(body)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // ━━ SKILL.MD 源文件（查看 / 编辑 / 保存 / 热重载） ━━
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("SKILL.MD")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .kerning(1)

                            if let path = entry.filePath?.path {
                                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Theme.textTertiary.opacity(0.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if isEditing {
                                Button("Cancel") {
                                    isEditing = false
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)

                                Button {
                                    onSave(editText)
                                    isEditing = false
                                    showSource = true
                                    saveFlash = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        saveFlash = false
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.down.doc")
                                            .font(.system(size: 9))
                                        Text("Save & Reload")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(Theme.bg)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.accent, in: Capsule())
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
                                        Text("Edit")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(Theme.accent)
                                }

                                Button {
                                    if !showSource { editText = rawContent }
                                    showSource.toggle()
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: showSource ? "eye.slash" : "eye")
                                            .font(.system(size: 9))
                                        Text(showSource ? "Hide" : "View")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }

                        if saveFlash {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                Text("Saved & reloaded")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.accentGreen)
                            .transition(.opacity)
                        }

                        if showSource || isEditing {
                            if isEditing {
                                TextEditor(text: $editText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 180, maxHeight: 300)
                                    .padding(6)
                                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
                                    )
                            } else {
                                ScrollView {
                                    Text(editText)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 200)
                                .padding(6)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .opacity(entry.isEnabled ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.2), value: entry.isEnabled)
        .animation(.easeInOut(duration: 0.3), value: saveFlash)
    }
}
