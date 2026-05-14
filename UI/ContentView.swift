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
    @State private var holdASRWarmupTask: Task<Void, Never>?
    @State private var captureOrigin: CaptureOrigin = .menu
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var importedAudioSnapshot: AudioCaptureSnapshot?
    @State private var importedAudioFilename: String?
    @State private var holdToTalkASR = ASRService()
    /// ASR 模型 (Whisper) 没下载时弹的提示, 引导用户去配置页 LIVE 语音模型下载.
    @State private var showASRMissingAlert = false
    /// ASR warmup 任务进行中. 用来在 mic 按钮 / 按住说话按钮上显示 loading 反馈,
    /// 因为 WhisperKit 首次冷启动 ~15s (Core ML 编译 + tokenizer 自动下载),
    /// 没视觉提示用户会以为没在加载。
    @State private var asrIsWarming = false
    /// 触觉反馈 generator. 用 @State 持久持有, 不能用局部变量 — 局部变量在
    /// impactOccurred() 还没真正派发到 haptic engine 之前就 deinit, 震动不触发。
    /// .medium 比 .light 明显, 微信"按住说话"那个力度接近 .medium。
    #if canImport(UIKit)
    @State private var holdHaptic = UIImpactFeedbackGenerator(style: .medium)
    #endif

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

                // v2 UI:空状态 skill chips 暂时不展示,后续会换位置/形态 (TBD)。
                // 函数 `skillChips` 保留供后续恢复 / 重新挂载。
                // if engine.messages.isEmpty {
                //     skillChips.padding(.bottom, 8)
                // }

                inputBar
            }
        }
        .preferredColorScheme(.light)
        .task {
            guard !ProcessInfo.processInfo.isRunningXCTest else { return }
            engine.setup()
            // 不在这里 initialize hold-to-talk ASR. 改为用户第一次按住说话时
            // 通过 ASRService.ensureInitialized 懒加载, 避免 cold start 就占用 ASR 内存 (zh ~160MB / en ~180MB).
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
        .onChange(of: engine.messages.isEmpty) { wasEmpty, isEmpty in
            // 新会话: 卸载 hold-to-talk ASR 以释放内存 (zh ~160MB / en ~180MB). 下次按住说话会 lazy 重新加载.
            // 注意 onChange 只在**变化**时 fire, 初次 render 不会触发. wasEmpty 参数
            // 保证我们只响应 "有消息 -> 清空" 这个方向, 忽略新开一条消息的方向.
            if isEmpty && !wasEmpty {
                print("[UI] New session detected → unloading ASR")
                holdASRWarmupTask?.cancel()
                holdASRWarmupTask = nil
                holdToTalkASR.unload()
            }
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
        .alert(
            tr("开启语音输入", "Set up voice input"),
            isPresented: $showASRMissingAlert
        ) {
            Button(tr("下载", "Download")) {
                showConfigurations = true
            }
            Button(tr("稍后", "Not now"), role: .cancel) {}
        } message: {
            Text({
                let mb = LiveModelDefinition.estimatedSizeMB
                return tr(
                    "首次使用需要下载语音模型（约 \(mb) MB）。",
                    "First use needs a one-time voice model download (~\(mb) MB)."
                )
            }())
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
        // 切换 Think 需要清 KV cache: system prompt 的 <|think|> 段变化后,
        // 若当前会话已有 context, 下一轮走 delta prompt 路径会**复用**旧
        // system prompt, 模型继续按旧设置 reasoning. reset 强制下一轮重新
        // prefill, 新 enableThinking 才能真正生效。
        Task { await engine.resetKVSession() }
    }

    private func canRetry(item: DisplayItem, block: ResponseBlock) -> Bool {
        guard item.id == displayItems.last?.id else { return false }
        guard !engine.isProcessing, engine.isModelReady else { return false }
        guard block.responseText != nil else { return false }
        guard let lastUser = engine.messages.last(where: { $0.role == .user }) else { return false }
        return lastUser.audios.isEmpty
    }

    // MARK: - 顶部栏

    // MARK: - topBar (v2: 极简两元素)
    //
    // 设计稿:左 chip (历史会话入口 + 状态指示) + 右 gear (设置)
    // 移除项 (跟用户当面讨论确认):
    //   - Gemma 4 E2B 模型名 → 进 settings 看
    //   - LIVE 按钮 → 中央 orb 已有 "进入 LIVE" 入口
    //   - 思考模式 toggle → 暂存,后续放到别处 (待定)
    private var topBar: some View {
        HStack(spacing: 0) {
            // 左:历史状态 chip.
            // 28pt 外圈 + 6pt 内点 + opacity 0.6 — 这不是"按钮", 是"悬浮状态痕迹".
            // 视觉重量比 orb / Dynamic Island 都要轻, 不抢戏.
            Button(action: {
                engine.flushPendingSessionSave()
                showHistory = true
            }) {
                ZStack {
                    Circle()
                        .fill(Theme.bgHover.opacity(UIScale.topStatusChipBgOpacity))
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                    Circle()
                        .fill(engine.isModelReady ? Theme.accentMuted : Theme.textTertiary)
                        .frame(
                            width: UIScale.topStatusChipDotSize,
                            height: UIScale.topStatusChipDotSize
                        )
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 右:settings gear — 裸 icon,opacity 0.72 让它"浮在空气里".
            Button(action: { showConfigurations = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: UIScale.gearIconSize, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(UIScale.gearIconOpacity)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
    }

    private var topModelStatusText: String {
        // isModelReady = .ready; isModelGenerating = .generating.
        // Both mean the model is loaded and active — show the model name.
        if engine.isModelReady || engine.isModelGenerating {
            return engine.catalog.modelDisplayName
        }

        let selectedModel = engine.catalog.selectedModel
        switch engine.installer.installState(for: selectedModel.id) {
        case .notInstalled:
            if engine.installer.hasResumableDownload(for: selectedModel.id) {
                return tr("可继续下载模型", "Resume model download")
            }
            if engine.installer.artifactPath(for: selectedModel) == nil {
                return tr("请先下载模型", "Download a model first")
            }
            return engine.statusMessage
        case .checkingSource:
            return tr("正在准备下载...", "Preparing download...")
        case .downloading:
            return tr("正在下载模型...", "Downloading model...")
        case .downloaded:
            return tr("模型已下载，等待加载", "Model downloaded, waiting to load")
        case .bundled:
            return tr("模型已内置，等待加载", "Bundled model, waiting to load")
        case .failed:
            return tr("模型下载失败", "Model download failed")
        }
    }

    // MARK: - 欢迎页

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer()

            // 中央陶瓷球 — 占屏宽 48% (标准) / 44% (大屏),大屏反而 缩,
            // 用更多空气换高级感. 见 UIScale.swift 详释.
            PorcelainOrbView(size: UIScale.orbSize)

            // "进入 LIVE" 入口 — 设计稿是 dot + 文字,无 capsule 背景。
            // dot 用 brand muted gold #C39660,避开 iOS 通知红语义。
            Button(action: enterLiveMode) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(canEnterLiveMode
                              ? Color(hex: "C39660")
                              : Theme.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(tr("进入 LIVE", "Enter LIVE"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(canEnterLiveMode
                                         ? Theme.textPrimary
                                         : Theme.textTertiary)
                }
                .contentShape(Rectangle())  // 整个 HStack 都可点
            }
            .buttonStyle(.plain)
            .disabled(!canEnterLiveMode)
            .padding(.top, UIScale.orbToEntryTextGap)

            Spacer(minLength: UIScale.entryToInputMinGap)
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

    // MARK: - inputBar (v2: 胶囊形容器内嵌 3 个子元素)
    //
    // 设计稿:整个输入框是一个 white capsule,内部 [+] | text | [waveform/send]
    // 三个子元素都"贴着"胶囊内壁,而不是各自独立按钮并排。左右按钮 chip 形
    // (圆形浅底),输入框无自身背景。
    private var inputBar: some View {
        HStack(spacing: UIScale.chipTextSpacing) {
            // 左:+ 附件菜单 — 圆形 chip
            Menu {
                #if canImport(PhotosUI)
                Button {
                    showPhotoPicker = true
                } label: {
                    Label(tr("照片", "Photo"), systemImage: "photo")
                }
                #endif
                Button {
                    captureOrigin = .menu
                    Task { _ = await audioCapture.toggleCapture() }
                } label: {
                    Label(audioCapture.isCapturing && captureOrigin == .menu ? tr("停止录音", "Stop Recording") : tr("录音", "Record"), systemImage: audioCapture.isCapturing && captureOrigin == .menu ? "stop.fill" : "waveform")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label(tr("文件", "File"), systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: UIScale.chipIconSize, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: UIScale.chipDiameter, height: UIScale.chipDiameter)
                    .background(Theme.bgHover, in: Circle())
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

            // 中间:文字输入 或 按住说话 — 无自身背景,贴胶囊
            if isVoiceInputMode {
                holdToTalkButton
            } else {
                #if os(macOS)
                TextField(tr("Ask anything...", "Ask anything..."), text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIScale.pillTextSize))
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit { Task { await send() } }
                #else
                TextField(tr("Ask anything...", "Ask anything..."), text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: UIScale.pillTextSize))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit { Task { await send() } }
                #endif
            }

            // 右:动态按钮 (idle → waveform / 有文字 → send / 生成中 → stop /
            //         语音模式 → keyboard).
            trailingDynamicButton
        }
        // Spec (per master mockup, "floating" Arc/Linear/Vision Pro idiom).
        // 大屏 (Pro Max) 不等比放大 — 组件微增、空气大增, 见 UIScale.swift.
        //   胶囊总高度:    54 / 56pt
        //   chip 距胶囊左/右内距: 12pt
        //   阴影 blur:     16 / 18pt, offsetY 4pt, opacity 0.05
        //   Capsule 自动用 height/2 圆角
        .padding(.horizontal, UIScale.chipInnerMargin)
        .padding(.vertical, (UIScale.pillHeight - UIScale.chipDiameter) / 2)
        .background(
            Theme.bgElevated,
            in: Capsule()
        )
        .shadow(color: Color.black.opacity(0.05), radius: UIScale.pillShadowBlur, x: 0, y: 4)
        .padding(.horizontal, UIScale.pillHorizontalMargin)
        .padding(.vertical, UIScale.inputBarBottomGap)
    }

    // MARK: - 动态尾部按钮 (mic / send / stop / keyboard 四态合一)

    private struct DynamicButtonStyle {
        let icon: String
        let bgColor: Color
        let fgColor: Color
        let action: () -> Void
    }

    private var trailingButtonStyle: DynamicButtonStyle {
        if canCancelGeneration {
            return .init(
                icon: "stop.fill",
                bgColor: Color.red.opacity(0.92),
                fgColor: Theme.bg,
                action: { engine.cancelActiveGeneration() }
            )
        }
        if canSend {
            // chip 保持中性灰, 只 icon 从 waveform 变成 arrow.up.
            // 形态变化驱动状态语义, 不靠 brand color — Arc/Linear/Apple Music 同款逻辑.
            // brand color 只留给 hero element (orb), chip 永远克制.
            return .init(
                icon: "arrow.up",
                bgColor: Theme.bgHover,
                fgColor: Theme.textSecondary,
                action: { Task { await send() } }
            )
        }
        if isVoiceInputMode {
            return .init(
                icon: "keyboard",
                bgColor: Theme.bgHover,  // 暖灰 chip,跟左侧 + 按钮一致,在白胶囊上清晰可见
                fgColor: Theme.textSecondary,
                action: { exitVoiceInputMode() }
            )
        }
        // idle: 输入框空 + 键盘模式 → waveform, 点击进语音模式
        return .init(
            icon: "waveform",
            bgColor: Theme.bgHover,  // 跟左侧 + 按钮的 chip 底色一致
            fgColor: Theme.textSecondary,
            action: { enterVoiceInputMode() }
        )
    }

    private var trailingDynamicButton: some View {
        let style = trailingButtonStyle
        // waveform / keyboard 是 idle 辅助态, icon 用 17pt + opacity 0.68 让它"浮起来";
        // send / stop 是行动态, 用 18pt 满 opacity 强调.
        let isIdleAux = !canSend && !canCancelGeneration
        let iconSize: CGFloat = isIdleAux ? UIScale.waveformIconSize : UIScale.chipIconSize
        let iconOpacity: Double = isIdleAux ? UIScale.waveformIconOpacity : 1.0
        return Button(action: style.action) {
            Image(systemName: style.icon)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(style.fgColor)
                .opacity(iconOpacity)
                .frame(width: UIScale.chipDiameter, height: UIScale.chipDiameter)
                .background(style.bgColor, in: Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeInOut(duration: 0.15), value: canCancelGeneration)
        .animation(.easeInOut(duration: 0.15), value: isVoiceInputMode)
    }

    /// 进入语音模式:检查 ASR 模型, 预热, 切换 UI 状态.
    private func enterVoiceInputMode() {
        // 切到语音模式前先检查 Whisper 模型有没有下载. 没有就弹提示让用户去
        // 配置页 LIVE 语音模型下载, 不要切到语音模式让用户白按住一下才发现没用。
        if LiveModelDefinition.resolve(for: LiveModelDefinition.activeASR) == nil {
            showASRMissingAlert = true
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isVoiceInputMode = true
        }
        // 进入语音模式立即预热 ASR. 加载期间 asrIsWarming = true 让按住说话
        // 按钮灰显 + 禁用点击, 加载完恢复正常. WhisperKit 首次冷启动 ~6-15s
        // (Core ML 编译 + tokenizer 拉取), 没这反馈用户会以为按钮坏了。
        let alreadyLoaded = holdToTalkASR.isAvailable
        log("[UI] Mic button tapped → enter voice mode (ASR \(alreadyLoaded ? "already loaded" : "starting warmup"))")
        holdASRWarmupTask?.cancel()
        if !alreadyLoaded {
            asrIsWarming = true
        }
        // 顺便 prepare haptic engine, 第一次按住时不会有冷启动延迟.
        #if canImport(UIKit)
        holdHaptic.prepare()
        #endif
        let asr = holdToTalkASR
        holdASRWarmupTask = Task.detached {
            await asr.initialize()
            await MainActor.run { asrIsWarming = false }
        }
    }

    /// 退出语音模式:卸载 ASR 释放内存, 切回键盘.
    private func exitVoiceInputMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isVoiceInputMode = false
        }
        // 切回键盘模式: 立即卸载 ASR 释放内存 (zh ~160MB / en ~180MB)。
        // 之前的策略是"保留, 用户可能秒切回来" — 但用户反馈期望
        // 显式 cancel 行为, 不要默默占内存。需要再用语音时点 mic
        // 重新加载 (Core ML 系统层 cache 命中, 0.5s 即可恢复)。
        log("[UI] Exit voice mode → unloading ASR")
        isInputFocused = true
        holdASRWarmupTask?.cancel()
        holdASRWarmupTask = nil
        asrIsWarming = false
        holdToTalkASR.unload()
    }

    // MARK: - 按住说话

    private var holdToTalkButton: some View {
        // 加载中 (asrIsWarming) 灰显 + 禁用点击, 加载完毕恢复正常颜色。
        // 灰显: 整体 .opacity(0.4) 一刀切, 比之前局部改 fg/bg 颜色对比明显得多。
        let isDisabled = asrIsWarming
        let label = isDisabled
            ? tr("正在准备...", "Preparing...")
            : (isHoldRecording ? tr("松开 结束", "Release to Stop") : tr("按住 说话", "Hold to Talk"))
        return Text(label)
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
            .opacity(isDisabled ? 0.4 : 1.0)
            .allowsHitTesting(!isDisabled)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHoldRecording else { return }
                        guard !asrIsWarming else { return }
                        isHoldRecording = true
                        captureOrigin = .holdToTalk
                        // 微信式触觉反馈: 按下瞬间一次震, 让用户确认录音开始。
                        // .medium = 微信级力度. impactOccurred 后立即 prepare,
                        // 下次按住能秒响应不需要冷启动 haptic engine。
                        #if canImport(UIKit)
                        holdHaptic.impactOccurred()
                        holdHaptic.prepare()
                        #endif
                        holdStartTask = Task {
                            await audioCapture.startCapture()
                        }
                        // ASR warmup 已经在 mic 按钮切到语音模式时启动, 这里不需要再发一次.
                        // 万一 warmup task 没被启动 (e.g. 直接进入 hold-to-talk 路径而没经过
                        // mic toggle, 当前 UI 走不到但作为防御), ensureInitialized 会在
                        // 真正 transcribe 时兜底加载。
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
                            guard snapshot.duration >= 0.45 else {
                                print("[UI] Hold-to-talk: recording too short (\(String(format: "%.2f", snapshot.duration))s), skipping ASR")
                                return
                            }
                            _ = await holdASRWarmupTask?.value
                            holdASRWarmupTask = nil

                            // ASR 转文字 → 填入输入框 → 自动发送
                            let transcript = await Task.detached {
                                await holdToTalkASR.transcribe(
                                    samples: snapshot.pcm,
                                    sampleRate: Int(snapshot.sampleRate)
                                )
                            }.value
                            // Whisper 在静音/噪声段会输出特殊 token. 同时过滤几种已知的
                            // "no speech" 标记 + 空字符串. 不发出去, 不让模型为空响应。
                            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            let blankMarkers: Set<String> = [
                                "", "[BLANK_AUDIO]", "(silence)", "(no speech)",
                                "[音乐]", "[Music]", "[ Music ]", "(Music)"
                            ]
                            guard !blankMarkers.contains(trimmed) else {
                                print("[UI] Hold-to-talk: silent / no-speech audio (\"\(trimmed)\"), ignoring")
                                return
                            }
                            print("[UI] Hold-to-talk ASR transcript: \"\(trimmed)\"")
                            inputText = trimmed
                            // Hold-to-talk 是"用语音口述文字"的语义, 录的音频只是 ASR 的输入,
                            // 不是给模型的附件. send() 默认会把 audioCapture 里的 snapshot
                            // 当附件带过去, 这里显式禁用, 让发出去的就是纯文本消息。
                            await send(includeAudio: false)
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
                Text(importedAudioFilename ?? tr("音频文件", "Audio File"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(String(format: tr("%.1f 秒 · %d kHz", "%.1f s · %d kHz"), snapshot.duration, Int(snapshot.sampleRate / 1000)))
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
        && !engine.isProcessing && engine.isModelReady
    }

    /// 当前选中模型的能力声明。UI 按它 gate Live / 思考 / MTP 等按钮显示。
    /// 找不到对应 descriptor (理论上不可能) 时返回默认全 false 能力, 把按钮全藏掉,
    /// 避免误显示无效按钮把 UX 搞乱。
    private var currentModelCapabilities: ModelCapabilities {
        guard let desc = engine.availableModels.first(where: { $0.id == engine.config.selectedModelID }) else {
            return ModelCapabilities()
        }
        return desc.capabilities
    }

    private var canEnterLiveMode: Bool {
        engine.isModelReady && currentModelCapabilities.supportsLive
    }

    /// 顶部 "思考" 按钮是否显示。只有声明 supportsThinking=true 的模型才显示, 否则
    /// 整个按钮藏掉 (而不是 disable+灰色) — disable 还在那里占位但点不亮, 反而更
    /// 让用户疑惑。比如 MiniCPM-V 4.6 没思考模式, 整个按钮在 v4.6 加载时消失。
    private var showThinkingButton: Bool {
        currentModelCapabilities.supportsThinking
    }

    private var canCancelGeneration: Bool {
        engine.isProcessing || engine.isModelGenerating
    }

    /// `includeAudio = false`: hold-to-talk 这种"用语音口述文字"的入口用,
    /// 录音只作 ASR 输入, 不当附件发给模型. 内部还是会显式 consume / 清理
    /// audioCapture 里的 snapshot, 防止下一轮误带。
    private func send(includeAudio: Bool = true) async {
        let text = inputText
        let images = selectedImages
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        // 优先用导入的音频文件, 其次用麦克风录音
        let pendingMicSnapshot = audioCapture.consumeLatestSnapshot()
        let audioSnapshot: AudioCaptureSnapshot? = includeAudio
            ? (importedAudioSnapshot ?? pendingMicSnapshot)
            : nil
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
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — 音频解码失败]", "[Attachment: \(filename) — audio decode failed]")
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
                        inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — PDF 无法提取文字]", "[Attachment: \(filename) — couldn't extract text from PDF]")
                    } else {
                        // 限制长度避免超出上下文
                        let maxChars = 4000
                        let content = trimmed.count > maxChars
                            ? String(trimmed.prefix(maxChars)) + tr("\n...(已截断)", "\n...(truncated)")
                            : trimmed
                        inputText += (inputText.isEmpty ? "" : "\n") + tr("以下是 \(filename) 的内容:\n\(content)", "Contents of \(filename):\n\(content)")
                    }
                    print("[UI] PDF imported: \(filename) (\(pdfDoc.numberOfPages) pages)")
                } else {
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — PDF 打开失败]", "[Attachment: \(filename) — couldn't open PDF]")
                }
            }
            // 文本文件 → 直接读取
            else if ["txt", "md", "json", "csv", "xml", "html", "swift", "py", "js"].contains(ext) {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let maxChars = 4000
                    let trimmed = content.count > maxChars
                        ? String(content.prefix(maxChars)) + tr("\n...(已截断)", "\n...(truncated)")
                        : content
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("以下是 \(filename) 的内容:\n\(trimmed)", "Contents of \(filename):\n\(trimmed)")
                    print("[UI] Text file imported: \(filename)")
                } catch {
                    print("[UI] Failed to read text file: \(error)")
                }
            }
            // 其他 → 标注文件名
            else {
                inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename)]", "[Attachment: \(filename)]")
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
                if engine.sessionStore.sessionSummaries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(engine.sessionStore.sessionSummaries) { session in
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
                                            if session.id == engine.sessionStore.currentSessionID {
                                                Text(tr("当前", "Current"))
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
                                engine.deleteSession(id: engine.sessionStore.sessionSummaries[index].id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.bg)
                }
            }
            .navigationTitle(tr("历史记录", "History"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("关闭", "Close")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        engine.startNewSession()
                        dismiss()
                    } label: {
                        Label(tr("新会话", "New Chat"), systemImage: "square.and.pencil")
                    }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            Text(tr("还没有历史记录", "No chat history yet"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(tr(
                "开始一次新会话后，聊天内容会自动保存在这里。",
                "Start a new chat — your messages will be saved here automatically."
            ))
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                engine.startNewSession()
                dismiss()
            } label: {
                Text(tr("开始新会话", "Start New Chat"))
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
                                Label(tr("复制", "Copy"), systemImage: "doc.on.doc")
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
