import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

private func localizedThinkingText(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.contains { $0.hasPrefix("zh") } ? zh : en
}

// MARK: - 主入口

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = AgentEngine()
    @State private var audioCapture = AudioCaptureService()
    @State private var inputText = ""
    @State private var selectedImages: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showConfigurations = false
    @State private var showSkillsManager = false
    /// 记录每个 skill 卡片的展开状态（key = SkillCard.id）
    @State private var expandedSkills: Set<UUID> = []
    /// 记录每个 THINK 卡片的展开状态（key = ResponseBlock.id）
    @State private var expandedThoughts: Set<UUID> = []
    @FocusState private var isInputFocused: Bool

    private var displayItems: [DisplayItem] {
        buildDisplayItems(from: engine.messages, isProcessing: engine.isProcessing)
    }

    private var scrollAnchorState: String {
        guard let last = displayItems.last else {
            return "empty:\(engine.isProcessing)"
        }

        switch last {
        case .user(let msg):
            return [
                "user",
                msg.id.uuidString,
                String(msg.content.count),
                String(msg.images.count),
                String(msg.audios.count)
            ].joined(separator: ":")
        case .response(let block):
            let skillSignature = block.skills.map {
                [
                    $0.id.uuidString,
                    $0.skillName,
                    $0.skillStatus ?? "",
                    $0.toolName ?? ""
                ].joined(separator: "|")
            }.joined(separator: "||")

            return [
                "response",
                block.id.uuidString,
                block.thinkingText ?? "",
                block.responseText ?? "",
                block.isThinking ? "1" : "0",
                skillSignature
            ].joined(separator: ":")
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if engine.messages.isEmpty {
                    welcomeView
                } else {
                    chatList
                }

                composerAttachmentsPanel

                if engine.messages.isEmpty {
                    skillChips.padding(.bottom, 8)
                }

                inputBar
            }
        }
        .preferredColorScheme(.dark)
        .task { engine.setup() }
        .task(id: selectedPhotoItem) {
            await loadSelectedPhoto()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                audioCapture.refreshPermissionStatus()
                return
            }
            engine.cancelActiveGeneration()
            _ = audioCapture.stopCapture()
        }
        .sheet(isPresented: $showConfigurations) {
            ConfigurationsView(engine: engine)
        }
        .sheet(isPresented: $showSkillsManager) {
            SkillsManagerView(engine: engine)
        }
    }

    // MARK: - 聊天列表

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.chatSpacing) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .user(let msg):
                            UserBubble(
                                text: msg.content,
                                images: msg.images.compactMap(\.uiImage),
                                audios: msg.audios
                            )
                        case .response(let block):
                            AIResponseView(
                                block: block,
                                expandedSkills: expandedSkills,
                                isThinkingExpanded: expandedThoughts.contains(block.id),
                                onToggle: { toggleExpand($0) },
                                onToggleThinking: { toggleThinking(block.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.chatPadH)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollTo(proxy, animated: false) }
            .onChange(of: engine.messages.count) { scrollTo(proxy) }
            .onChange(of: engine.isProcessing) { scrollTo(proxy) }
            .onChange(of: scrollAnchorState) { scrollTo(proxy) }
        }
    }

    private func scrollTo(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = displayItems.last else { return }
        let lastID = last.id
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func toggleExpand(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if expandedSkills.contains(id) {
                expandedSkills.remove(id)
            } else {
                expandedSkills.insert(id)
            }
        }
    }

    private func toggleThinking(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if expandedThoughts.contains(id) {
                expandedThoughts.remove(id)
            } else {
                expandedThoughts.insert(id)
            }
        }
    }

    private func toggleThinkingMode() {
        engine.config.enableThinking.toggle()
        engine.applySamplingConfig()
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 0) {
            // 左：新会话
            Button(action: { engine.clearMessages() }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            Spacer()

            // 中：模型状态
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.llm.isLoaded ? Theme.accentGreen : Theme.accent)
                    .frame(width: 6, height: 6)
                Text(engine.llm.isLoaded ? engine.llm.modelDisplayName : engine.llm.statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // 右：Skills + 设置
            HStack(spacing: 6) {
                Button(action: toggleThinkingMode) {
                    HStack(spacing: 6) {
                        Image(systemName: engine.config.enableThinking ? "sparkles" : "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text(localizedThinkingText("思考", "Think"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(engine.config.enableThinking ? Theme.bg : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        engine.config.enableThinking ? Theme.accent : Theme.bgElevated,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)

                Button(action: { showSkillsManager = true }) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                Button(action: { showConfigurations = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
    }

    // MARK: - 欢迎页

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accentSubtle).frame(width: 60, height: 60)
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Text("PhoneClaw")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 16)
            Text("On-device AI Agent")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Skill 快捷标签

    private var skillChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(engine.enabledSkillInfos, id: \.name) { skill in
                    Button {
                        inputText = skill.samplePrompt
                        Task { await send() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: skill.icon).font(.system(size: 11))
                            Text(skill.displayName).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.chatPadH)
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                #if canImport(PhotosUI)
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                #endif

                Button {
                    Task {
                        _ = await audioCapture.toggleCapture()
                    }
                } label: {
                    Image(systemName: audioCapture.isCapturing ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(audioCapture.isCapturing ? Theme.bg : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(
                            audioCapture.isCapturing ? Theme.accent : Theme.bgElevated,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)

            #if os(macOS)
            TextField("Message…", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border, lineWidth: 1))
                .onSubmit { Task { await send() } }
            #else
            TextField("Message…", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.border, lineWidth: 1))
                .focused($isInputFocused)
                .onSubmit { Task { await send() } }
            #endif

            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSend ? Theme.bg : Theme.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Theme.accent : Theme.bgElevated, in: Circle())
                    .overlay(Circle().strokeBorder(canSend ? .clear : Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 14)
        .background(Theme.bg)
        }
    }

    @ViewBuilder
    private var composerAttachmentsPanel: some View {
        if audioCapture.isCapturing
            || audioCapture.latestSnapshot() != nil
            || audioCapture.lastErrorMessage != nil
            || !selectedImages.isEmpty {
            VStack(spacing: 10) {
                audioComposerPanel

                if !selectedImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .strokeBorder(Theme.border, lineWidth: 1)
                                        )

                                    Button {
                                        selectedImages.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white, Color.black.opacity(0.65))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.inputPadH)
                    }
                }
            }
            .padding(.bottom, engine.messages.isEmpty ? 8 : 0)
        }
    }

    @ViewBuilder
    private var audioComposerPanel: some View {
        if audioCapture.isCapturing {
            RecordingStatusCard(
                duration: audioCapture.duration,
                sampleRate: max(audioCapture.sampleRate, 16_000),
                peakLevel: audioCapture.peakLevel,
                onStop: {
                    _ = audioCapture.stopCapture()
                },
                onDiscard: {
                    _ = audioCapture.stopCapture()
                    _ = audioCapture.consumeLatestSnapshot()
                }
            )
            .padding(.horizontal, Theme.inputPadH)
        } else if let draft = audioCapture.latestSnapshot(),
                  let attachment = ChatAudioAttachment(snapshot: draft) {
            ComposerAudioDraftCard(
                attachment: attachment,
                onDiscard: {
                    _ = audioCapture.consumeLatestSnapshot()
                }
            )
            .padding(.horizontal, Theme.inputPadH)
        } else if let error = audioCapture.lastErrorMessage {
            AudioErrorBanner(
                message: error,
                onDismiss: {
                    audioCapture.clearStatus()
                }
            )
            .padding(.horizontal, Theme.inputPadH)
        }
    }

    private var canSend: Bool {
        (
            !inputText.trimmingCharacters(in: .whitespaces).isEmpty
                || !selectedImages.isEmpty
                || audioCapture.bufferedSampleCount > 0
        )
        && !engine.isProcessing && engine.llm.isLoaded
    }

    private func send() async {
        let text = inputText
        let images = selectedImages
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        let audioSnapshot = audioCapture.consumeLatestSnapshot()
        inputText = ""
        selectedImages = []
        selectedPhotoItem = nil
        isInputFocused = false
        await engine.processInput(text, images: images, audio: audioSnapshot)
    }

    @MainActor
    private func loadSelectedPhoto() async {
        #if canImport(PhotosUI)
        guard let selectedPhotoItem else { return }
        do {
            if let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImages = [ChatImageAttachment.preparedImage(image)]
            }
        } catch {
            print("[UI] Failed to load selected photo: \(error)")
        }
        #endif
    }
}

// MARK: - 用户气泡

struct UserBubble: View {
    let text: String
    let images: [UIImage]
    let audios: [ChatAudioAttachment]
    var body: some View {
        HStack {
            Spacer(minLength: Theme.bubbleMinSpacer)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(audios) { audio in
                    AudioAttachmentBubble(attachment: audio)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.userText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.userBubble, in: UserBubbleShape())
                }
            }
        }
    }
}

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

struct RecordingLevelBars: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                let seed = abs(sin(Double(index) * 0.55))
                let intensity = max(CGFloat(level), 0.08)
                Capsule()
                    .fill(index < highlightedBarCount ? Theme.accent : Theme.textTertiary.opacity(0.35))
                    .frame(width: 4, height: 8 + CGFloat(seed) * (8 + intensity * 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: highlightedBarCount)
    }

    private var highlightedBarCount: Int {
        let normalized = min(max(level, 0), 1)
        return max(2, Int((normalized * 24).rounded(.up)))
    }
}

@ViewBuilder
private func audioMetaChip(text: String, emphasized: Bool = false) -> some View {
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

struct UserBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18, sr: CGFloat = 4
        return Path { p in
            p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                     tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - sr))
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.maxX - sr, y: rect.maxY), radius: sr)
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                     tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                     tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        }
    }
}

// MARK: - AI 回复

struct AIResponseView: View {
    let block: ResponseBlock
    let expandedSkills: Set<UUID>
    let isThinkingExpanded: Bool
    let onToggle: (UUID) -> Void
    let onToggleThinking: () -> Void

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
                // 纯思考状态（无 skill、无文字）
                if isPureThinking {
                    ThinkingIndicator()
                        .padding(.leading, 12)
                        .padding(.vertical, 10)
                }

                // 所有 Skill 卡片（支持多张）
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

                // Skill 完成后等待 follow-up 文字
                if hasSkill && block.isThinking && block.responseText == nil {
                    ThinkingIndicator()
                        .padding(.leading, 12)
                }

                // 回复文本
                if let text = block.responseText {
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 4)
                        .animation(nil, value: text)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: block.skills.count)

            Spacer(minLength: Theme.aiMinSpacer)
        }
    }
}

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

// MARK: - 单个 Skill 卡片（4 步进度）

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
            // 卡片头部
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

            // 展开：4 步进度
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

// MARK: - 旋转 Spinner

struct SpinnerIcon: View {
    @State private var rotating = false
    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

// MARK: - 思考动画

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
