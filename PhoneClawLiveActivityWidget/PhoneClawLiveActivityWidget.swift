import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 设计语言
//
// PhoneClaw LIVE 是系统级语音入口, 不是任务看板:
//   · 一个主状态、一句主正文、一条细进度, 避免灵动岛信息过载
//   · 进行中统一使用 warm signal, 完成/失败仅在结果态低饱和提示
//   · compact 只表达「LIVE 还在运行」和当前状态, expanded 才显示正文
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
                DynamicIslandExpandedRegion(.leading, priority: 2) {
                    LiveIslandLeadingRail(presentation: presentation)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.center, priority: 1) {
                    LiveIslandCenterLabel(presentation: presentation)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 2) {
                    LiveIslandTrailingRail(presentation: presentation)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.bottom, priority: 3) {
                    LiveIslandBottomPanel(presentation: presentation)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                }
            } compactLeading: {
                LiveCompactLeadingSurface(presentation: presentation)
            } compactTrailing: {
                LiveCompactTrailingSurface(presentation: presentation)
            } minimal: {
                LiveCompactGlyph(presentation: presentation, size: 22)
            }
            .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
        }
    }
}

// MARK: - 锁屏 / 横幅卡

private struct LiveActivityBannerView: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        LiveCardContent(presentation: presentation)
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

private struct LiveIslandPresentation {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var phase: String { state.phase }
    var detail: String { state.detail }
    var phaseStartedAt: Date? { state.phaseStartedAt }

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

    var statusText: String {
        if stage == .result {
            return state.success == false ? "未完成" : "已完成"
        }
        switch phase {
        case "starting": return "启动"
        case "listening": return "待命"
        case "recording": return "聆听"
        case "understanding", "processing", "searching": return "思考"
        case "executing": return "执行"
        case "summarizing", "speaking": return "回应"
        case "ended": return "结束"
        default: return "待命"
        }
    }

    var compactTitle: String {
        switch stage {
        case .voice: return "LIVE"
        case .thinking, .searching, .executing: return "AI"
        case .responding: return "答"
        case .result: return state.success == false ? "FAIL" : "DONE"
        case .ended: return "END"
        case .starting: return "LIVE"
        case .idle: return "LIVE"
        }
    }

    var compactStageText: String {
        if stage == .result {
            return state.success == false ? "!" : "✓"
        }
        switch stage {
        case .starting: return "启"
        case .voice: return phase == "recording" ? "听" : "待"
        case .thinking: return "想"
        case .searching: return "搜"
        case .executing: return "做"
        case .responding: return "答"
        case .ended: return "停"
        case .idle: return "待"
        case .result: return "✓"
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

    var iconName: String {
        if stage == .result {
            switch state.skillID {
            case "calendar": return "calendar"
            case "reminders": return "checklist"
            case "health": return "heart"
            case "web-search": return "magnifyingglass"
            default: return state.success == false ? "xmark" : "checkmark"
            }
        }
        switch stage {
        case .voice: return "waveform"
        case .thinking, .starting: return "ellipsis"
        case .searching: return "magnifyingglass"
        case .executing: return "bolt.horizontal.circle"
        case .responding: return phase == "speaking" ? "speaker.wave.2" : "text.alignleft"
        case .ended: return "mic.slash"
        case .idle: return "mic"
        case .result: return "checkmark"
        }
    }

    var progress: Double {
        if stage == .result { return 1.0 }
        switch phase {
        case "starting": return 0.08
        case "listening": return 0.18
        case "recording": return 0.3
        case "understanding", "processing": return 0.55
        case "searching", "executing": return 0.72
        case "summarizing": return 0.84
        case "speaking": return 0.92
        case "ended": return 1.0
        default: return 0.12
        }
    }

    var nextMilestone: Double {
        if stage == .result { return 1.0 }
        switch phase {
        case "starting", "listening": return 0.3
        case "recording": return 0.55
        case "understanding", "processing": return 0.72
        case "searching", "executing": return 0.84
        case "summarizing": return 0.92
        case "speaking": return 1.0
        default: return 0.3
        }
    }

    var phaseEstimate: TimeInterval {
        switch phase {
        case "starting": return 8
        case "listening": return 30
        case "recording": return 12
        case "understanding", "processing": return 12
        case "searching", "executing": return 50
        case "summarizing": return 35
        case "speaking": return 20
        default: return 20
        }
    }

    var isInFlight: Bool {
        switch stage {
        case .starting, .voice, .thinking, .searching, .executing, .responding:
            return true
        case .result, .ended, .idle:
            return false
        }
    }

    var usesVoiceWave: Bool { stage == .voice }
    var usesThinkingGlyph: Bool {
        stage == .starting || stage == .thinking || stage == .searching || stage == .executing || stage == .responding
    }
    var usesResultGlyph: Bool { stage == .result }
}

private struct LiveSignalDot: View {
    let presentation: LiveIslandPresentation
    var size: CGFloat = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: !presentation.isInFlight)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = presentation.isInFlight ? CGFloat((sin(t * 4.2) + 1.0) / 2.0) : 0.0
            Circle()
                .fill(presentation.accent.dot)
                .frame(width: size, height: size)
                .shadow(
                    color: presentation.accent.color.opacity(0.28 + pulse * 0.26),
                    radius: presentation.isInFlight ? 3 + pulse * 4 : 1
                )
        }
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

private struct LiveIslandBottomPanel: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                LiveSignalDot(presentation: presentation, size: 6)
                Text(presentation.moodText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LiveTheme.secondaryText)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Text("PhoneClaw")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(LiveTheme.tertiaryText)
                    .lineLimit(1)
            }

            Text(presentation.primaryLine)
                .font(.callout.weight(.medium))
                .foregroundStyle(LiveTheme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .id(presentation.primaryLine)
                .transition(.blurReplace)

            LivePipelineTrack(presentation: presentation, height: 3)
                .padding(.top, 2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
        .background(LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 17))
    }
}

private struct LiveIslandCenterLabel: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Text(presentation.moodText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(LiveTheme.secondaryText)
            .lineLimit(1)
            .contentTransition(.opacity)
            .frame(maxWidth: 82)
    }
}

private struct LiveIslandTrailingRail: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(spacing: 6) {
            Text(presentation.compactStageText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(presentation.accent.glyph)
                .frame(width: 16)
                .contentTransition(.opacity)

            LiveProgressRing(presentation: presentation, size: 17)
        }
        .frame(width: 48, height: 32, alignment: .trailing)
    }
}

private struct LiveIslandLeadingRail: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        LiveIslandSurroundingVisual(presentation: presentation)
            .frame(width: 68, height: 40, alignment: .leading)
    }
}

private struct LiveIslandSurroundingVisual: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        ZStack(alignment: .center) {
            LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 20)

            if presentation.accent.hasGlow {
                Circle()
                    .fill(presentation.accent.color.opacity(0.18))
                    .frame(width: 42, height: 42)
                    .blur(radius: 14)
            }

            if presentation.usesVoiceWave {
                LiveExpandedVoiceWave(presentation: presentation)
            } else if presentation.usesThinkingGlyph {
                LiveExpandedThinkingGlyph()
            } else if presentation.usesResultGlyph {
                LiveExpandedSkillGlyph(presentation: presentation)
            } else {
                Image(systemName: presentation.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(presentation.accent.glyph)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}

private struct LiveExpandedVoiceWave: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.10, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3.0) {
                ForEach(0..<6, id: \.self) { index in
                    let wave = (sin(t * 6.4 + Double(index) * 0.78) + 1.0) / 2.0
                    let height = 10.0 + wave * 22.0
                    Capsule()
                        .fill(presentation.accent.glyph.opacity(0.48 + wave * 0.42))
                        .frame(width: 3.2, height: height)
                        .shadow(color: presentation.accent.color.opacity(wave * 0.34), radius: 3)
                }
            }
            .frame(width: 48, height: 40)
        }
    }
}

private struct LiveExpandedThinkingGlyph: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 1)
                    .frame(width: 34, height: 34)

                ForEach(0..<3, id: \.self) { index in
                    let angle = t * 2.2 + Double(index) / 3.0 * 2.0 * Double.pi
                    let normalized = (sin(t * 2.6 + Double(index)) + 1.0) / 2.0
                    let intensity = 1.0 - normalized
                    Circle()
                        .fill(.white.opacity(0.42 + intensity * 0.42))
                        .frame(width: 4.8 + intensity * 2.8, height: 4.8 + intensity * 2.8)
                        .offset(
                            x: cos(angle) * 17.0,
                            y: sin(angle) * 17.0
                        )
                        .shadow(color: .white.opacity(intensity * 0.45), radius: 4)
                }
            }
            .frame(width: 46, height: 46)
        }
    }
}

private struct LiveExpandedSkillGlyph: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 4.8) + 1.0) / 2.0
            ZStack {
                Circle()
                    .stroke(presentation.accent.dot.opacity(0.18 + pulse * 0.26), lineWidth: 1.6)
                    .frame(width: 34 + pulse * 8, height: 34 + pulse * 8)
                    .blur(radius: pulse * 1.8)
                Image(systemName: presentation.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(presentation.accent.glyph)
                    .scaleEffect(0.96 + pulse * 0.08)
            }
            .frame(width: 48, height: 48)
        }
    }
}

/// 锁屏 / 横幅: 一个入口符号 + 一个状态词 + 一句主文案。
private struct LiveCardContent: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            LiveIconChip(presentation: presentation)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("PhoneClaw LIVE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LiveTheme.secondaryText)
                        .lineLimit(1)
                    LiveStatusTag(presentation: presentation)
                    Spacer(minLength: 0)
                }

                Text(presentation.primaryLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LiveTheme.primaryText)
                    .lineLimit(2)
                    .id(presentation.primaryLine)
                    .transition(.blurReplace)

                LivePipelineTrack(presentation: presentation)
            }
        }
        .padding(.horizontal, 1)
    }
}

/// 签名元素: 流水线进度轨 — 进行中白轨 + 琥珀轨头, 完成柔绿满轨, 失败柔红。
/// 阶段→比例 与 LiveBackgroundContinuation 的上报映射保持一致。
/// 两次推送之间靠 ProgressView(timerInterval:) 让轨头前方持续向下一里程碑爬行 —
/// 系统驱动、零更新推送, 任务再久画面也一直在动。
private struct LivePipelineTrack: View {
    let presentation: LiveIslandPresentation
    var height: CGFloat = 3

    private var trackFill: Color {
        switch presentation.accent {
        case .amber: return presentation.accent.color.opacity(0.72)
        case .green: return LiveAccent.green.color.opacity(0.74)
        case .red: return LiveAccent.red.color.opacity(0.74)
        case .dim: return .white.opacity(0.20)
        }
    }

    var body: some View {
        let progress = presentation.progress
        let inFlight = presentation.isInFlight
        GeometryReader { geo in
            let solidWidth = max(geo.size.width * progress, 5)
            let crawlWidth = max(geo.size.width * (presentation.nextMilestone - progress), 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(trackFill)
                        .frame(width: solidWidth)
                    if inFlight, crawlWidth > 1, let phaseStart = presentation.phaseStartedAt {
                        ProgressView(
                            timerInterval: phaseStart...phaseStart.addingTimeInterval(presentation.phaseEstimate),
                            countsDown: false,
                            label: { EmptyView() },
                            currentValueLabel: { EmptyView() }
                        )
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.30))
                        .frame(width: crawlWidth)
                    }
                }
                .frame(height: height)
                .clipShape(Capsule())
                if inFlight, progress < 1 {
                    Circle()
                        .fill(presentation.accent.color)
                        .frame(width: height + 1.6, height: height + 1.6)
                        .offset(x: max(solidWidth - height - 2, 0))
                }
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.6), value: progress)
    }
}

/// compact 态不是完整自由画布, 但这里会把系统给的 leading slot 用满:
/// 外圈 pulse 表示 LIVE 正在跑, 中间符号表示 voice / thinking / skill 阶段。
private struct LiveCompactLeadingSurface: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        ZStack {
            LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 15)

            HStack(spacing: 5) {
                ZStack {
                    LiveCompactHalo(presentation: presentation, diameter: 24)
                    LiveCompactGlyph(presentation: presentation, size: 18)
                }
                .frame(width: 24, height: 24)

                Text(presentation.compactTitle)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(presentation.accent.glyph)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 72, height: 30)
    }
}

/// compact trailing 负责持续进度: 不再只是一个 13pt 小环, 而是一枚短胶囊。
private struct LiveCompactTrailingSurface: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        ZStack {
            LiveAuroraCapsuleBackground(presentation: presentation, cornerRadius: 14)

            HStack(spacing: 6) {
                Text(presentation.compactStageText)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(presentation.accent.glyph)
                    .frame(width: 14, height: 20)
                    .contentTransition(.opacity)

                LiveProgressRing(presentation: presentation, size: 18)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 50, height: 28)
    }
}

private struct LiveCompactHalo: View {
    let presentation: LiveIslandPresentation
    let diameter: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.14, paused: !presentation.isInFlight)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = presentation.isInFlight ? CGFloat((sin(t * 4.8) + 1.0) / 2.0) : 0.0
            ZStack {
                Circle()
                    .fill(presentation.accent.chipFill)
                    .frame(width: diameter - 4, height: diameter - 4)

                Circle()
                    .fill(presentation.accent.color.opacity(0.14 + pulse * 0.10))
                    .frame(width: diameter + pulse * 7, height: diameter + pulse * 7)
                    .blur(radius: 4 + pulse * 2)

                Circle()
                    .stroke(presentation.accent.dot.opacity(0.26 + pulse * 0.30), lineWidth: 1.4)
                    .frame(width: diameter + pulse * 6, height: diameter + pulse * 6)
            }
        }
    }
}

/// compact 态的微型进度环 — 36px 高度下大形状才可读, 比呆点多一层"在走"的信息。
private struct LiveProgressRing: View {
    let presentation: LiveIslandPresentation
    var size: CGFloat = 13

    var body: some View {
        let progress = presentation.progress
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    presentation.accent.dot,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.6), value: progress)
    }
}

/// 灵动岛 compact/minimal 入口符号:
/// - listening/recording: 语音态, 保持 waveform 呼吸;
/// - understanding/searching/executing/summarizing: 思考/调用态, 类 Siri AI 小 spinner;
/// - skill/result: 结果态, 显示具体 Skill 图标。
private struct LiveCompactGlyph: View {
    let presentation: LiveIslandPresentation
    var size: CGFloat = 18

    var body: some View {
        Group {
            if presentation.usesVoiceWave {
                LiveVoiceIslandGlyph(presentation: presentation)
            } else if presentation.usesThinkingGlyph {
                LiveThinkingIslandGlyph()
            } else if presentation.usesResultGlyph {
                LiveSkillIslandGlyph(presentation: presentation)
            } else {
                LiveStaticIslandGlyph(presentation: presentation)
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(size / 18.0)
        .frame(width: size, height: size)
        .contentTransition(.symbolEffect(.replace))
    }
}

private struct LiveVoiceIslandGlyph: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.14, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(presentation.accent.color.opacity(0.18))
                    .frame(width: 19, height: 19)
                    .blur(radius: 3)

                HStack(alignment: .center, spacing: 1.6) {
                    ForEach(0..<5, id: \.self) { index in
                        let wave = (sin(t * 6.8 + Double(index) * 0.86) + 1.0) / 2.0
                        let height = 5.0 + wave * 8.0
                        Capsule()
                            .fill(presentation.accent.glyph.opacity(0.60 + wave * 0.34))
                            .frame(width: 2.1, height: height)
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
    }
}

private struct LiveThinkingIslandGlyph: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.10, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 20, height: 20)
                    .blur(radius: 4)

                ForEach(0..<4, id: \.self) { index in
                    let angle = t * 3.2 + Double(index) / 4.0 * 2.0 * Double.pi
                    let intensity = (sin(t * 3.4 + Double(index)) + 1.0) / 2.0
                    Circle()
                        .fill(.white.opacity(0.26 + intensity * 0.50))
                        .frame(width: 3.0 + intensity * 1.7, height: 3.0 + intensity * 1.7)
                        .offset(
                            x: cos(angle) * 6.2,
                            y: sin(angle) * 6.2
                        )
                        .shadow(color: .white.opacity(intensity * 0.42), radius: 2)
                }
            }
            .frame(width: 20, height: 20)
        }
    }
}

private struct LiveSkillIslandGlyph: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 5.5) + 1.0) / 2.0
            ZStack {
                Circle()
                    .stroke(presentation.accent.dot.opacity(0.30 + pulse * 0.35), lineWidth: 1.4)
                    .frame(width: 15 + pulse * 4, height: 15 + pulse * 4)
                    .blur(radius: pulse * 1.5)

                Image(systemName: presentation.iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(presentation.accent.glyph)
                    .scaleEffect(0.92 + pulse * 0.12)
            }
            .frame(width: 20, height: 20)
        }
    }
}

private struct LiveStaticIslandGlyph: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        Image(systemName: presentation.iconName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(presentation.accent.glyph)
            .symbolEffect(
                .variableColor.iterative,
                options: .repeating,
                isActive: presentation.isInFlight
            )
    }
}

/// 圆角方块 icon chip — 跟 app 内 Skill 卡同款 (26~28pt, tint 0.16)。
private struct LiveIconChip: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        let accent = presentation.accent
        ZStack {
            if accent.hasGlow {
                Circle()
                    .fill(accent.color.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .blur(radius: 8)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.chipFill)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(LiveTheme.line, lineWidth: 1)
                )
            Image(systemName: presentation.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.glyph)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: presentation.isInFlight
                )
        }
        .frame(width: 30, height: 30)
    }
}

/// 状态点 + 低对比文字。
private struct LiveStatusTag: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(spacing: 4) {
            LiveSignalDot(presentation: presentation)
            Text(presentation.statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LiveTheme.tertiaryText)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
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
