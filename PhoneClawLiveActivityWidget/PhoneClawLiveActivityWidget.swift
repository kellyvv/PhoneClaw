import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 设计语言
//
// PhoneClaw LIVE 是系统级语音入口, 不是任务看板:
//   · 监听态只显示横向 6 个点, 自然循环波浪摆动
//   · Skill 链路让同一组点形成旋转圆环, 直到结果产生
//   · 结果态才展示结果符号和一句结果文案
//   · 所有表面读同一个 LiveIslandPresentation, 保持状态、色彩、动效一致

@main
struct PhoneClawLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        PhoneClawLiveActivityWidget()
        PhoneClawLiveLauncherWidget()
        if #available(iOS 18.0, *) {
            PhoneClawLiveControlWidget()
        }
    }
}

private let phoneClawLiveLaunchURL = URL(string: "phoneclaw://live?mode=voice")!
private let liveIslandFrameInterval: TimeInterval = 1.0 / 30.0

private enum LiveTheme {
    static let surface = Color(red: 0.055, green: 0.052, blue: 0.070)
    static let surfaceRaised = Color(red: 0.080, green: 0.076, blue: 0.100)
    static let line = Color.white.opacity(0.11)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
    static let signal = Color(red: 1.00, green: 0.62, blue: 0.32)
}

struct PhoneClawLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneClawLiveActivityAttributes.self) { context in
            LiveActivityBannerView(presentation: LiveIslandPresentation(state: context.state))
                .activityBackgroundTint(LiveTheme.surface)
                .activitySystemActionForegroundColor(.orange)
                .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
        } dynamicIsland: { context in
            let presentation = LiveIslandPresentation(state: context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.center, priority: 3) {
                    LiveIslandCoreVisual(presentation: presentation, diameter: 58)
                }
                DynamicIslandExpandedRegion(.bottom, priority: 2) {
                    LiveIslandResultPanel(presentation: presentation)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .padding(.bottom, presentation.visualPhase == .result ? 6 : 0)
                }
            } compactLeading: {
                LiveIslandCoreVisual(presentation: presentation, diameter: 34)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                LiveIslandCoreVisual(presentation: presentation, diameter: 24)
            }
            .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
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
            .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
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

    var stage: LiveIslandStage {
        if phase == "skill" { return .result }
        switch phase {
        case "starting": return .starting
        case "listening", "recording": return .voice
        case "understanding", "processing": return .thinking
        case "searching": return .searching
        case "executing": return .executing
        case "summarizing", "speaking": return .responding
        case "ended": return .ended
        default: return .idle
        }
    }

    var primaryLine: String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? moodText : trimmed
    }

    var visualPhase: LiveIslandVisualPhase {
        switch stage {
        case .voice:
            return .voice
        case .starting, .thinking, .searching, .executing, .responding:
            return .skill
        case .result:
            return .result
        case .ended, .idle:
            return .idle
        }
    }

    var moodText: String {
        if stage == .result {
            return state.success == false ? "未完成" : "已完成"
        }
        switch stage {
        case .starting: return "启动"
        case .voice: return phase == "recording" ? "聆听" : "待命"
        case .thinking, .searching: return "思考"
        case .executing: return "执行"
        case .responding: return "回应"
        case .ended: return "结束"
        case .idle: return "待命"
        case .result: return "完成"
        }
    }

    var accent: LiveAccent {
        if stage == .result {
            return state.success == false ? .red : .green
        }
        switch stage {
        case .voice, .thinking, .searching, .executing, .responding, .starting: return .amber
        case .ended, .idle: return .dim
        case .result: return .green
        }
    }

    var resultSymbolName: String {
        state.success == false ? "xmark" : "checkmark"
    }

    var resultAccessibilityText: String {
        state.success == false ? "未完成" : "已完成"
    }

}

private struct LiveAuroraCapsuleBackground: View {
    let presentation: LiveIslandPresentation
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LiveTheme.surfaceRaised.opacity(0.92))
            .overlay(alignment: .topLeading) {
                if presentation.accent.hasGlow {
                    Capsule()
                        .fill(presentation.accent.color.opacity(0.16))
                        .frame(width: 118, height: 42)
                        .blur(radius: 18)
                        .offset(x: -36, y: -16)
                }
            }
            .overlay(
                shape.stroke(LiveTheme.line, lineWidth: 1)
            )
            .clipShape(shape)
    }
}

private struct LiveIslandCoreVisual: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        ZStack {
            switch presentation.visualPhase {
            case .voice:
                LiveSixDotVoiceWave(presentation: presentation, diameter: diameter)
            case .skill:
                LiveRotatingSkillDotRing(presentation: presentation, diameter: diameter)
            case .result:
                LiveResultMark(presentation: presentation, diameter: diameter)
            case .idle:
                LiveIdleMark(presentation: presentation, diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(Text(presentation.moodText))
    }
}

private struct LiveSixDotVoiceWave: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: liveIslandFrameInterval)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dot = max(diameter * 0.105, 3.2)
            let spacing = max(diameter * 0.070, 2.2)
            let travel = diameter * 0.18
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<6, id: \.self) { index in
                    let carrier = (sin(t * 7.0 + Double(index) * 0.72) + 1.0) / 2.0
                    let envelope = 0.62 + 0.38 * ((sin(t * 2.1) + 1.0) / 2.0)
                    let level = 0.18 + carrier * envelope
                    Circle()
                        .fill(presentation.accent.glyph.opacity(0.42 + level * 0.46))
                        .frame(width: dot, height: dot)
                        .scaleEffect(0.82 + CGFloat(level) * 0.50)
                        .offset(y: CGFloat(0.5 - level) * travel)
                        .shadow(color: presentation.accent.color.opacity(0.16 + level * 0.26), radius: 2.5)
                }
            }
        }
    }
}

private struct LiveRotatingSkillDotRing: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: liveIslandFrameInterval)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dot = max(diameter * 0.125, 3.4)
            let orbit = diameter * 0.31
            let rotation = t * 1.45
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let phase = rotation + Double(index) * .pi * 2.0 / 6.0
                    let pulse = (sin(t * 4.2 + Double(index) * 0.82) + 1.0) / 2.0
                    Circle()
                        .fill(presentation.accent.glyph.opacity(0.58 + pulse * 0.34))
                        .frame(width: dot, height: dot)
                        .scaleEffect(0.86 + CGFloat(pulse) * 0.26)
                        .offset(
                            x: CGFloat(cos(phase)) * orbit,
                            y: CGFloat(sin(phase)) * orbit
                        )
                        .shadow(color: presentation.accent.color.opacity(0.18 + pulse * 0.28), radius: 2.8)
                }
            }
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(t * 42.0))
        }
    }
}

private struct LiveResultMark: View {
    let presentation: LiveIslandPresentation
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(presentation.accent.chipFill)
                .frame(width: diameter * 0.76, height: diameter * 0.76)
            Circle()
                .stroke(presentation.accent.dot.opacity(0.42), lineWidth: max(diameter * 0.050, 1.2))
                .frame(width: diameter * 0.76, height: diameter * 0.76)
            Image(systemName: presentation.resultSymbolName)
                .font(.system(size: max(diameter * 0.34, 9), weight: .bold))
                .foregroundStyle(presentation.accent.glyph)
        }
        .accessibilityLabel(Text(presentation.resultAccessibilityText))
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

private struct LiveIslandResultPanel: View {
    let presentation: LiveIslandPresentation

    @ViewBuilder
    var body: some View {
        if presentation.visualPhase == .result {
            Text(presentation.primaryLine)
                .font(.callout.weight(.medium))
                .foregroundStyle(LiveTheme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .multilineTextAlignment(.center)
                .id(presentation.primaryLine)
                .transition(.blurReplace)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 17))
        }
    }
}

private struct LiveMinimalActivityCard: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LiveIslandCoreVisual(presentation: presentation, diameter: 34)

            if presentation.visualPhase == .result {
                Text(presentation.primaryLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LiveTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .id(presentation.primaryLine)
                    .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity, alignment: presentation.visualPhase == .result ? .leading : .center)
        .padding(.horizontal, 1)
        .animation(.spring(duration: 0.42), value: presentation.visualPhase)
    }
}

// MARK: - 状态映射

/// 强调色档位 — 进行中统一 warm signal, 结果只用柔和绿/红。
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

// MARK: - 桌面快速启动小组件 (不变)

struct PhoneClawLiveLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "PhoneClawLiveLauncherWidget",
            provider: PhoneClawLiveLauncherProvider()
        ) { entry in
            PhoneClawLiveLauncherView(entry: entry)
                .widgetURL(phoneClawLiveLaunchURL)
        }
        .configurationDisplayName("PhoneClaw LIVE")
        .description("Open PhoneClaw directly in LIVE voice mode.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

private struct PhoneClawLiveLauncherEntry: TimelineEntry {
    let date: Date
}

private struct PhoneClawLiveLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneClawLiveLauncherEntry {
        PhoneClawLiveLauncherEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (PhoneClawLiveLauncherEntry) -> Void
    ) {
        completion(PhoneClawLiveLauncherEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<PhoneClawLiveLauncherEntry>) -> Void
    ) {
        completion(Timeline(entries: [PhoneClawLiveLauncherEntry(date: Date())], policy: .never))
    }
}

private struct PhoneClawLiveLauncherView: View {
    let entry: PhoneClawLiveLauncherEntry
    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        Group {
            switch widgetFamily {
            case .accessoryCircular:
                circularLauncher
            case .accessoryRectangular:
                rectangularLauncher
            case .accessoryInline:
                inlineLauncher
            default:
                systemSmallLauncher
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var systemSmallLauncher: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.06, blue: 0.10),
                    Color(red: 0.18, green: 0.12, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                    Image(systemName: "waveform")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 44, height: 44)

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("PhoneClaw")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    Text("LIVE")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("点按开始语音")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                }
            }
            .padding(14)
        }
    }

    private var circularLauncher: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private var rectangularLauncher: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("PhoneClaw LIVE")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("点按开始语音")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var inlineLauncher: some View {
        Label("PhoneClaw LIVE", systemImage: "waveform")
    }
}

@available(iOS 18.0, *)
struct PhoneClawLiveControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PhoneClawLiveControlWidget") {
            ControlWidgetButton(action: OpenURLIntent(phoneClawLiveLaunchURL)) {
                Label("PhoneClaw LIVE", systemImage: "waveform")
            }
            .tint(.orange)
        }
        .displayName("PhoneClaw LIVE")
        .description("Open PhoneClaw directly in LIVE voice mode.")
    }
}
