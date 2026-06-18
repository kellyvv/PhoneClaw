import AppIntents
import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// MARK: - 设计语言
//
// LiveLand 是系统级语音入口, 不是任务看板；App 内 LIVE Mode 仍是独立实时语音模式。
// 灵动岛只保留三种状态:
//   · Listening: 短岛, 左侧三条 amber 音频柱, 普通理解/回复也保持低反馈。
//   · Skill: 只有真实 tool/skill 执行时才拉长, 左侧三段 amber 环, 右侧“正在执行”。
//   · Result: 最大展开 Live Activity, 纯文本结果预览优先, 不展示来源列表。
// 第三方 Live Activity 会被系统快照/挂起; 这里用状态切换和系统级过渡, 不放自绘帧循环。

@main
struct PhoneClawLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        PhoneClawLiveActivityWidget()
        PhoneClawLiveLandLauncherWidget()
        if #available(iOS 18.0, *) {
            PhoneClawLiveLandControlWidget()
        }
    }
}

private let phoneClawLiveModeLaunchURL = URL(string: "phoneclaw://live?mode=voice")!
private let phoneClawLiveLandLaunchURL = URL(string: "phoneclaw://liveland")!

private enum LiveTheme {
    static let surface = Color(red: 0.055, green: 0.052, blue: 0.070)
    static let surfaceRaised = Color(red: 0.080, green: 0.076, blue: 0.100)
    static let line = Color.white.opacity(0.11)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let skillStatusText = Color.white.opacity(0.36)
    static let tertiaryText = Color.white.opacity(0.36)
    static let signal = Color(red: 1.00, green: 0.62, blue: 0.32)
}

struct PhoneClawLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneClawLiveActivityAttributes.self) { context in
            let presentation = LiveIslandPresentation(state: context.state)
            LiveActivityBannerView(presentation: presentation)
                .activityBackgroundTint(LiveTheme.surface)
                .activitySystemActionForegroundColor(.orange)
                .widgetURL(presentation.launchURL)
        } dynamicIsland: { context in
            let presentation = LiveIslandPresentation(state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 2) {
                    if presentation.visualPhase != .result {
                        LiveIslandCoreVisual(
                            presentation: presentation,
                            diameter: presentation.expandedGlyphDiameter
                        )
                    }
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    if presentation.visualPhase != .result {
                        if presentation.visualPhase == .skill || presentation.hasStartupConfirmation {
                            LiveIslandSkillStatusLabel(presentation: presentation)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center, priority: 3) {
                    if presentation.visualPhase == .result {
                        LiveResultExpandedText(presentation: presentation)
                    }
                }
            } compactLeading: {
                if presentation.visualPhase == .result {
                    LiveIslandCoreVisual(presentation: presentation, diameter: 18)
                } else {
                    LiveIslandCoreVisual(
                        presentation: presentation,
                        diameter: presentation.visualPhase == .voice ? 22 : 24
                    )
                }
            } compactTrailing: {
                if presentation.visualPhase == .result {
                    EmptyView()
                } else {
                    LiveIslandCompactTrailing(presentation: presentation)
                }
            } minimal: {
                LiveIslandCoreVisual(presentation: presentation, diameter: 18)
            }
            .widgetURL(presentation.launchURL)
        }
    }
}

// MARK: - 锁屏 / 横幅卡

private struct LiveActivityBannerView: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        LiveMinimalActivityCard(presentation: presentation)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .widgetURL(presentation.launchURL)
    }
}

// MARK: - 共享小件

private enum LiveIslandStage {
    case starting
    case voice
    case thinking
    case searching
    case executing
    case responding
    case result
    case ended
    case idle
}

private enum LiveIslandVisualPhase {
    case voice
    case skill
    case result
    case idle
}

private struct LiveIslandPresentation {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var phase: String { state.phase }
    var detail: String { state.detail }

    var launchURL: URL {
        state.entryPoint == "liveLand"
            ? phoneClawLiveLandLaunchURL
            : phoneClawLiveModeLaunchURL
    }

    var stage: LiveIslandStage {
        if phase == "result" { return .result }
        switch phase {
        case "starting": return .starting
        case "listening", "recording": return .voice
        case "skill": return .executing
        case "understanding", "processing": return .thinking
        case "searching": return .searching
        case "executing": return .executing
        case "summarizing", "speaking": return .responding
        case "ended": return .ended
        default: return .idle
        }
    }

    var primaryLine: String {
        explicitDetail.isEmpty ? moodText : explicitDetail
    }

    var explicitDetail: String {
        detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasStartupConfirmation: Bool {
        stage == .starting && !explicitDetail.isEmpty
    }

    var visualPhase: LiveIslandVisualPhase {
        if stage == .result {
            return .result
        }
        if isSkillExecutionPhase {
            return .skill
        }
        switch stage {
        case .starting, .voice, .thinking, .searching, .executing, .responding:
            return .voice
        case .ended, .idle:
            return .idle
        case .result:
            return .result
        }
    }

    private var hasSkillIdentity: Bool {
        let skillID = state.skillID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let toolName = state.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !skillID.isEmpty || !toolName.isEmpty
    }

    private var isSkillExecutionPhase: Bool {
        if phase == "skill" { return true }
        guard hasSkillIdentity else { return false }
        return phase == "searching" ||
            phase == "executing" ||
            phase == "summarizing"
    }

    var moodText: String {
        if stage == .result {
            return state.success == false ? "未完成" : "结果"
        }
        if isSkillExecutionPhase {
            return skillStatusText
        }
        switch stage {
        case .starting, .voice, .thinking, .searching, .executing, .responding:
            return "聆听"
        case .ended: return "结束"
        case .idle: return "待命"
        case .result: return "完成"
        }
    }

    private static let skillStatusTexts: Set<String> = [
        "正在查询",
        "正在执行",
        "正在处理",
        "正在整理"
    ]

    var skillStatusText: String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.skillStatusTexts.contains(trimmed) {
            return trimmed
        }
        switch phase {
        case "searching":
            return "正在查询"
        case "executing":
            return "正在执行"
        case "summarizing":
            return "正在整理"
        default:
            return "正在处理"
        }
    }

    var accent: LiveAccent {
        if stage == .result {
            return state.success == false ? .red : .amber
        }
        switch stage {
        case .voice, .thinking, .searching, .executing, .responding, .starting: return .amber
        case .ended, .idle: return .dim
        case .result: return .amber
        }
    }

    var resultAccessibilityText: String {
        state.success == false ? "未完成，\(resultPlainText)" : resultPlainText
    }

    var resultHeadline: String {
        let lines = resultContentLines
        return lines.first ?? resultFallbackLine
    }

    var resultPlainText: String {
        let text = resultContentLines
            .map(strippingListMarker)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? resultFallbackLine : text
    }

    var resultSummary: String {
        Array(resultContentLines.dropFirst())
            .map(strippingListMarker)
            .joined(separator: "\n")
    }

    var expandedGlyphDiameter: CGFloat {
        switch visualPhase {
        case .voice: return 28
        case .result: return 24
        case .skill: return 32
        case .idle: return 20
        }
    }

    private var resultContentLines: [String] {
        let lines = detail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !isResultSectionHeading($0) }
            .filter { !isSourceMetadataLine($0) }
        return lines
    }

    private var resultFallbackLine: String {
        let candidates = [
            state.headline,
            state.skillName,
            state.toolName,
            "结果已准备好"
        ]
        return candidates
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .first { !$0.isEmpty && !isResultSectionHeading($0) && !isSourceMetadataLine($0) }
            ?? "结果已准备好"
    }

    private func isResultSectionHeading(_ line: String) -> Bool {
        let normalized = line.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*_ "))
        return normalized == "总结" ||
            normalized == "summary" ||
            normalized == "结果" ||
            normalized == "result"
    }

    private func isSourceMetadataLine(_ line: String) -> Bool {
        let lowercasedLine = line.lowercased()
        if lowercasedLine.hasPrefix("source:") ||
            lowercasedLine.hasPrefix("sources:") ||
            line.hasPrefix("来源：") ||
            line.hasPrefix("来源:") ||
            line.hasPrefix("引用网址") ||
            line.hasPrefix("引用 URL") {
            return true
        }

        let stripped = strippingListMarker(from: line)
        let strippedLower = stripped.lowercased()
        let hasMarkdownURL = strippedLower.range(
            of: #"^\[[^\]\n]{1,160}\]\(https?://[^)]+\)"#,
            options: .regularExpression
        ) != nil
        let startsWithURL = strippedLower.hasPrefix("http://") ||
            strippedLower.hasPrefix("https://") ||
            strippedLower.hasPrefix("www.")
        return hasMarkdownURL || startsWithURL
    }

    private func strippingListMarker(from line: String) -> String {
        var output = line.trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(
            of: #"^\d+[.)、]\s*"#,
            with: "",
            options: .regularExpression
        )
        for marker in ["- ", "* ", "• ", "· ", "✦ "] where output.hasPrefix(marker) {
            output = String(output.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

}

private struct LiveIslandCoreVisual: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        ZStack {
            glyph
                .id(presentation.visualPhase)
                .transition(phaseTransition)
        }
        .frame(width: diameter, height: diameter)
        .animation(.spring(response: 0.46, dampingFraction: 0.84, blendDuration: 0.08), value: presentation.visualPhase)
        .accessibilityLabel(Text(presentation.moodText))
    }

    @ViewBuilder
    private var glyph: some View {
        switch presentation.visualPhase {
        case .voice:
            LiveListeningBarsGlyph(presentation: presentation, diameter: diameter)
        case .skill:
            LiveSkillOrbitGlyph(presentation: presentation, diameter: diameter)
        case .result:
            LiveResultGlyph(presentation: presentation, diameter: diameter)
        case .idle:
            LiveIdleMark(presentation: presentation, diameter: diameter)
        }
    }

    private var phaseTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.72).combined(with: .opacity),
            removal: .scale(scale: 1.08).combined(with: .opacity)
        )
    }
}

private struct LiveListeningBarsGlyph: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        let barWidth = max(diameter * 0.105, 2.4)
        let barSpacing = max(diameter * 0.13, 2.6)

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            presentation.accent.color.opacity(0.16),
                            presentation.accent.color.opacity(0.05),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.54
                    )
                )
                .frame(width: diameter * 0.96, height: diameter * 0.96)

            HStack(alignment: .center, spacing: barSpacing) {
                listeningBar(width: barWidth, height: max(diameter * 0.42, 8), opacity: 0.86)
                listeningBar(width: barWidth, height: max(diameter * 0.66, 14), opacity: 1.0)
                listeningBar(width: barWidth, height: max(diameter * 0.42, 8), opacity: 0.86)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: presentation.accent.color.opacity(0.34), radius: max(diameter * 0.16, 3))
    }

    private func listeningBar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        presentation.accent.color.opacity(0.78 * opacity),
                        presentation.accent.color.opacity(opacity),
                        presentation.accent.color.opacity(0.72 * opacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.22 * opacity))
                    .frame(width: width * 0.48, height: 1)
                    .padding(.top, 1)
            }
    }
}

private struct LiveSkillOrbitGlyph: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        let lineWidth = max(diameter * 0.108, 2.7)
        let ringSize = diameter * 0.82

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            presentation.accent.color.opacity(0.20),
                            presentation.accent.color.opacity(0.07),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.62
                    )
                )
                .frame(width: diameter * 1.24, height: diameter * 1.24)

            ForEach(Self.ringSegments.indices, id: \.self) { index in
                let segment = Self.ringSegments[index]
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(
                        AngularGradient(
                            colors: [
                                presentation.accent.color.opacity(0.70),
                                presentation.accent.color,
                                presentation.accent.color.opacity(0.82)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .frame(width: ringSize, height: ringSize)
                    .shadow(color: presentation.accent.color.opacity(0.46), radius: max(diameter * 0.08, 2.0))
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: presentation.accent.color.opacity(0.34), radius: max(diameter * 0.18, 3.2))
    }

    private static let ringSegments: [(start: CGFloat, end: CGFloat)] = [
        (0.06, 0.20),
        (0.29, 0.40),
        (0.53, 0.68),
        (0.79, 0.91)
    ]
}

private struct LiveResultGlyph: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(presentation.accent.color.opacity(0.16))
                .frame(width: diameter, height: diameter)

            Circle()
                .stroke(presentation.accent.color.opacity(0.72), lineWidth: max(diameter * 0.075, 1.8))
                .frame(width: diameter * 0.82, height: diameter * 0.82)

            Image(systemName: presentation.state.success == false ? "xmark" : "checkmark")
                .font(.system(size: max(diameter * 0.34, 8), weight: .bold))
                .foregroundStyle(presentation.accent.color)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: presentation.accent.color.opacity(0.24), radius: max(diameter * 0.10, 2))
    }
}

private struct LiveIslandSkillStatusLabel: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Text(labelText)
            .font(.system(size: 16, weight: .semibold, design: .default))
            .foregroundStyle(LiveTheme.skillStatusText)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
            .frame(minWidth: 92, alignment: .trailing)
            .padding(.trailing, 12)
            .contentTransition(.opacity)
    }

    private var labelText: String {
        presentation.hasStartupConfirmation ? presentation.primaryLine : presentation.skillStatusText
    }
}

private struct LiveIslandCompactTrailing: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Group {
            if presentation.visualPhase == .skill {
                Text(presentation.skillStatusText)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(LiveTheme.skillStatusText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 72, alignment: .trailing)
                    .padding(.trailing, 4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                EmptyView()
            }
        }
    }
}

private struct LiveIdleMark: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        Circle()
            .fill(presentation.accent.dot)
            .frame(width: max(diameter * 0.22, 5), height: max(diameter * 0.22, 5))
    }
}

private struct LiveResultExpandedText: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Text(presentation.resultPlainText)
            .font(.system(size: 20, weight: .semibold, design: .default))
            .foregroundStyle(LiveTheme.primaryText)
            .lineLimit(4)
            .minimumScaleFactor(0.58)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .accessibilityLabel(Text(presentation.resultAccessibilityText))
    }
}

private struct LiveMinimalActivityCard: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Group {
            if presentation.visualPhase == .result {
                LiveResultExpandedText(presentation: presentation)
            } else if presentation.hasStartupConfirmation {
                HStack(alignment: .center, spacing: 12) {
                    LiveIslandCoreVisual(presentation: presentation, diameter: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LiveLand")
                            .font(.system(size: 16, weight: .semibold, design: .default))
                            .foregroundStyle(LiveTheme.primaryText)
                            .lineLimit(1)
                        Text(presentation.primaryLine)
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundStyle(LiveTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    LiveIslandCoreVisual(presentation: presentation, diameter: 34)
                    Spacer(minLength: 0)
                    if presentation.visualPhase == .skill {
                        LiveIslandSkillStatusLabel(presentation: presentation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 1)
    }
}

// MARK: - 状态映射

/// 强调色档位 — LIVE 视觉统一 amber, 失败结果保留 red。
private enum LiveAccent {
    case amber
    case green
    case red
    case dim

    var color: Color {
        switch self {
        case .amber: return LiveTheme.signal
        case .green: return Color(red: 0.48, green: 0.78, blue: 0.58)
        case .red: return Color(red: 0.90, green: 0.42, blue: 0.38)
        case .dim: return .white
        }
    }

    var glyph: Color {
        switch self {
        case .dim: return LiveTheme.secondaryText
        default: return color
        }
    }

    var chipFill: Color {
        switch self {
        case .dim: return .white.opacity(0.08)
        default: return color.opacity(0.14)
        }
    }

    var dot: Color {
        switch self {
        case .amber, .green, .red: return color
        case .dim: return LiveTheme.tertiaryText
        }
    }

    var hasGlow: Bool {
        switch self {
        case .amber, .green, .red: return true
        case .dim: return false
        }
    }
}

// MARK: - 桌面 / 锁屏 LiveLand 快速入口

struct PhoneClawLiveLandLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "PhoneClawLiveLandLauncherWidget",
            provider: PhoneClawLiveLandLauncherProvider()
        ) { entry in
            PhoneClawLiveLandLauncherView(entry: entry)
                .widgetURL(phoneClawLiveLandLaunchURL)
        }
        .configurationDisplayName("LiveLand")
        .description("Open PhoneClaw and start LiveLand microphone listening.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
        .contentMarginsDisabled()
    }
}

private struct PhoneClawLiveLandLauncherEntry: TimelineEntry {
    let date: Date
}

private struct PhoneClawLiveLandLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneClawLiveLandLauncherEntry {
        PhoneClawLiveLandLauncherEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (PhoneClawLiveLandLauncherEntry) -> Void
    ) {
        completion(PhoneClawLiveLandLauncherEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<PhoneClawLiveLandLauncherEntry>) -> Void
    ) {
        completion(Timeline(entries: [PhoneClawLiveLandLauncherEntry(date: Date())], policy: .never))
    }
}

private struct LiveLandLauncherMark: View {
    enum Style {
        case badge
        case pill
        case barsOnly
    }

    let size: CGFloat
    var style: Style

    var body: some View {
        ZStack {
            switch style {
            case .badge:
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.16, blue: 0.11),
                                Color(red: 0.13, green: 0.09, blue: 0.07)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                pill(width: size * 0.64, height: size * 0.28)
                LiveLandListeningBars(height: size * 0.39, color: .liveLandAmber)

            case .pill:
                pill(width: size, height: size * 0.48)
                LiveLandListeningBars(height: size * 0.56, color: .liveLandAmber)

            case .barsOnly:
                LiveLandListeningBars(height: size, color: .liveLandAmber)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func pill(width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.74),
                        Color(red: 0.10, green: 0.075, blue: 0.06).opacity(0.78)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
    }
}

private struct LiveLandListeningBars: View {
    let height: CGFloat
    var color: Color

    var body: some View {
        let barWidth = max(height * 0.18, 2)
        let spacing = max(height * 0.24, 3)
        HStack(alignment: .center, spacing: spacing) {
            bar(width: barWidth, height: height * 0.62)
            bar(width: barWidth, height: height)
            bar(width: barWidth, height: height * 0.62)
        }
        .frame(height: height)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
            .shadow(color: color.opacity(0.34), radius: max(width * 1.7, 2), y: 0)
    }
}

private extension Color {
    static let liveLandAmber = Color(red: 1.0, green: 0.62, blue: 0.16)
}

private struct PhoneClawLiveLandLauncherView: View {
    let entry: PhoneClawLiveLandLauncherEntry
    @Environment(\.widgetFamily) private var widgetFamily

    @ViewBuilder
    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            circularLauncher
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            rectangularLauncher
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            inlineLauncher
                .containerBackground(.clear, for: .widget)
        default:
            systemSmallLauncher
        }
    }

    // systemSmall：整张 LiveLand 图铺满小组件。
    // launcherFill 内的 Color.black 是贪婪视图，确保 body 占满整块（绝不出现"空 body→系统灰占位"）；
    // 图叠在黑底之上 scaledToFill 铺满。配合 widget 的 .contentMarginsDisabled() 真正贴边。
    private var systemSmallLauncher: some View {
        launcherFill
            .containerBackground(.clear, for: .widget)
            .accessibilityElement()
            .accessibilityLabel(Text("PhoneClaw LiveLand"))
            .accessibilityHint(Text("点按监听"))
    }

    @ViewBuilder
    private var launcherFill: some View {
        ZStack {
            // 始终可见的实底：只要 widget 渲染成功就绝不会是系统灰占位（也作诊断锚点）
            Color.black
            if let image = UIImage(named: "liveland_launcher", in: .main, compatibleWith: nil) {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFill()
            } else {
                LiveLandLauncherMark(size: 96, style: .badge)
            }
        }
    }

    private var circularLauncher: some View {
        ZStack {
            AccessoryWidgetBackground()
            LiveLandLauncherMark(size: 26, style: .pill)
        }
    }

    private var rectangularLauncher: some View {
        HStack(spacing: 8) {
            LiveLandLauncherMark(size: 20, style: .barsOnly)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("PhoneClaw LiveLand")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("点按监听")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var inlineLauncher: some View {
        Label("LiveLand", systemImage: "waveform")
    }
}

@available(iOS 18.0, *)
struct PhoneClawLiveLandControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PhoneClawLiveLandControlWidget") {
            ControlWidgetButton(action: OpenURLIntent(phoneClawLiveLandLaunchURL)) {
                Label("LiveLand", systemImage: "waveform")
            }
            .tint(.orange)
        }
        .displayName("LiveLand")
        .description("Open PhoneClaw and start LiveLand microphone listening.")
    }
}
