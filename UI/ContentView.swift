import SwiftUI
import MarkdownUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers
import PDFKit


private extension ProcessInfo {
    var isRunningXCTest: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

// MARK: - 主入口

private enum CaptureOrigin { case menu, holdToTalk }
private struct ScrollSignal: Equatable {
    let lastMessageID: UUID?
    let messageCount: Int
    let lastMessageContentCount: Int
    let isProcessing: Bool
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = AgentEngine()
    @State private var audioCapture = AudioCaptureService()
    @State private var inputText = ""
    @State private var selectedImages: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showConfigurations = false
    @State private var showHistory = false
    @State private var showLiveMode = false
    /// 记录每个 skill 卡片的展开状态（key = SkillCard.id）
    @State private var expandedSkills: Set<UUID> = []
    /// 记录每个 THINK 卡片的展开状态（key = ResponseBlock.id）
    @State private var expandedThoughts: Set<UUID> = []
    @FocusState private var isInputFocused: Bool

    // MARK: - Voice Input Mode
    @State private var isVoiceInputMode = false
    @State private var isHoldRecording = false
    @State private var holdStartTask: Task<Bool, Never>?
    @State private var captureOrigin: CaptureOrigin = .menu
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var importedAudioSnapshot: AudioCaptureSnapshot?
    @State private var importedAudioFilename: String?
    @State private var holdToTalkASR = ASRService()

    private var displayItems: [DisplayItem] {
        buildDisplayItems(from: engine.messages, isProcessing: engine.isProcessing)
    }

    private var scrollSignal: ScrollSignal {
        let lastMessage = engine.messages.last
        return ScrollSignal(
            lastMessageID: lastMessage?.id,
            messageCount: engine.messages.count,
            lastMessageContentCount: lastMessage?.content.count ?? 0,
            isProcessing: engine.isProcessing
        )
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
        .task {
            guard !ProcessInfo.processInfo.isRunningXCTest else { return }
            engine.setup()
            holdToTalkASR.initialize()
        }
        .task(id: selectedPhotoItem) {
            await loadSelectedPhoto()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                audioCapture.refreshPermissionStatus()
                return
            }
            engine.flushPendingSessionSave()
            engine.cancelActiveGeneration()
            _ = audioCapture.stopCapture()
        }
        .sheet(isPresented: $showHistory) {
            SessionHistorySheet(engine: engine)
        }
        .fullScreenCover(isPresented: $showLiveMode) {
            LiveModeView(
                isPresented: $showLiveMode,
                inference: engine.inference,
                catalog: engine.catalog,
                userSystemPrompt: engine.config.systemPrompt
            )
        }
        .sheet(isPresented: $showConfigurations) {
            ConfigurationsView(engine: engine)
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
                                onToggleThinking: { toggleThinking(block.id) },
                                onRetry: canRetry(item: item, block: block)
                                    ? { Task { await engine.retryLastResponse() } }
                                    : nil
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.chatPadH)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .task(id: scrollSignal) {
                let signal = scrollSignal
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollTo(proxy, animated: !signal.isProcessing)
            }
        }
    }

    @MainActor
    private func scrollTo(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = displayItems.last else { return }
        let lastID = last.id
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
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

    private func canRetry(item: DisplayItem, block: ResponseBlock) -> Bool {
        guard item.id == displayItems.last?.id else { return false }
        guard !engine.isProcessing, engine.inference.isLoaded else { return false }
        guard block.responseText != nil else { return false }
        guard let lastUser = engine.messages.last(where: { $0.role == .user }) else { return false }
        return lastUser.audios.isEmpty
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 0) {
            // 左：历史/新会话
            Button(action: {
                engine.flushPendingSessionSave()
                showHistory = true
            }) {
                Image(systemName: "clock.arrow.circlepath")
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
                    .fill(engine.inference.isLoaded ? Theme.accentGreen : Theme.accent)
                    .frame(width: 6, height: 6)
                Text(engine.inference.isLoaded ? engine.catalog.modelDisplayName : engine.inference.statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // 右：LIVE + 思考 + 设置
            HStack(spacing: 6) {
                Button(action: enterLiveMode) {
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(canEnterLiveMode ? Theme.textSecondary : Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        Theme.bgElevated,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canEnterLiveMode)

                Button(action: toggleThinkingMode) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
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

                Button(action: { showConfigurations = true }) {
                    Image(systemName: "gearshape")
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
            Button(action: enterLiveMode) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("进入 LIVE")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(canEnterLiveMode ? Theme.bg : Theme.textTertiary)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    canEnterLiveMode ? Theme.accentGreen : Theme.bgElevated,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        canEnterLiveMode ? .clear : Theme.border,
                        lineWidth: 1
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canEnterLiveMode)
            .padding(.top, 22)
            Spacer()
        }
    }

    // MARK: - Skill 快捷标签
    //
    // Chip 完全由 SKILL.md 数据驱动:
    //   - UI 显示 = skill.chipLabel (来自 SKILL.md `chip_label`, 短) ?? chipPrompt (兜底)
    //   - 点击发送 = skill.chipPrompt (来自 SKILL.md `chip_prompt`, 长完整命令)
    //   - 图标 = skill.icon (来自 SKILL.md `icon` 字段)
    //
    // Decoupled: chip 视觉短紧凑 ("创建日程"), 发送给 LLM 的是完整意图
    // ("帮我创建明天下午两点的产品评审会议") —— LLM 拿到具体例子能直接执行,
    // 不用反问 "什么时间什么主题".
    //
    // 没声明 chip_prompt 的 skill 不会出现在 chip 列表.

    private var skillChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(engine.enabledSkillInfos.compactMap { skill -> (SkillInfo, label: String, prompt: String)? in
                    guard let prompt = skill.chipPrompt, !prompt.isEmpty else { return nil }
                    let label = (skill.chipLabel?.isEmpty == false) ? skill.chipLabel! : prompt
                    return (skill, label, prompt)
                }, id: \.0.name) { skill, chipLabel, chipPrompt in
                    Button {
                        inputText = chipPrompt
                        Task { await send() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(chipLabel).font(.system(size: 12, weight: .medium))
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

    /// 只有"录音已结束 + 有有效音频"才算完成草稿
    private var hasCompletedDraft: Bool {
        !audioCapture.isCapturing && audioCapture.latestSnapshot() != nil
    }

    private var inputBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // 左侧：+ 号附件菜单
                Menu {
                    #if canImport(PhotosUI)
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("照片", systemImage: "photo")
                    }
                    #endif
                    Button {
                        captureOrigin = .menu
                        Task { _ = await audioCapture.toggleCapture() }
                    } label: {
                        Label(audioCapture.isCapturing && captureOrigin == .menu ? "停止录音" : "录音", systemImage: audioCapture.isCapturing && captureOrigin == .menu ? "stop.fill" : "waveform")
                    }
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("文件", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                #if canImport(PhotosUI)
                .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
                #endif
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.audio, .pdf, .plainText, .data],
                    allowsMultipleSelection: false
                ) { result in
                    handleImportedFile(result)
                }

                // 中间：文字输入 或 按住说话
                if isVoiceInputMode {
                    holdToTalkButton
                } else {
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
                }

                // 右侧：mic/keyboard 切换 + send/stop
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVoiceInputMode.toggle()
                    }
                    if !isVoiceInputMode {
                        isInputFocused = true
                    }
                } label: {
                    Image(systemName: isVoiceInputMode ? "keyboard" : "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                Button {
                    if canCancelGeneration {
                        engine.cancelActiveGeneration()
                    } else {
                        Task { await send() }
                    }
                } label: {
                    Image(systemName: canCancelGeneration ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(
                            canCancelGeneration || canSend
                                ? Theme.bg
                                : Theme.textTertiary
                        )
                        .frame(width: 34, height: 34)
                        .background(
                            canCancelGeneration
                                ? Color.red.opacity(0.92)
                                : (canSend ? Theme.accent : Theme.bgElevated),
                            in: Circle()
                        )
                        .overlay(
                            Circle().strokeBorder(
                                canCancelGeneration || canSend ? .clear : Theme.border,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !canCancelGeneration)
                .animation(.easeInOut(duration: 0.15), value: canSend)
                .animation(.easeInOut(duration: 0.15), value: canCancelGeneration)
            }
            .padding(.horizontal, Theme.inputPadH)
            .padding(.vertical, 14)
            .background(Theme.bg)
        }
    }

    // MARK: - 按住说话

    private var holdToTalkButton: some View {
        Text(isHoldRecording ? "松开 结束" : "按住 说话")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isHoldRecording ? Theme.bg : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                isHoldRecording ? Theme.accent : Theme.bgElevated,
                in: RoundedRectangle(cornerRadius: 22)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(isHoldRecording ? Theme.accent : Theme.border, lineWidth: 1)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHoldRecording else { return }
                        isHoldRecording = true
                        captureOrigin = .holdToTalk
                        holdStartTask = Task {
                            await audioCapture.startCapture()
                        }
                    }
                    .onEnded { _ in
                        guard isHoldRecording else { return }
                        isHoldRecording = false
                        Task {
                            // 等 start 完成后再 stop，避免反序
                            _ = await holdStartTask?.value
                            holdStartTask = nil
                            guard let snapshot = audioCapture.stopCapture() else { return }
                            _ = audioCapture.consumeLatestSnapshot()

                            // ASR 转文字 → 填入输入框 → 自动发送
                            let transcript = holdToTalkASR.transcribe(
                                samples: snapshot.pcm,
                                sampleRate: Int(snapshot.sampleRate)
                            )
                            guard !transcript.isEmpty else {
                                print("[UI] Hold-to-talk: empty ASR result, ignoring")
                                return
                            }
                            inputText = transcript
                            await send()
                        }
                    }
            )
    }

    @ViewBuilder
    private var composerAttachmentsPanel: some View {
        if (audioCapture.isCapturing && captureOrigin == .menu)
            || hasCompletedDraft
            || audioCapture.lastErrorMessage != nil
            || !selectedImages.isEmpty
            || importedAudioSnapshot != nil {
            VStack(spacing: 10) {
                audioComposerPanel

                // 导入的音频文件附件卡片
                if let snapshot = importedAudioSnapshot {
                    importedAudioCard(snapshot: snapshot)
                        .padding(.horizontal, Theme.inputPadH)
                }

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

    /// 导入音频文件的附件预览卡片
    private func importedAudioCard(snapshot: AudioCaptureSnapshot) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(importedAudioFilename ?? "音频文件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.1f 秒 · %d kHz", snapshot.duration, Int(snapshot.sampleRate / 1000)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    importedAudioSnapshot = nil
                    importedAudioFilename = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var audioComposerPanel: some View {
        if audioCapture.isCapturing && captureOrigin == .menu {
            RecordingStatusCard(
                duration: audioCapture.duration,
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
        } else if hasCompletedDraft,
                  let draft = audioCapture.latestSnapshot(),
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
                || hasCompletedDraft
                || importedAudioSnapshot != nil
        )
        && !engine.isProcessing && engine.inference.isLoaded
    }

    private var canEnterLiveMode: Bool {
        engine.inference.isLoaded
    }

    private var canCancelGeneration: Bool {
        engine.isProcessing || engine.inference.isGenerating
    }

    private func send() async {
        let text = inputText
        let images = selectedImages
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        // 优先用导入的音频文件, 其次用麦克风录音
        let audioSnapshot = importedAudioSnapshot ?? audioCapture.consumeLatestSnapshot()
        inputText = ""
        selectedImages = []
        selectedPhotoItem = nil
        importedAudioSnapshot = nil
        importedAudioFilename = nil
        isInputFocused = false
        await engine.processInput(text, images: images, audio: audioSnapshot)
    }

    private func enterLiveMode() {
        guard canEnterLiveMode else { return }
        engine.cancelActiveGeneration()
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        _ = audioCapture.consumeLatestSnapshot()
        isInputFocused = false
        showLiveMode = true
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

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                print("[UI] File import: cannot access \(url.lastPathComponent)")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let filename = url.lastPathComponent
            let ext = url.pathExtension.lowercased()

            // 音频文件 → 读取为 PCM 并走音频附件路径
            if ["wav", "mp3", "m4a", "aac", "caf", "flac", "ogg"].contains(ext) {
                do {
                    let snapshot = try Self.decodeAudioFile(url: url)
                    importedAudioSnapshot = snapshot
                    importedAudioFilename = filename
                    print("[UI] Audio file decoded: \(filename) → \(snapshot.pcm.count) samples @ \(Int(snapshot.sampleRate))Hz, \(String(format: "%.1f", snapshot.duration))s")
                } catch {
                    inputText += (inputText.isEmpty ? "" : "\n") + "[附件: \(filename) — 音频解码失败]"
                    print("[UI] Failed to decode audio file: \(error)")
                }
            }
            // PDF → 提取文字内容
            else if ext == "pdf" {
                if let pdfDoc = CGPDFDocument(url as CFURL) {
                    var pdfText = ""
                    for pageNum in 1...pdfDoc.numberOfPages {
                        guard let page = pdfDoc.page(at: pageNum) else { continue }
                        // 尝试用 PDFKit 提取文字
                        if let pdfPage = PDFDocument(url: url)?.page(at: pageNum - 1) {
                            pdfText += pdfPage.string ?? ""
                            pdfText += "\n"
                        }
                    }
                    let trimmed = pdfText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        inputText += (inputText.isEmpty ? "" : "\n") + "[附件: \(filename) — PDF 无法提取文字]"
                    } else {
                        // 限制长度避免超出上下文
                        let maxChars = 4000
                        let content = trimmed.count > maxChars
                            ? String(trimmed.prefix(maxChars)) + "\n...(已截断)"
                            : trimmed
                        inputText += (inputText.isEmpty ? "" : "\n") + "以下是 \(filename) 的内容:\n\(content)"
                    }
                    print("[UI] PDF imported: \(filename) (\(pdfDoc.numberOfPages) pages)")
                } else {
                    inputText += (inputText.isEmpty ? "" : "\n") + "[附件: \(filename) — PDF 打开失败]"
                }
            }
            // 文本文件 → 直接读取
            else if ["txt", "md", "json", "csv", "xml", "html", "swift", "py", "js"].contains(ext) {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let maxChars = 4000
                    let trimmed = content.count > maxChars
                        ? String(content.prefix(maxChars)) + "\n...(已截断)"
                        : content
                    inputText += (inputText.isEmpty ? "" : "\n") + "以下是 \(filename) 的内容:\n\(trimmed)"
                    print("[UI] Text file imported: \(filename)")
                } catch {
                    print("[UI] Failed to read text file: \(error)")
                }
            }
            // 其他 → 标注文件名
            else {
                inputText += (inputText.isEmpty ? "" : "\n") + "[附件: \(filename)]"
                print("[UI] Unknown file type imported: \(filename)")
            }

        case .failure(let error):
            print("[UI] File import failed: \(error)")
        }
    }

    // MARK: - Audio File Decoder

    /// 解码任意音频文件 (MP3/WAV/M4A/AAC/…) 为 16kHz mono PCM Float
    private static func decodeAudioFile(url: URL) throws -> AudioCaptureSnapshot {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        // 目标: 16kHz mono Float32
        let targetSR: Double = 16_000
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSR,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioDecode", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }

        // 读原始 PCM
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioDecode", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create source buffer"])
        }
        try file.read(into: srcBuffer)

        // 转换到 16kHz mono
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "AudioDecode", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }
        let ratio = targetSR / srcFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            throw NSError(domain: "AudioDecode", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create output buffer"])
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let error { throw error }
        guard status != .error else {
            throw NSError(domain: "AudioDecode", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Conversion failed"])
        }

        // 提取 Float samples
        guard let channelData = outBuffer.floatChannelData else {
            throw NSError(domain: "AudioDecode", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "No channel data"])
        }
        let count = Int(outBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        return AudioCaptureSnapshot(
            pcm: samples,
            sampleRate: targetSR,
            channelCount: 1,
            duration: Double(count) / targetSR
        )
    }
}


// LiveModeView has been extracted to LiveModeUI.swift

private struct SessionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var engine: AgentEngine

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if engine.sessionSummaries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(engine.sessionSummaries) { session in
                            Button {
                                engine.loadSession(id: session.id)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Text(session.title)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(Theme.textPrimary)
                                                .lineLimit(1)
                                            if session.id == engine.currentSessionID {
                                                Text("当前")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(Theme.bg)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Theme.accent, in: Capsule())
                                            }
                                        }

                                        Text(session.preview)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(2)

                                        Text(Self.dateFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textTertiary)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.bgElevated)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                engine.deleteSession(id: engine.sessionSummaries[index].id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.bg)
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        engine.startNewSession()
                        dismiss()
                    } label: {
                        Label("新会话", systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            Text("还没有历史记录")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("开始一次新会话后，聊天内容会自动保存在这里。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                engine.startNewSession()
                dismiss()
            } label: {
                Text("开始新会话")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Theme.bg)
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
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.userBubble, in: UserBubbleShape())
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = text
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
    }
}

// Audio, Response, and Shared UI components have been extracted to:
// - AudioUI.swift
// - ResponseUI.swift
// - SharedUI.swift
