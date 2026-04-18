import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - 音频 UI 组件

struct AudioAttachmentBubble: View {
    let attachment: ChatAudioAttachment
    @StateObject private var player = AudioAttachmentPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("语音消息", systemImage: "waveform.badge.mic")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 8)

                Text(attachment.formattedDuration)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.bg.opacity(0.35), in: Capsule())
            }

            HStack(spacing: 12) {
                AudioPlaybackActionButton(
                    isPlaying: player.isPlaying,
                    action: { player.togglePlayback(data: attachment.wavData) }
                )

                VStack(alignment: .leading, spacing: 6) {
                    AudioWaveformView(
                        levels: attachment.waveform,
                        progress: player.progress,
                        isPlaying: player.isPlaying,
                        activeColor: Theme.accent,
                        inactiveColor: Theme.textTertiary.opacity(0.45),
                        barWidth: 4,
                        minHeight: 8,
                        maxExtraHeight: 18
                    )
                    .frame(height: 30)

                    HStack(spacing: 8) {
                        Text(player.isPlaying ? "播放中" : "点击播放")
                            .font(.system(size: 11))
                            .foregroundStyle(player.isPlaying ? Theme.accent : Theme.textSecondary)

                        Spacer(minLength: 8)

                        Text(player.secondaryStatusText(totalDuration: attachment.duration))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .frame(minWidth: 230, maxWidth: 272, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Theme.bgElevated, Theme.bgHover.opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
    }
}

struct AudioWaveformView: View {
    let levels: [Float]
    var progress: Double = 0
    var isPlaying: Bool = false
    var activeColor: Color = Theme.accent
    var inactiveColor: Color = Theme.textTertiary
    var barWidth: CGFloat = 3
    var minHeight: CGFloat = 6
    var maxExtraHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let threshold = Double(index + 1) / Double(max(levels.count, 1))
                let isActive = progress > 0 ? threshold <= progress : isPlaying
                Capsule()
                    .fill(isActive ? activeColor : inactiveColor)
                    .frame(
                        width: barWidth,
                        height: minHeight + CGFloat(level) * maxExtraHeight
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: progress)
        .animation(.easeInOut(duration: 0.18), value: isPlaying)
    }
}

// MARK: - AudioAttachmentPlayer

@MainActor
final class AudioAttachmentPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedClipSignature: Int?
    private let audioSession = AVAudioSession.sharedInstance()

    func togglePlayback(data: Data) {
        if isPlaying {
            pause()
        } else if loadedClipSignature == data.hashValue, player != nil {
            resume()
        } else {
            play(data: data)
        }
    }

    func stop() {
        invalidateTimer()
        player?.stop()
        player = nil
        loadedClipSignature = nil
        isPlaying = false
        progress = 0
        currentTime = 0
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        invalidateTimer()
        self.player = nil
        loadedClipSignature = nil
        isPlaying = false
        progress = 0
        currentTime = 0
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func secondaryStatusText(totalDuration: TimeInterval) -> String {
        guard totalDuration > 0 else { return "--:--" }
        if isPlaying || currentTime > 0 {
            return "\(formatTime(currentTime)) / \(formatTime(totalDuration))"
        }
        return formatTime(totalDuration)
    }

    private func pause() {
        player?.pause()
        invalidateTimer()
        isPlaying = false
        syncProgress()
    }

    private func resume() {
        guard let player else { return }
        guard player.play() else { return }
        isPlaying = true
        startProgressUpdates()
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startProgressUpdates() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncProgress()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func syncProgress() {
        guard let player else {
            progress = 0
            currentTime = 0
            return
        }
        currentTime = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func play(data: Data) {
        stop()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            if !player.play() {
                print("[AudioUI] playback failed: AVAudioPlayer returned false")
                isPlaying = false
                return
            }
            self.player = player
            loadedClipSignature = data.hashValue
            isPlaying = true
            progress = 0
            currentTime = 0
            startProgressUpdates()
        } catch {
            print("[AudioUI] playback failed: \(error.localizedDescription)")
            isPlaying = false
        }
    }
}

// MARK: - Playback Action Button

struct AudioPlaybackActionButton: View {
    let isPlaying: Bool
    var symbolName: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName ?? (isPlaying ? "pause.fill" : "play.fill"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recording Status Card

struct RecordingStatusCard: View {
    let duration: TimeInterval
    let sampleRate: Double
    let peakLevel: Float
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red.opacity(0.92))
                        .frame(width: 8, height: 8)
                    Text("录音中")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer(minLength: 8)

                audioMetaChip(text: formattedDuration, emphasized: true)
                audioMetaChip(text: sampleRateText)
            }

            HStack(spacing: 12) {
                AudioPlaybackActionButton(
                    isPlaying: false,
                    symbolName: "stop.fill",
                    action: onStop
                )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.red.opacity(0.25), lineWidth: 8)
                            .scaleEffect(1.08)
                    )

                VStack(alignment: .leading, spacing: 8) {
                    RecordingLevelBars(level: peakLevel)
                        .frame(height: 28)

                    Text("点左侧按钮结束录音，发送时会作为音频附件一并发出。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                Button(action: onDiscard) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.bg.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Theme.bgElevated, Theme.bgHover.opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var formattedDuration: String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var sampleRateText: String {
        String(format: "%.0f kHz", max(sampleRate, 16_000) / 1000)
    }
}

// MARK: - Composer Audio Draft Card

struct ComposerAudioDraftCard: View {
    let attachment: ChatAudioAttachment
    let onDiscard: () -> Void

    @StateObject private var player = AudioAttachmentPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("语音草稿", systemImage: "paperplane.circle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 8)

                audioMetaChip(text: attachment.formattedDuration, emphasized: true)

                Button(action: onDiscard) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.bg.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                AudioPlaybackActionButton(
                    isPlaying: player.isPlaying,
                    action: { player.togglePlayback(data: attachment.wavData) }
                )

                VStack(alignment: .leading, spacing: 8) {
                    AudioWaveformView(
                        levels: attachment.waveform,
                        progress: player.progress,
                        isPlaying: player.isPlaying,
                        activeColor: Theme.accent,
                        inactiveColor: Theme.textTertiary.opacity(0.45),
                        barWidth: 4,
                        minHeight: 8,
                        maxExtraHeight: 18
                    )
                    .frame(height: 30)

                    HStack(spacing: 8) {
                        Text(player.isPlaying ? "预览播放中" : "可直接发送，也可以先试听")
                            .font(.system(size: 11))
                            .foregroundStyle(player.isPlaying ? Theme.accent : Theme.textSecondary)

                        Spacer(minLength: 8)

                        audioMetaChip(text: String(format: "%.0f kHz", attachment.sampleRate / 1000))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Theme.accentSubtle, Theme.bgElevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Audio Error Banner

struct AudioErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Theme.bg.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Recording Level Bars

struct RecordingLevelBars: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                let seed = abs(sin(Double(index) * 0.55))
                let intensity = max(displayLevel, 0.08)
                Capsule()
                    .fill(index < highlightedBarCount ? Theme.accent : Theme.textTertiary.opacity(0.35))
                    .frame(width: 4, height: 8 + CGFloat(seed) * (8 + intensity * 26))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.12), value: highlightedBarCount)
        .animation(.easeInOut(duration: 0.12), value: displayLevel)
    }

    /// sqrt 感知映射: 归一化浮点麦克风峰值正常只到 0.02-0.3, 线性塞进 0-1
    /// bar 高度几乎看不出变化. sqrt 把低幅拉上去: 0.03→0.17, 0.1→0.32, 0.3→0.55.
    private var displayLevel: CGFloat {
        let clamped = min(max(CGFloat(level), 0), 1)
        return clamped.squareRoot()
    }

    private var highlightedBarCount: Int {
        max(2, Int((displayLevel * 24).rounded(.up)))
    }
}

// MARK: - Audio Meta Chip

@ViewBuilder
func audioMetaChip(text: String, emphasized: Bool = false) -> some View {
    Text(text)
        .font(.system(size: 11, weight: emphasized ? .semibold : .medium, design: .monospaced))
        .foregroundStyle(emphasized ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            emphasized ? Theme.bg.opacity(0.42) : Theme.bg.opacity(0.3),
            in: Capsule()
        )
}
