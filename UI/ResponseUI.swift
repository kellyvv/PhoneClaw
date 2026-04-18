import SwiftUI
import MarkdownUI

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
                        .padding(.leading, 12)
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
                        .padding(.leading, 12)
                }

                if let text = block.responseText {
                    StreamingMarkdownView(
                        content: text,
                        isStreaming: block.isThinking
                    )
                    .padding(.leading, 4)
                }

                if let onRetry, !block.isThinking {
                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text("重新生成")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: block.skills.count)

            Spacer(minLength: Theme.aiMinSpacer)
        }
    }
}

// MARK: - Streaming Markdown

/// Single-renderer streaming markdown. MarkdownUI throughout — no mid-stream
/// or end-of-stream renderer swap, so there is never a "re-render" visual jump.
///
/// `.contentTransition(.opacity)` is an environment value that cascades into
/// MarkdownUI's internal Text views. When content grows, new glyphs crossfade
/// in using the animation context provided by `.animation(_:value:)`.
/// This mirrors the per-glyph fade used by React-based streaming markdown
/// (e.g. Claude Code desktop) while keeping view identity stable.
private struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool

    var body: some View {
        Markdown(content)
            .markdownTextStyle {
                FontSize(15)
                ForegroundColor(Theme.textPrimary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(nil, value: content)
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
        guard !compact.isEmpty else { return localizedThinkingText("已捕获思考内容", "Captured thinking content") }
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
                    Text(localizedThinkingText("思考", "Think"))
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

                Text(localizedThinkingText("\(lineCount) 行", "\(lineCount) lines"))
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
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 7))
                        .opacity(isSkillDone ? 1 : 0)

                    SpinnerIcon()
                        .frame(width: 26, height: 26)
                        .opacity(isSkillDone ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.3), value: isSkillDone)

                Text(isSkillDone ? "Used \"\(card.skillName)\"" : "Running \"\(card.skillName)\"…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: isSkillDone)

                Spacer()

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

                VStack(alignment: .leading, spacing: 6) {
                    stepRow(label: "识别能力: \(card.skillName)",
                            done: currentStep > 0,
                            active: currentStep == 0)
                    stepRow(label: "加载 Skill 指令",
                            done: currentStep > 1,
                            active: currentStep == 1)
                    stepRow(label: card.toolName != nil ? "执行 \(card.toolName!)" : "执行工具",
                            done: currentStep > 2,
                            active: currentStep == 2)
                    stepRow(label: "生成回复",
                            done: isSkillDone,
                            active: false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.easeInOut(duration: 0.2), value: currentStep)
            }
        }
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func stepRow(label: String, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentGreen)
                } else if active {
                    ProgressView().controlSize(.mini).tint(Theme.textTertiary)
                } else {
                    Circle().fill(Theme.textTertiary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            .frame(width: 14, height: 14)

            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(done ? Theme.textSecondary : Theme.textTertiary)
        }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    @State private var active = 0
    let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.textTertiary)
                    .frame(width: 6, height: 6)
                    .opacity(active == i ? 1.0 : 0.3)
                    .scaleEffect(active == i ? 1.0 : 0.75)
                    .animation(.easeInOut(duration: 0.35), value: active)
            }
        }
        .frame(height: 20)
        .onReceive(timer) { _ in active = (active + 1) % 3 }
    }
}
