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
//   · 展开态 bottom 单区整卡 (≤144pt), 与锁屏横幅同构 (同一个 LiveCardContent)
//   · 动效只靠状态切换 transition: symbol replace / blurReplace / 进度弹簧

@main
struct PhoneClawLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        PhoneClawLiveActivityWidget()
        PhoneClawLiveLauncherWidget()
    }
}

struct PhoneClawLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneClawLiveActivityAttributes.self) { context in
            LiveActivityBannerView(state: context.state)
                .activityBackgroundTint(Color(red: 0.07, green: 0.06, blue: 0.10))
                .activitySystemActionForegroundColor(.orange)
                .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态只用 bottom 单区 — leading/trailing 角落式布局会把内容打散在
                // 相机带两侧、中间留一块死黑; 整张卡收在相机带下方才是一体的。
                DynamicIslandExpandedRegion(.bottom) {
                    LiveCardContent(state: context.state)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
            } compactLeading: {
                Image(systemName: liveIconName(for: context.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liveAccent(for: context.state).glyph)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: liveIsInFlight(context.state)
                    )
            } compactTrailing: {
                LiveProgressRing(state: context.state)
            } minimal: {
                Image(systemName: liveIconName(for: context.state))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(liveAccent(for: context.state).glyph)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: liveIsInFlight(context.state)
                    )
            }
            .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
        }
    }
}

// MARK: - 锁屏 / 横幅卡

private struct LiveActivityBannerView: View {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var body: some View {
        LiveCardContent(state: state)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
    }
}

// MARK: - 共享小件

/// 整张结果卡 — 横幅和展开岛共用同一套解剖: chip + 标题·状态行 + 正文。
private struct LiveCardContent: View {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LiveIconChip(state: state)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(liveTitle(for: state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    Spacer(minLength: 0)

                    LiveStatusTag(state: state)
                }

                // 结果/进展文案是这张卡的主角 — 最亮、最大的一行。
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .id(state.detail)
                    .transition(.blurReplace)

                LivePipelineTrack(state: state)
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
    let state: PhoneClawLiveActivityAttributes.ContentState

    private var trackFill: Color {
        switch liveAccent(for: state) {
        case .amber, .neutral: return .white.opacity(0.42)
        case .green: return LiveAccent.green.color.opacity(0.8)
        case .red: return LiveAccent.red.color.opacity(0.8)
        case .dim: return .white.opacity(0.22)
        }
    }

    var body: some View {
        let progress = liveProgress(for: state)
        let inFlight = liveIsInFlight(state)
        GeometryReader { geo in
            let solidWidth = max(geo.size.width * progress, 5)
            let crawlWidth = max(geo.size.width * (liveNextMilestone(for: state) - progress), 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(trackFill)
                        .frame(width: solidWidth)
                    if inFlight, crawlWidth > 1, let phaseStart = state.phaseStartedAt {
                        ProgressView(
                            timerInterval: phaseStart...phaseStart.addingTimeInterval(livePhaseEstimate(for: state)),
                            countsDown: false,
                            label: { EmptyView() },
                            currentValueLabel: { EmptyView() }
                        )
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.30))
                        .frame(width: crawlWidth)
                    }
                }
                .frame(height: 3)
                .clipShape(Capsule())
                if inFlight, progress < 1 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .offset(x: max(solidWidth - 5, 0))
                }
            }
        }
        .frame(height: 3)
        .animation(.spring(duration: 0.6), value: progress)
    }
}

/// compact 态的微型进度环 — 36px 高度下大形状才可读, 比呆点多一层"在走"的信息。
private struct LiveProgressRing: View {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var body: some View {
        let progress = liveProgress(for: state)
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    liveAccent(for: state).dot,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .animation(.spring(duration: 0.6), value: progress)
    }
}

/// 圆角方块 icon chip — 跟 app 内 Skill 卡同款 (26~28pt, tint 0.16)。
private struct LiveIconChip: View {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var body: some View {
        let accent = liveAccent(for: state)
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
            Image(systemName: liveIconName(for: state))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.glyph)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: liveIsInFlight(state)
                )
        }
        .frame(width: 30, height: 30)
    }
}

/// 状态点 + 低对比文字。
private struct LiveStatusTag: View {
    let state: PhoneClawLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(liveAccent(for: state).dot)
                .frame(width: 5, height: 5)
            Text(liveStatusText(for: state))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .contentTransition(.opacity)
            // 执行中实时走秒 — 系统驱动的滚动计时, 不静止的"还在干活"凭证。
            if liveIsInFlight(state), let started = state.startedAt {
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

private func liveAccent(for state: PhoneClawLiveActivityAttributes.ContentState) -> LiveAccent {
    if state.phase == "skill" {
        return state.success == false ? .red : .green
    }
    switch state.phase {
    case "recording": return .amber
    case "understanding", "processing", "searching", "summarizing", "executing", "speaking": return .neutral
    case "ended": return .dim
    default: return .dim
    }
}

private func liveIconName(for state: PhoneClawLiveActivityAttributes.ContentState) -> String {
    if state.phase == "skill" {
        switch state.skillID {
        case "calendar": return "calendar"
        case "reminders": return "checklist"
        case "health": return "heart"
        case "web-search": return "magnifyingglass"
        default: return state.success == false ? "xmark" : "checkmark"
        }
    }
    switch state.phase {
    case "recording": return "waveform"
    case "understanding", "processing": return "ellipsis"
    case "searching": return "magnifyingglass"
    case "summarizing": return "text.alignleft"
    case "executing": return "bolt.horizontal.circle"
    case "speaking": return "speaker.wave.2"
    case "ended": return "mic.slash"
    default: return "mic"
    }
}

/// 阶段→进度比例 — 中段三档 (0.55/0.72/0.84) 与 LiveBackgroundContinuation
/// 上报系统的进度百分比同源, 两个表面讲同一个故事。
private func liveProgress(for state: PhoneClawLiveActivityAttributes.ContentState) -> Double {
    if state.phase == "skill" { return 1.0 }
    switch state.phase {
    case "recording": return 0.3
    case "understanding", "processing": return 0.55
    case "searching", "executing": return 0.72
    case "summarizing": return 0.84
    case "speaking": return 0.92
    case "ended": return 1.0
    default: return 0.12
    }
}

/// 执行中 = 持续动效开 (流光/走秒/爬行); 结果与待机态静止。
private func liveIsInFlight(_ state: PhoneClawLiveActivityAttributes.ContentState) -> Bool {
    switch liveAccent(for: state) {
    case .amber, .neutral: return true
    case .green, .red, .dim: return false
    }
}

/// 当前阶段的爬行目标 — 下一个里程碑比例。
private func liveNextMilestone(for state: PhoneClawLiveActivityAttributes.ContentState) -> Double {
    if state.phase == "skill" { return 1.0 }
    switch state.phase {
    case "recording": return 0.55
    case "understanding", "processing": return 0.72
    case "searching", "executing": return 0.84
    case "summarizing": return 0.92
    case "speaking": return 1.0
    default: return 0.3
    }
}

/// 阶段时长的展示预估 (秒) — 只决定爬行速度, 跑满即停在下一档前, 不影响真实进度。
private func livePhaseEstimate(for state: PhoneClawLiveActivityAttributes.ContentState) -> TimeInterval {
    switch state.phase {
    case "recording": return 12
    case "understanding", "processing": return 12
    case "searching", "executing": return 50
    case "summarizing": return 35
    case "speaking": return 20
    default: return 20
    }
}

private func liveTitle(for state: PhoneClawLiveActivityAttributes.ContentState) -> String {
    if let skillName = state.skillName, !skillName.isEmpty {
        return skillName
    }
    return "LIVE"
}

private func liveStatusText(for state: PhoneClawLiveActivityAttributes.ContentState) -> String {
    if state.phase == "skill" {
        return state.success == false ? "未完成" : "已完成"
    }
    switch state.phase {
    case "recording": return "聆听中"
    case "understanding", "processing": return "理解中"
    case "searching": return "搜索中"
    case "summarizing": return "总结中"
    case "executing": return "执行中"
    case "speaking": return "回答中"
    case "ended": return "已结束"
    default: return "待命"
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
                .widgetURL(URL(string: "phoneclaw://live?mode=voice"))
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
