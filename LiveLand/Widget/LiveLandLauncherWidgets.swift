import AppIntents
import SwiftUI
import UIKit
import WidgetKit

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
    // launcherFill 内的 Color.black 是贪婪视图，确保 body 占满整块（绝不出现"空 body→系统灰占位"）。
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
