import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 设计语言
//
// 参考 Flighty (ADA 2023) / Citymapper / Swiggy 的灵动岛复盘 + Apple 官方设计专文:
//   · 签名元素 = 流水线进度轨 (收音→理解→检索→总结→完成), 对位 Flighty 的航线进度条;
//     进度比例镜像 LiveBackgroundContinuation 的 55/72/84 阶段映射, 跨表面一致
//   · 关键信息 front and center — 结果文案是主角 (subheadline 0.95), 标签才是配角
//   · 品牌琥珀只出现一次 — 进行中的轨头/活跃点; 完成柔绿, 失败柔红, 其余白系分层
//   · compact 态用大形状: 符号 + 微型进度环 (Swiggy: 过细的图形在 36px 高度不可读)
//   · 展开态使用 leading/center/trailing + bottom, 把语音/思考动效做成主视觉;
//     锁屏横幅继续使用紧凑 LiveCardContent, 灵动岛展开态使用更高的 LIVE 面板
//   · 流程只在 LiveIslandPresentation 里归一: phase string → stage/accent/progress/icon/status;
//     compact / expanded / banner 都读同一个呈现模型, 避免各个 View 自己猜状态
//   · 动效只靠状态切换 transition: symbol replace / blurReplace / 进度弹簧

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

struct PhoneClawLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneClawLiveActivityAttributes.self) { context in
            LiveActivityBannerView(presentation: LiveIslandPresentation(state: context.state))
                .activityBackgroundTint(Color(red: 0.07, green: 0.06, blue: 0.10))
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
    var startedAt: Date? { state.startedAt }
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

    var title: String {
        if let skillName = state.skillName, !skillName.isEmpty {
            return skillName
        }
        return "LIVE"
    }

    var statusText: String {
        if stage == .result {
            return state.success == false ? "未完成" : "已完成"
        }
        switch phase {
        case "starting": return "启动中"
        case "listening": return "待命聆听"
        case "recording": return "聆听中"
        case "understanding", "processing": return "理解中"
        case "searching": return "搜索中"
        case "executing": return "调用 Skill"
        case "summarizing": return "整理中"
        case "speaking": return "回答中"
        case "ended": return "已结束"
        default: return "待命"
        }
    }

    var islandCaption: String {
        switch stage {
        case .voice: return "VOICE"
        case .thinking, .searching, .executing: return "THINK"
        case .responding: return "ANSWER"
        case .result: return state.success == false ? "FAILED" : "DONE"
        case .ended: return "ENDED"
        case .starting: return "START"
        case .idle: return "LIVE"
        }
    }

    var accent: LiveAccent {
        if stage == .result {
            return state.success == false ? .red : .green
        }
        switch stage {
        case .voice: return .amber
        case .thinking, .searching, .executing, .responding, .starting: return .neutral
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

private struct LiveIslandBottomPanel: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(presentation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .contentTransition(.opacity)

                Spacer(minLength: 0)

                Text(presentation.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(presentation.accent.glyph.opacity(0.86))
                    .lineLimit(1)
            }

            Text(presentation.detail)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .id(presentation.detail)
                .transition(.blurReplace)

            LivePipelineTrack(presentation: presentation, height: 5)

            LiveExpandedMilestones(presentation: presentation)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

private struct LiveIslandCenterLabel: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        VStack(spacing: 1) {
            Text("PhoneClaw LIVE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            Text(presentation.islandCaption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .frame(maxWidth: 104)
    }
}

private struct LiveIslandTrailingRail: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(spacing: 7) {
            LiveProgressRing(presentation: presentation)
                .frame(width: 16, height: 16)

            if presentation.isInFlight, let started = presentation.startedAt {
                Text(
                    timerInterval: started...started.addingTimeInterval(3600),
                    countsDown: false,
                    showsHours: false
                )
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .frame(width: 38, alignment: .leading)
            } else {
                Image(systemName: presentation.iconName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(presentation.accent.glyph)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 72, height: 32, alignment: .trailing)
    }
}

private struct LiveIslandLeadingRail: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        LiveIslandSurroundingVisual(presentation: presentation)
            .frame(width: 78, height: 42, alignment: .leading)
    }
}

private struct LiveIslandSurroundingVisual: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        ZStack(alignment: .center) {
            Capsule()
                .fill(.white.opacity(0.065))
                .overlay(
                    Capsule()
                        .stroke(presentation.accent.dot.opacity(0.22), lineWidth: 1)
                )

            if presentation.accent.hasGlow {
                Circle()
                    .fill(presentation.accent.color.opacity(0.28))
                    .frame(width: 50, height: 50)
                    .blur(radius: 12)
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
            HStack(alignment: .center, spacing: 2.4) {
                ForEach(0..<9, id: \.self) { index in
                    let wave = (sin(t * 7.6 + Double(index) * 0.62) + 1.0) / 2.0
                    let height = 11.0 + wave * 30.0
                    Capsule()
                        .fill(presentation.accent.glyph.opacity(0.54 + wave * 0.46))
                        .frame(width: 3.6, height: height)
                        .shadow(color: presentation.accent.color.opacity(wave * 0.42), radius: 3)
                }
            }
            .frame(width: 60, height: 46)
        }
    }
}

private struct LiveExpandedThinkingGlyph: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<12, id: \.self) { index in
                    let angle = Double(index) / 12.0 * 2.0 * Double.pi
                    let phase = (t * 10.0 - Double(index)).truncatingRemainder(dividingBy: 12.0)
                    let normalized = (phase + 12.0).truncatingRemainder(dividingBy: 12.0) / 12.0
                    let intensity = 1.0 - normalized
                    Circle()
                        .fill(.white.opacity(0.20 + intensity * 0.80))
                        .frame(width: 4.6 + intensity * 4.4, height: 4.6 + intensity * 4.4)
                        .offset(
                            x: cos(angle) * 18.0,
                            y: sin(angle) * 18.0
                        )
                        .shadow(color: .white.opacity(intensity * 0.65), radius: 4)
                }
            }
            .rotationEffect(.degrees(t * 150.0))
            .frame(width: 50, height: 50)
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
                    .stroke(presentation.accent.dot.opacity(0.30 + pulse * 0.42), lineWidth: 2)
                    .frame(width: 38 + pulse * 10, height: 38 + pulse * 10)
                    .blur(radius: pulse * 2.2)
                Image(systemName: presentation.iconName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(presentation.accent.glyph)
                    .scaleEffect(0.94 + pulse * 0.12)
            }
            .frame(width: 54, height: 54)
        }
    }
}

private struct LiveExpandedMilestones: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(spacing: 6) {
            milestone("听", active: presentation.progress >= 0.18)
            milestone("想", active: presentation.progress >= 0.55)
            milestone("做", active: presentation.progress >= 0.72)
            milestone("答", active: presentation.progress >= 0.84)
        }
    }

    private func milestone(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(active ? .white.opacity(0.78) : .white.opacity(0.28))
            .frame(width: 18, height: 16)
            .background(
                Capsule()
                    .fill(active ? .white.opacity(0.13) : .white.opacity(0.055))
            )
    }
}

/// 锁屏 / 横幅的紧凑结果卡: chip + 标题·状态行 + 正文。
private struct LiveCardContent: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LiveIconChip(presentation: presentation)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    Spacer(minLength: 0)

                    LiveStatusTag(presentation: presentation)
                }

                // 结果/进展文案是这张卡的主角 — 最亮、最大的一行。
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .id(presentation.detail)
                    .transition(.blurReplace)

                LivePipelineTrack(presentation: presentation)
                    .padding(.top, 3)
            }
        }
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
        case .amber, .neutral: return .white.opacity(0.42)
        case .green: return LiveAccent.green.color.opacity(0.8)
        case .red: return LiveAccent.red.color.opacity(0.8)
        case .dim: return .white.opacity(0.22)
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
                    .fill(.white.opacity(0.14))
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
                        .fill(Color.orange)
                        .frame(width: height + 2, height: height + 2)
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
            LiveCompactHalo(presentation: presentation, diameter: 31)
            LiveCompactGlyph(presentation: presentation, size: 24)
        }
        .frame(width: 34, height: 32)
    }
}

/// compact trailing 负责持续进度: 不再只是一个 13pt 小环, 而是一枚短胶囊。
private struct LiveCompactTrailingSurface: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.065))
                .overlay(
                    Capsule()
                        .stroke(presentation.accent.dot.opacity(presentation.isInFlight ? 0.34 : 0.18), lineWidth: 1)
                )

            HStack(spacing: 4) {
                LiveCompactStatusPulse(presentation: presentation)
                LiveProgressRing(presentation: presentation, size: 18)
            }
        }
        .frame(width: 42, height: 28)
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

private struct LiveCompactStatusPulse: View {
    let presentation: LiveIslandPresentation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16, paused: !presentation.isInFlight)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = presentation.isInFlight ? CGFloat((sin(t * 5.2) + 1.0) / 2.0) : 0.0
            ZStack {
                Circle()
                    .fill(presentation.accent.dot.opacity(0.18 + pulse * 0.22))
                    .frame(width: 10 + pulse * 4, height: 10 + pulse * 4)
                Circle()
                    .fill(presentation.accent.dot)
                    .frame(width: 5.5, height: 5.5)
            }
            .frame(width: 13, height: 18)
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
        TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(presentation.accent.color.opacity(0.24))
                    .frame(width: 19, height: 19)
                    .blur(radius: 3)

                HStack(alignment: .center, spacing: 1.6) {
                    ForEach(0..<5, id: \.self) { index in
                        let wave = (sin(t * 8.0 + Double(index) * 0.85) + 1.0) / 2.0
                        let height = 5.0 + wave * 9.0
                        Capsule()
                            .fill(presentation.accent.glyph.opacity(0.68 + wave * 0.32))
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
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 20, height: 20)
                    .blur(radius: 4)

                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) / 8.0 * 2.0 * Double.pi
                    let phase = (t * 9.0 - Double(index)).truncatingRemainder(dividingBy: 8.0)
                    let normalized = (phase + 8.0).truncatingRemainder(dividingBy: 8.0) / 8.0
                    let intensity = 1.0 - normalized
                    Circle()
                        .fill(.white.opacity(0.24 + intensity * 0.76))
                        .frame(width: 3.2 + intensity * 2.1, height: 3.2 + intensity * 2.1)
                        .offset(
                            x: cos(angle) * 6.4,
                            y: sin(angle) * 6.4
                        )
                        .shadow(color: .white.opacity(intensity * 0.65), radius: 2.4)
                }
            }
            .rotationEffect(.degrees(t * 160.0))
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
                    .fill(accent.color.opacity(0.22))
                    .frame(width: 30, height: 30)
                    .blur(radius: 7)
            }
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.chipFill)
                .frame(width: 28, height: 28)
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
            Circle()
                .fill(presentation.accent.dot)
                .frame(width: 5, height: 5)
            Text(presentation.statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .contentTransition(.opacity)
            // 执行中实时走秒 — 系统驱动的滚动计时, 不静止的"还在干活"凭证。
            if presentation.isInFlight, let started = presentation.startedAt {
                Text(
                    timerInterval: started...started.addingTimeInterval(3600),
                    countsDown: false,
                    showsHours: false
                )
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
                .frame(maxWidth: 44, alignment: .leading)
            }
        }
    }
}

// MARK: - 状态映射

/// 强调色档位 — 琥珀只给"收音中", 结果只用柔和绿/红, 其余白系。
private enum LiveAccent {
    case amber
    case green
    case red
    case neutral
    case dim

    var color: Color {
        switch self {
        case .amber: return .orange
        case .green: return Color(red: 0.42, green: 0.78, blue: 0.55)
        case .red: return Color(red: 0.93, green: 0.46, blue: 0.42)
        case .neutral: return .white
        case .dim: return .white
        }
    }

    var glyph: Color {
        switch self {
        case .neutral, .dim: return .white.opacity(0.78)
        default: return color
        }
    }

    var chipFill: Color {
        switch self {
        case .neutral, .dim: return .white.opacity(0.10)
        default: return color.opacity(0.16)
        }
    }

    var dot: Color {
        switch self {
        case .amber, .green, .red: return color
        case .neutral: return .white.opacity(0.45)
        case .dim: return .white.opacity(0.25)
        }
    }

    /// 有彩度的状态才点光晕 — 白系阶段保持纯平, 光只属于"活着/有结果"。
    var hasGlow: Bool {
        switch self {
        case .amber, .green, .red: return true
        case .neutral, .dim: return false
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
