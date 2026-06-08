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

private extension View {
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.contentTransition(.symbolEffect(.replace.downUp))
        } else {
            self
        }
    }
}

private extension ModelInstallState {
    var isTransientInstallState: Bool {
        switch self {
        case .checkingSource, .downloading:
            return true
        default:
            return false
        }
    }
}

// MARK: - 主入口

private enum CaptureOrigin { case menu, holdToTalk }
private struct TopStatusHint: Equatable {
    let id: String
    let text: String
    let symbolName: String?
    let showsProgress: Bool
    let isWarning: Bool
}

private struct StarterAction: Identifiable {
    let id: String
    let title: String
    let prompt: String
    let symbolName: String
    let opensPhotoPicker: Bool
}

private struct ScrollSignal: Equatable {
    let lastMessageID: UUID?
    let lastMessageRole: String?
    let messageCount: Int
    let lastMessageContentCount: Int
    let isProcessing: Bool
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = AgentEngine()
    @State private var audioCapture = AudioCaptureService()
    @State private var inputText = ""
    @State private var pendingContextFollowUpAct: DialogueAct?
    @State private var pendingContextFollowUpDraft: String?
    @State private var pendingContextFollowUpTargetItemID: UUID?
    @State private var selectedImages: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showConfigurations = false
    @State private var showHistory = false
    @State private var showLiveMode = false
    @State private var showModelSwitcher = false
    /// 记录每个 skill 卡片的展开状态（key = SkillCard.id）
    @State private var expandedSkills: Set<UUID> = []
    /// 记录每个 THINK 卡片的展开状态（key = ResponseBlock.id）
    @State private var expandedThoughts: Set<UUID> = []
    @State private var keyboardScrollTask: Task<Void, Never>?
    @State private var shouldAutoFollowChat = true
    @FocusState private var isInputFocused: Bool

    // MARK: - Voice Input Mode
    @State private var isVoiceInputMode = false
    @State private var isHoldRecording = false
    @State private var holdStartTask: Task<Bool, Never>?
    @State private var holdASRWarmupTask: Task<Void, Never>?
    @State private var captureOrigin: CaptureOrigin = .menu
    @State private var showAttachmentTray = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var importedAudioSnapshot: AudioCaptureSnapshot?
    @State private var importedAudioFilename: String?
    @State private var holdToTalkASR = ASRService()
    /// 语音模型未就绪时弹的应用内提示, 引导用户去配置页下载 LIVE 语音模型。
    @State private var showVoiceModelPrompt = false
    @State private var transientTopNotice: TopStatusHint?
    @State private var topNoticeDismissTask: Task<Void, Never>?
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
    @State private var cachedDisplayItems: [DisplayItem] = []
    @State private var cachedDisplayMessageIDs: [UUID] = []

    private var displayItems: [DisplayItem] {
        cachedDisplayItems
    }

    private var scrollSignal: ScrollSignal {
        let lastMessage = engine.messages.last
        return ScrollSignal(
            lastMessageID: lastMessage?.id,
            lastMessageRole: lastMessage?.role.rawValue,
            messageCount: engine.messages.count,
            lastMessageContentCount: shouldAutoFollowChat ? (lastMessage?.content.count ?? 0) : 0,
            isProcessing: engine.isProcessing
        )
    }

    private var composerSkillPrompts: [String] {
        var seen = Set<String>()
        let prompts = engine.enabledSkillInfos.compactMap(composerPrompt)

        let unique = prompts.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            return [tr("问点什么…", "Ask anything...", "なんでも聞いてください…")]
        }
        return Array(unique.prefix(8))
    }

    private func composerPrompt(for skill: SkillInfo) -> String? {
        switch skill.name {
        case "calendar":
            return tr("创建明天下午会议", "Create tomorrow's meeting", "明日午後の会議を作成")
        case "reminders":
            return tr("今晚八点提醒我", "Remind me at 8pm", "今夜8時にリマインド")
        case "contacts":
            return tr("添加一个联系人", "Add a contact", "連絡先を追加")
        case "clipboard":
            return tr("读取剪贴板内容", "Read my clipboard", "クリップボードを読む")
        case "health":
            return tr("查看今天步数", "Show today's steps", "今日の歩数を見る")
        case "translate":
            return tr("翻译这句话", "Translate this sentence", "この文を翻訳")
        default:
            let fallback = skill.chipLabel?.isEmpty == false
                ? skill.chipLabel
                : (skill.samplePrompt.isEmpty ? skill.chipPrompt : skill.samplePrompt)
            return fallback?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var starterActions: [StarterAction] {
        [
            StarterAction(
                id: "write-article",
                title: tr("帮我写文章", "Write an article", "記事を書いて"),
                prompt: tr(
                    "请帮我写一篇 800 字左右的文章，主题是：为什么本地 AI 会成为手机上的重要能力。要求结构清晰、语气自然、有小标题，最后给出三个要点总结。",
                    "Please write an article of about 800 words on the topic: why local AI will become an important capability on phones. Make it clearly structured, natural in tone, include section headings, and end with three key takeaways.",
                    "「なぜローカル AI がスマホで重要な能力になるのか」をテーマに、800 字程度の記事を書いてください。構成を明確に、自然な語り口で、小見出しを付け、最後に 3 つの要点でまとめてください。"
                ),
                symbolName: "doc.text",
                opensPhotoPicker: false
            ),
            StarterAction(
                id: "schedule",
                title: tr("安排日程", "Schedule", "予定を入れる"),
                prompt: tr(
                    "帮我预定下明天下午两点的产品会议。",
                    "Schedule a product meeting for tomorrow at 2 PM.",
                    "明日午後2時にプロダクト会議を予定に入れてください。"
                ),
                symbolName: "calendar.badge.plus",
                opensPhotoPicker: false
            ),
            StarterAction(
                id: "activity",
                title: tr("今天的运动量", "Today's activity", "今日の運動量"),
                prompt: tr(
                    "今天的运动量怎么样？",
                    "How is my activity today?",
                    "今日の運動量はどう？"
                ),
                symbolName: "figure.walk",
                opensPhotoPicker: false
            ),
            StarterAction(
                id: "web-search",
                title: tr("联网搜索", "Web search", "ウェブ検索"),
                prompt: tr(
                    "联网搜索今天的 AI 新闻",
                    "Search the web: latest artificial intelligence news",
                    "ウェブで最新の AI ニュースを検索"
                ),
                symbolName: "magnifyingglass",
                opensPhotoPicker: false
            ),
            StarterAction(
                id: "analyze-image",
                title: tr("分析图片", "Analyze image", "画像を分析"),
                prompt: tr(
                    "请分析这张图片，告诉我关键内容、可能的问题和下一步建议。",
                    "Please analyze this image and tell me the key content, possible issues, and next-step suggestions.",
                    "この画像を分析して、重要な内容、考えられる問題、次のステップの提案を教えてください。"
                ),
                symbolName: "photo",
                opensPhotoPicker: true
            )
        ]
    }

    private var shouldShowStarterActions: Bool {
        engine.messages.isEmpty
            && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedImages.isEmpty
            && importedAudioSnapshot == nil
            && !audioCapture.isCapturing
            && !showAttachmentTray
            && !isVoiceInputMode
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                chatList
                    .opacity(engine.messages.isEmpty ? 0 : 1)
                    .allowsHitTesting(!engine.messages.isEmpty)
                    .accessibilityHidden(engine.messages.isEmpty)

                welcomeView
                    .opacity(engine.messages.isEmpty ? 1 : 0)
                    .scaleEffect(engine.messages.isEmpty ? 1 : 0.985)
                    .allowsHitTesting(engine.messages.isEmpty)
                    .accessibilityHidden(!engine.messages.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            composerDock
        }
        .background(Theme.bg.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.28), value: engine.messages.isEmpty)
        .overlay {
            voiceModelPromptOverlay
        }
        .task {
            guard !ProcessInfo.processInfo.isRunningXCTest else { return }
            engine.setup()
            refreshDisplayItems()
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
        .onChange(of: engine.messagesRevision) { _, _ in
            refreshDisplayItems()
        }
        .onChange(of: engine.isProcessing) { _, _ in
            refreshDisplayItems()
        }
        .onChange(of: isInputFocused) { _, focused in
            if focused {
                showAttachmentTray = false
                #if canImport(UIKit)
                // 聚焦输入框 = 用户要往别处去, 顺手清掉 AI 回复 UITextView 的选区。
                NotificationCenter.default.post(name: .dismissAssistantTextSelection, object: nil)
                #endif
            }
        }
        .onChange(of: engine.installer.installStates) { oldStates, newStates in
            handleInstallStateChange(from: oldStates, to: newStates)
        }
        .onChange(of: engine.coordinator.sessionState) { _, newState in
            handleRuntimeStateChange(newState)
        }
        .onDisappear {
            topNoticeDismissTask?.cancel()
            topNoticeDismissTask = nil
        }
        .fullScreenCover(isPresented: $showHistory) {
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
        .fullScreenCover(isPresented: $showConfigurations) {
            ConfigurationsView(engine: engine)
        }
        .sheet(isPresented: $showModelSwitcher) {
            ModelSwitcherSheet(engine: engine)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func refreshDisplayItems() {
        let messages = engine.messages
        let messageIDs = messages.map(\.id)

        defer {
            cachedDisplayMessageIDs = messageIDs
        }

        if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }),
           let cachedUserIndex = cachedDisplayMessageIDs.lastIndex(of: messages[lastUserIndex].id),
           cachedUserIndex == lastUserIndex,
           cachedDisplayMessageIDs.prefix(cachedUserIndex + 1).elementsEqual(messageIDs.prefix(lastUserIndex + 1)),
           let displayCutIndex = cachedDisplayItems.lastIndex(where: { $0.id == messages[lastUserIndex].id }) {
            let tailStart = messages.index(after: lastUserIndex)
            let tailMessages = tailStart < messages.endIndex ? Array(messages[tailStart...]) : []
            let tailItems = buildDisplayItems(
                from: tailMessages,
                isProcessing: engine.isProcessing
            )
            cachedDisplayItems = Array(cachedDisplayItems.prefix(displayCutIndex + 1)) + tailItems
            return
        }

        cachedDisplayItems = buildDisplayItems(
            from: engine.messages,
            isProcessing: engine.isProcessing
        )
    }

    @ViewBuilder
    private var voiceModelPromptOverlay: some View {
        if showVoiceModelPrompt {
            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissVoiceModelPrompt()
                    }

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(tr("语音模型未就绪", "Voice models not ready", "音声モデルが未準備"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        Text({
                            let mb = LiveModelDefinition.estimatedSizeMB
                            return tr(
                                "首次使用语音输入或 LIVE 需要下载语音模型，约 \(mb) MB。",
                                "Voice input and LIVE need a voice model download, about \(mb) MB.",
                                "音声入力や LIVE を初めて使うには音声モデルのダウンロードが必要です（約 \(mb) MB）。"
                            )
                        }())
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        voicePromptButton(
                            title: tr("稍后", "Not now", "あとで"),
                            isPrimary: false
                        ) {
                            dismissVoiceModelPrompt()
                        }

                        voicePromptButton(
                            title: tr("下载", "Download", "ダウンロード"),
                            isPrimary: true
                        ) {
                            dismissVoiceModelPrompt()
                            showConfigurations = true
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 330)
                .background(
                    Theme.bgElevated.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.border.opacity(0.86), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 22, x: 0, y: 14)
                .padding(.horizontal, 28)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .zIndex(20)
        }
    }

    private func voicePromptButton(
        title: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(isPrimary ? Theme.bg : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    isPrimary ? Theme.textPrimary : Theme.bgHover,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func dismissVoiceModelPrompt() {
        withAnimation(.easeInOut(duration: 0.16)) {
            showVoiceModelPrompt = false
        }
    }

    // MARK: - 聊天列表

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.chatSpacing) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .user(let msg):
                            UserBubble(
                                text: msg.content,
                                images: msg.images.compactMap(\.uiImage),
                                audios: msg.audios
                            )
                            .equatable()
                        case .response(let block):
                            let isLastItem = item.id == displayItems.last?.id
                            let isStreamingResponseText = engine.isProcessing && isLastItem
                            AIResponseView(
                                block: block,
                                expandedSkillIDs: expandedSkillIDs(for: block),
                                isThinkingExpanded: expandedThoughts.contains(block.id),
                                isStreamingResponseText: isStreamingResponseText,
                                onToggle: { toggleExpand($0) },
                                onToggleThinking: { toggleThinking(block.id) },
                                onRetry: isLastItem && canRetry(item: item, block: block)
                                    ? { Task { await engine.retryLastResponse() } }
                                    : nil,
                                followUpSuggestions: isLastItem ? followUpSuggestions(for: item, block: block) : [],
                                onFollowUpSuggestion: applyFollowUpSuggestion
                            )
                            .equatable()
                        }
                    }
                }
                .padding(.horizontal, Theme.chatPadH)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            // 任意点击 chatList → 清掉所有 AI 回复 UITextView 的选区。
            // simultaneousGesture 不会拦截内部按钮 (regenerate / expand skill 等) 的 tap,
            // 它们照样能触发, 我们的清选区动作只是并行跑一下。
            .simultaneousGesture(
                TapGesture().onEnded {
                    #if canImport(UIKit)
                    NotificationCenter.default.post(name: .dismissAssistantTextSelection, object: nil)
                    #endif
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in
                    if shouldAutoFollowChat {
                        shouldAutoFollowChat = false
                    }
                }
            )
            .task(id: scrollSignal) {
                let signal = scrollSignal
                await Task.yield()
                guard !Task.isCancelled else { return }
                handleScrollSignal(signal, proxy: proxy)
            }
            .onChange(of: isInputFocused) { _, focused in
                guard focused else { return }
                followKeyboardScroll(proxy, duration: 0.32)
            }
        }
    }

    @MainActor
    private func scrollTo(_ proxy: ScrollViewProxy, animated: Bool = true, duration: Double = 0.22) {
        guard let last = displayItems.last else { return }
        let lastID = last.id
        if animated {
            withAnimation(.easeOut(duration: duration)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    @MainActor
    private func handleScrollSignal(_ signal: ScrollSignal, proxy: ScrollViewProxy) {
        if signal.lastMessageRole == ChatMessage.Role.user.rawValue {
            shouldAutoFollowChat = true
            scrollTo(proxy, animated: true, duration: 0.18)
            return
        }

        guard shouldAutoFollowChat else { return }
        scrollTo(proxy, animated: !signal.isProcessing)
    }

    private func followKeyboardScroll(_ proxy: ScrollViewProxy, duration: Double) {
        keyboardScrollTask?.cancel()
        shouldAutoFollowChat = true
        keyboardScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollTo(proxy, animated: true, duration: duration)

            let midDelay = UInt64(max(duration * 0.45, 0.10) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: midDelay)
            guard !Task.isCancelled else { return }
            scrollTo(proxy, animated: true, duration: 0.16)

            let settleDelay = UInt64(max(duration * 0.35, 0.08) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: settleDelay)
            guard !Task.isCancelled else { return }
            scrollTo(proxy, animated: false)
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

    private func expandedSkillIDs(for block: ResponseBlock) -> Set<UUID> {
        let ids = block.skills.map(\.id)
        return Set(ids.filter { expandedSkills.contains($0) })
    }

    private func followUpSuggestions(for item: DisplayItem, block: ResponseBlock) -> [FollowUpSuggestion] {
        guard item.id == displayItems.last?.id else { return [] }
        guard !engine.isProcessing, !block.isThinking else { return [] }
        guard block.responseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return []
        }
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedImages.isEmpty,
              importedAudioSnapshot == nil,
              !audioCapture.isCapturing
        else {
            return []
        }

        return [
            FollowUpSuggestion(
                id: "expand",
                title: tr("展开说说", "Tell me more", "もっと詳しく"),
                prompt: tr("继续展开刚才的回答。", "Tell me more about your last answer.", "さっきの回答をもっと詳しく続けて。"),
                contextAct: .elaborateLastResult,
                targetItemID: item.id
            ),
            FollowUpSuggestion(
                id: "example",
                title: tr("举个例子", "Give an example", "例を挙げて"),
                prompt: tr("举一个具体例子。", "Give me a concrete example.", "具体的な例を一つ挙げて。"),
                contextAct: .elaborateLastResult,
                targetItemID: item.id
            ),
            FollowUpSuggestion(
                id: "summary",
                title: tr("总结三点", "Summarize", "3点に要約"),
                prompt: tr("把刚才的内容总结成三点。", "Summarize that in three points.", "さっきの内容を3点にまとめて。"),
                contextAct: .transformLastResult,
                targetItemID: item.id
            ),
            FollowUpSuggestion(
                id: "structure",
                title: tr("帮我结构化", "Structure it", "構造化して"),
                prompt: tr("把刚才的内容整理成结构化要点。", "Turn the previous answer into structured key points.", "さっきの内容を構造化した要点に整理して。"),
                contextAct: .transformLastResult,
                targetItemID: item.id
            )
        ]
    }

    private func applyFollowUpSuggestion(_ suggestion: FollowUpSuggestion) {
        showAttachmentTray = false
        isVoiceInputMode = false
        inputText = suggestion.prompt
        pendingContextFollowUpAct = suggestion.contextAct
        pendingContextFollowUpDraft = suggestion.prompt
        pendingContextFollowUpTargetItemID = suggestion.targetItemID
        isInputFocused = true
    }

    private func toggleThinkingMode() {
        guard engine.isModelLoaded else {
            showTransientTopNotice(
                hasNoUsableModel
                    ? tr("请先下载模型", "Download a model first", "モデルをダウンロードしてください")
                    : tr("模型加载中，请稍候", "Model is loading, please wait", "モデルを読み込み中です")
            )
            return
        }
        guard currentModelSupportsThinking else {
            showTransientTopNotice(tr("当前模型不支持思考模式", "Current model does not support Thinking mode", "現在のモデルは思考モードに非対応"))
            return
        }

        engine.config.enableThinking.toggle()
        engine.applySamplingConfig()
        showTransientTopNotice(
            engine.config.enableThinking ? tr("思考模式已开启", "Thinking mode on", "思考モードをオン") : tr("思考模式已关闭", "Thinking mode off", "思考モードをオフ")
        )
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

    // MARK: - topBar (v2: 对称轻量入口)
    //
    // 设计稿:左侧「历史状态 + 新会话」, 右侧「Think + 设置」; 中间只给状态提示。
    // 历史状态 chip 与 设置 gear 完全沿用 main 的逻辑/风格/位置 (历史最外、gear 最外);
    // 新会话 与 Think 是后加的, 统一成跟 gear 同一种安静线性图标语言。
    // 移除项 (跟用户当面讨论确认):
    //   - Gemma 4 E2B 模型名 → 进 settings 看
    //   - LIVE 按钮 → 中央 orb 已有 "进入 LIVE" 入口
    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                historyStatusButton
                newSessionTopBarButton
            }

            Spacer(minLength: 12)

            if let hint = activeTopStatusHint {
                Group {
                    if hint.id == "no-model-download" {
                        // "请先下载模型" 可点 → 跳设置(默认落在「模型」分组下载)
                        Button { showConfigurations = true } label: { topStatusHintView(hint) }
                            .buttonStyle(.plain)
                    } else {
                        topStatusHintView(hint)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                thinkingModeButton
                modelSwitchTopBarButton
            }
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.18), value: activeTopStatusHint)
        .animation(.easeInOut(duration: 0.18), value: engine.config.enableThinking)
        .animation(.easeInOut(duration: 0.18), value: currentModelSupportsThinking)
    }

    private var newSessionTopBarButton: some View {
        Button(action: {
            engine.flushPendingSessionSave()
            engine.startNewSession()
        }) {
            // + 包在圆角方块里 — 跟 Think 的 T 方块同款 chip (尺寸/圆角/描边一致),
            // 让左内 + 与右内 T 成对称一对; 它是一次性动作, 没有点亮态。
            // + 比 T 细 (细十字 vs 字母), 同 pt 看着偏轻; 放大到 14pt 补足视觉分量,
            // 让两个 chip 的"满度"对齐。
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .opacity(UIScale.gearIconOpacity)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.textSecondary.opacity(0.42), lineWidth: 1)
                )
                .frame(
                    width: UIScale.topStatusChipDiameter,
                    height: UIScale.topStatusChipDiameter
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tr("新会话", "New chat", "新しいチャット")))
    }

    private var historyStatusButton: some View {
        Button(action: {
            engine.flushPendingSessionSave()
            showHistory = true
        }) {
            ZStack {
                // 可见外圈缩到 24 (略大于 +/T chip 的 22), 不再像 28 那样偏大;
                // 外层仍保留 28 点击区, 跟其它三个图标的 tap / 垂直对齐一致。
                Circle()
                    .fill(Theme.bgHover.opacity(UIScale.topStatusChipBgOpacity))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(engine.isModelLoaded ? Theme.accentMuted : Theme.textTertiary)
                    .frame(
                        width: UIScale.topStatusChipDotSize,
                        height: UIScale.topStatusChipDotSize
                    )
            }
            .frame(
                width: UIScale.topStatusChipDiameter,
                height: UIScale.topStatusChipDiameter
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tr("历史记录", "History", "履歴")))
    }

    private var thinkingModeButton: some View {
        // 没模型(没加载)时 T 也置灰、看着不可点;点了由 toggleThinkingMode 提示"请先下载模型"。
        let isUsable = currentModelSupportsThinking && engine.isModelLoaded
        let isActive = isUsable && engine.config.enableThinking

        // 字母 T 包在圆角方块里 — 零噪点的字母, 跟 gear/pencil 同属"低细节"一家;
        // 壳呼应 app 内「思考」块的 accentSubtle 圆角方块 (ResponseUI). 品牌色只在开启时点亮。
        let tint: Color = isUsable
            ? (isActive ? Theme.accentMuted : Theme.textSecondary)
            : Theme.textTertiary
        let glyphOpacity: Double = isUsable ? (isActive ? 0.96 : UIScale.gearIconOpacity) : 0.36

        return Button(action: toggleThinkingMode) {
            Text("T")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .opacity(glyphOpacity)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Theme.accentSubtle : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.clear : tint.opacity(isUsable ? 0.42 : 0.24),
                            lineWidth: 1
                        )
                )
                .frame(
                    width: UIScale.topStatusChipDiameter,
                    height: UIScale.topStatusChipDiameter
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tr("思考模式", "Thinking mode", "思考モード")))
        .accessibilityValue(Text(isActive ? tr("已开启", "On", "オン") : tr("已关闭", "Off", "オフ")))
    }

    private var modelSwitchTopBarButton: some View {
        // M chip 两态完全对齐 Think 的 T:有模型 = 点亮(accentMuted 字 + accentSubtle 底、无边),
        // 没模型 = 未点亮(textSecondary 字 + 描边)。
        let hasModel = engine.isModelLoaded
        let tint: Color = hasModel ? Theme.accentMuted : Theme.textSecondary
        let glyphOpacity: Double = hasModel ? 0.96 : UIScale.gearIconOpacity

        return Button(action: { showModelSwitcher = true }) {
            Text("M")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .opacity(glyphOpacity)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hasModel ? Theme.accentSubtle : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(hasModel ? Color.clear : tint.opacity(0.42), lineWidth: 1)
                )
                .frame(
                    width: UIScale.topStatusChipDiameter,
                    height: UIScale.topStatusChipDiameter
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tr("切换模型", "Switch model", "モデル切替")))
        .accessibilityValue(Text(hasModel ? tr("已选择模型", "Model selected", "モデル選択済み") : tr("未选择模型", "No model", "モデル未選択")))
    }

    private var activeTopStatusHint: TopStatusHint? {
        modelLifecycleTopStatusHint ?? transientTopNotice
    }

    private var modelLifecycleTopStatusHint: TopStatusHint? {
        if let downloadHint = activeModelDownloadHint {
            return downloadHint
        }

        switch engine.coordinator.sessionState {
        case .loading(let modelID, let phase):
            return .init(
                id: "runtime-loading-\(modelID)-\(String(describing: phase))",
                text: runtimeLoadingText(for: phase),
                symbolName: nil,
                showsProgress: true,
                isWarning: false
            )
        case .switching:
            return .init(
                id: "runtime-switching",
                text: tr("正在切换模型", "Switching model", "モデルを切り替え中"),
                symbolName: nil,
                showsProgress: true,
                isWarning: false
            )
        case .unloading:
            return .init(
                id: "runtime-unloading",
                text: tr("正在释放模型", "Unloading model", "モデルを解放中"),
                symbolName: nil,
                showsProgress: true,
                isWarning: false
            )
        default:
            // 首次进来 / 没有可用模型 (选中的本地模型没装、也没配对远程) → 提示下载
            if hasNoUsableModel {
                return .init(
                    id: "no-model-download",
                    text: tr("请先下载模型", "Download a model first", "モデルをダウンロードしてください"),
                    symbolName: "arrow.down.circle",
                    showsProgress: false,
                    isWarning: false
                )
            }
            return nil
        }
    }

    /// 没有任何可用模型:没加载、且当前选中的不是已装本地、也不是已配对远程模型。
    private var hasNoUsableModel: Bool {
        if engine.isModelLoaded { return false }
        let id = engine.config.selectedModelID
        if id.hasPrefix("remote::") { return false }   // 远程模型:配对即可用
        let state = engine.installer.installState(for: id)
        return state != .downloaded && state != .bundled
    }

    private var activeModelDownloadHint: TopStatusHint? {
        let selectedModel = engine.catalog.selectedModel
        let selectedState = engine.installer.installState(for: selectedModel.id)
        return downloadHint(for: selectedModel, state: selectedState)
    }

    private func downloadHint(for model: ModelDescriptor, state: ModelInstallState) -> TopStatusHint? {
        switch state {
        case .checkingSource:
            return .init(
                id: "download-checking-\(model.id)",
                text: tr("正在准备下载模型", "Preparing model download", "モデルのダウンロードを準備中"),
                symbolName: nil,
                showsProgress: true,
                isWarning: false
            )
        case .downloading(let completedFiles, let totalFiles, _):
            return .init(
                id: "download-active-\(model.id)",
                text: modelDownloadText(
                    progress: engine.installer.downloadProgress[model.id],
                    completedFiles: completedFiles,
                    totalFiles: totalFiles
                ),
                symbolName: nil,
                showsProgress: true,
                isWarning: false
            )
        default:
            return nil
        }
    }

    private func modelDownloadText(
        progress: DownloadProgress?,
        completedFiles: Int,
        totalFiles: Int
    ) -> String {
        if let fraction = progress?.fractionCompleted {
            let percent = max(0, min(99, Int((fraction * 100).rounded(.down))))
            return tr("正在下载模型 \(percent)%", "Downloading model \(percent)%", "モデルをダウンロード中 \(percent)%")
        }
        if totalFiles > 1 {
            return tr("正在下载模型 \(completedFiles)/\(totalFiles)", "Downloading model \(completedFiles)/\(totalFiles)", "モデルをダウンロード中 \(completedFiles)/\(totalFiles)")
        }
        return tr("正在下载模型", "Downloading model", "モデルをダウンロード中")
    }

    private func runtimeLoadingText(for phase: LoadPhase) -> String {
        switch phase {
        case .preparingAccelerator:
            return tr("正在准备模型", "Preparing model", "モデルを準備中")
        case .loadingWeights:
            return tr("正在加载模型", "Loading model", "モデルを読み込み中")
        case .openingSession:
            return tr("正在打开会话", "Opening session", "セッションを開いています")
        }
    }

    private func topStatusHintView(_ hint: TopStatusHint) -> some View {
        HStack(spacing: 6) {
            if hint.showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
                    .tint(hint.isWarning ? Theme.accent : Theme.textSecondary)
                    .frame(width: 12, height: 12)
            } else if let symbolName = hint.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            }

            Text(hint.text)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(hint.isWarning ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: UIScale.topStatusChipDiameter)
        .frame(maxWidth: 230)
        .background(Theme.bgHover.opacity(0.58), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.border.opacity(0.42), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .id(hint.id)
    }

    private func handleInstallStateChange(
        from oldStates: [String: ModelInstallState],
        to newStates: [String: ModelInstallState]
    ) {
        for (modelID, newState) in newStates where oldStates[modelID] != newState {
            guard !newState.isTransientInstallState else { continue }
            if case .failed = newState {
                showTransientTopNotice(
                    tr("模型下载失败", "Model download failed", "モデルのダウンロードに失敗"),
                    symbolName: "exclamationmark.circle",
                    isWarning: true
                )
            }
        }
    }

    private func handleRuntimeStateChange(_ state: RuntimeSessionState) {
        if case .failed = state {
            showTransientTopNotice(
                tr("模型加载失败", "Model load failed", "モデルの読み込みに失敗"),
                symbolName: "exclamationmark.circle",
                isWarning: true
            )
        }
    }

    private func showTransientTopNotice(
        _ text: String,
        symbolName: String = "info.circle",
        isWarning: Bool = false,
        durationNanoseconds: UInt64 = 2_800_000_000
    ) {
        topNoticeDismissTask?.cancel()

        let notice = TopStatusHint(
            id: "notice-\(UUID().uuidString)",
            text: text,
            symbolName: symbolName,
            showsProgress: false,
            isWarning: isWarning
        )
        transientTopNotice = notice

        topNoticeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard !Task.isCancelled, transientTopNotice == notice else { return }
            transientTopNotice = nil
        }
    }

    // MARK: - 欢迎页

    // MARK: - welcomeView (centered in middle content area)
    //
    // BrandMark 跟 chatList 共享 root VStack 中间的 ZStack 容器, 在容器内**居中**。
    // 容器高度 = 屏幕高 - topBar - composerDock, 键盘升起时 SwiftUI 默认避让会
    // 压缩这个容器, BrandMark 跟着压缩后的容器中心走 — 不会被推出可见区, 也
    // 不会再跟键盘联动出错。
    //
    // 历史: 之前用 `.padding(.top, welcomeBrandTopOffset) + alignment: .top` 是
    // 为了对抗旧 ZStack + safeAreaInset + 手写 keyboardLift 方案下的漂移; 那一
    // 整套方案现在已经全部删除, 不需要顶部固定偏移这种 workaround 了。
    private var welcomeView: some View {
        BrandMarkView(size: UIScale.orbSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
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
                        pendingContextFollowUpAct = nil
                        pendingContextFollowUpDraft = nil
                        pendingContextFollowUpTargetItemID = nil
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

    private var composerDock: some View {
        VStack(spacing: 0) {
            composerAttachmentsPanel
            if shouldShowStarterActions {
                starterActionsView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
            }
            if showAttachmentTray {
                HStack {
                    attachmentTray
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.inputPadH + 10)
                .padding(.bottom, 8)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading))
                ))
            }
            inputBar
        }
        .background(alignment: .bottom) {
            inputAreaBackground
        }
        .animation(.easeOut(duration: 0.2), value: showAttachmentTray)
    }

    private var starterActionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(starterActions) { action in
                Button {
                    applyStarterAction(action)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: action.symbolName)
                            .font(.system(size: 15.5, weight: .regular))
                            .foregroundStyle(Theme.textSecondary.opacity(0.78))
                            .frame(width: 22, height: 22)

                        Text(action.title)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(Theme.textSecondary.opacity(0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .frame(height: 34, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.inputPadH + 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyStarterAction(_ action: StarterAction) {
        showAttachmentTray = false
        inputText = action.prompt
        pendingContextFollowUpAct = nil
        pendingContextFollowUpDraft = nil
        pendingContextFollowUpTargetItemID = nil
        isVoiceInputMode = false
        isInputFocused = true

        if action.opensPhotoPicker {
            #if canImport(PhotosUI)
            showPhotoPicker = true
            #endif
        }
    }

    // MARK: - 输入栏

    /// 只有"录音已结束 + 有有效音频"才算完成草稿
    private var hasCompletedDraft: Bool {
        !audioCapture.isCapturing && audioCapture.latestSnapshot() != nil
    }

    private var attachmentTray: some View {
        HStack(spacing: 6) {
            #if canImport(PhotosUI)
            attachmentTrayButton(
                title: tr("照片", "Photo", "写真"),
                systemImage: "photo"
            ) {
                showAttachmentTray = false
                showPhotoPicker = true
            }
            #endif

            attachmentTrayButton(
                title: audioCapture.isCapturing && captureOrigin == .menu
                    ? tr("停止", "Stop", "停止")
                    : tr("录音", "Record", "録音"),
                systemImage: audioCapture.isCapturing && captureOrigin == .menu
                    ? "stop.fill"
                    : "waveform"
            ) {
                showAttachmentTray = false
                captureOrigin = .menu
                Task { _ = await audioCapture.toggleCapture() }
            }

            attachmentTrayButton(
                title: tr("文件", "File", "ファイル"),
                systemImage: "doc"
            ) {
                showAttachmentTray = false
                showFilePicker = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            Theme.bgElevated.opacity(0.78),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.border.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
    }

    private func attachmentTrayButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
            }
            .foregroundStyle(Theme.textSecondary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Theme.bgHover.opacity(0.34),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - inputBar (v2: 胶囊形容器内嵌 3 个子元素)
    //
    // 设计稿:整个输入框是一个 white capsule,内部 [+] | text | [waveform/send]
    // 三个子元素都"贴着"胶囊内壁,而不是各自独立按钮并排。左右按钮 chip 形
    // (圆形浅底),输入框无自身背景。
    private var inputAreaBackground: some View {
        Group {
            if !engine.messages.isEmpty {
                LinearGradient(
                    stops: [
                        .init(color: Theme.bg.opacity(colorScheme == .dark ? 0.10 : 0.16), location: 0),
                        .init(color: Theme.bg.opacity(colorScheme == .dark ? 0.82 : 0.72), location: 0.36),
                        .init(color: Theme.bg.opacity(1), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: UIScale.chipTextSpacing) {
            // 左:+ 附件菜单 — 圆形 chip
            Button {
                isInputFocused = false
                showAttachmentTray.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: UIScale.chipIconSize, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: UIScale.chipDiameter, height: UIScale.chipDiameter)
                    .background(
                        showAttachmentTray ? Theme.bgHover.opacity(0.88) : Theme.bgHover,
                        in: Circle()
                    )
                    .rotationEffect(.degrees(showAttachmentTray ? 45 : 0))
                    .animation(.easeInOut(duration: 0.18), value: showAttachmentTray)
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

            // 中间槽常驻, 内部状态淡入淡出, 避免 TextField / hold-to-talk sibling 硬切。
            ZStack(alignment: .leading) {
                if isVoiceInputMode {
                    holdToTalkButton
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    composerTextField
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.18), value: isVoiceInputMode)

            // 右侧 mic + LIVE 视觉分级:
            //   mic = 内嵌图标 (无 chip 底), 辅助输入开关, "藏在文字旁"
            //   LIVE = 圆 chip, 主操作入口, "落在胶囊右端"
            // 两者收成一簇(更紧的间距), 跟左侧 textfield 仍隔 chipTextSpacing.
            HStack(spacing: UIScale.trailingClusterSpacing) {
                modeToggleButton
                trailingDynamicButton
            }
        }
        .padding(.horizontal, UIScale.chipInnerMargin)
        .padding(.vertical, (UIScale.pillHeight - UIScale.chipDiameter) / 2)
        .background(Theme.bgElevated, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.borderSubtle.opacity(colorScheme == .dark ? 0.56 : 0.18), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0 : 0.035),
            radius: colorScheme == .dark ? 0 : 10,
            x: 0,
            y: colorScheme == .dark ? 0 : 3
        )
        .padding(.horizontal, UIScale.pillHorizontalMargin)
        .padding(.vertical, UIScale.inputBarBottomGap)
    }

    private var composerTextField: some View {
        ZStack(alignment: .leading) {
            if shouldShowComposerPromptCarousel {
                ComposerPromptCarousel(prompts: composerSkillPrompts)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if inputText.isEmpty {
                Text(composerSkillPrompts.first ?? tr("问点什么…", "Ask anything...", "なんでも聞いてください…"))
                    .font(.system(size: UIScale.pillTextSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.textTertiary.opacity(0.62))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            #if os(macOS)
            TextField("", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pillTextSize, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { Task { await send() } }
            #else
            composerTextMirror

            TextField("", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: UIScale.pillTextSize, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .focused($isInputFocused)
                .onSubmit { Task { await send() } }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var composerTextMirror: some View {
        Text(inputText.isEmpty ? " " : inputText)
            .font(.system(size: UIScale.pillTextSize, weight: .regular, design: .rounded))
            .lineLimit(1...5)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    // MARK: - 输入栏右侧按钮组 (mic 模式切换 + 动态主操作)
    //
    // 设计:右侧两枚 chip 并排.
    //   modeToggleButton: 永远在原位, 切换 "键盘 ⇄ 语音输入" (mic ↔ keyboard).
    //   trailingDynamicButton: 主操作动态, idle → LIVE entry (waveform), 有文字 → send,
    //     生成中 → stop.
    // LIVE 跟 voice 是平行的两条音频路径 — LIVE 是实时对话模式 (走 orb), voice 是
    // 单条按住说话 (走 ASR→文字→当前对话). 用户在两者间显式选择.

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
                bgColor: Theme.accentSubtle,
                fgColor: Theme.accentMuted,
                action: { engine.cancelActiveGeneration() }
            )
        }
        if hasComposedInput {
            // chip 保持中性灰, 只 icon 从 waveform 变成 arrow.up.
            // 形态变化驱动状态语义, 不靠 brand color — Arc/Linear/Apple Music 同款逻辑.
            // brand color 只留给 hero element (orb), chip 永远克制.
            return .init(
                icon: "arrow.up",
                bgColor: Theme.bgHover,
                fgColor: Theme.textSecondary,
                action: {
                    guard canSend else {
                        let message = tr("请先下载模型", "Download a model first", "先にモデルをダウンロード")
                        showTransientTopNotice(message)
                        return
                    }
                    Task { await send() }
                }
            )
        }
        // idle 或 语音模式 → LIVE entry. 不管中央是文字框还是 hold-to-talk,
        // LIVE 都在原位等待用户点击进入实时模式.
        return .init(
            icon: "waveform",
            bgColor: Theme.bgHover,
            fgColor: Theme.textSecondary,
            action: { enterLiveMode() }
        )
    }

    /// 右侧 mic / keyboard 切换按钮 — 内嵌图标 (无 chip 底), 辅助开关.
    /// 视觉上"贴着文字", 不抢右端主操作 (LIVE) 的位置.
    /// idle:     mic — 点击进语音输入模式 (中央换成 holdToTalk)
    /// 语音模式: keyboard — 点击回键盘模式
    private var modeToggleButton: some View {
        let icon = isVoiceInputMode ? "keyboard" : "mic"
        let isEnteringVoiceDisabled = !isVoiceInputMode && !liveVoiceModelsReady
        let action: () -> Void = isVoiceInputMode
            ? { exitVoiceInputMode() }
            : { enterVoiceInputMode() }
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: UIScale.waveformIconSize, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .symbolReplaceTransition()
                .opacity(isEnteringVoiceDisabled ? 0.24 : 0.55)  // 比 LIVE chip 更弱, 强化"辅助" 而非 "主操作"
                .frame(width: UIScale.chipDiameter, height: UIScale.chipDiameter)
                .contentShape(Rectangle())  // 保持 chip 大小的点击区
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isVoiceInputMode)
        .animation(.easeInOut(duration: 0.15), value: liveVoiceModelsReady)
    }

    private var trailingDynamicButton: some View {
        let style = trailingButtonStyle
        // waveform = LIVE entry 是 idle 辅助态, icon 17pt + opacity 0.68 让它"浮起来";
        // send / stop 是行动态, 用 18pt 满 opacity 强调.
        let isIdleAux = !hasComposedInput && !canCancelGeneration
        let iconSize: CGFloat = isIdleAux ? UIScale.waveformIconSize : UIScale.chipIconSize
        // LIVE 模型未就绪时, 进一步压暗 (0.68 → 0.32) 暗示不可用。
        let liveDimmed = isIdleAux && !canEnterLiveMode
        let iconOpacity: Double = isIdleAux
            ? (liveDimmed ? 0.32 : UIScale.waveformIconOpacity)
            : 1.0
        return Button(action: style.action) {
            Image(systemName: style.icon)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(style.fgColor)
                .symbolReplaceTransition()
                .opacity(iconOpacity)
                .frame(width: UIScale.chipDiameter, height: UIScale.chipDiameter)
                .background(style.bgColor, in: Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: hasComposedInput)
        .animation(.easeInOut(duration: 0.15), value: canCancelGeneration)
        .animation(.easeInOut(duration: 0.15), value: canEnterLiveMode)
    }

    /// 进入语音模式:检查语音模型, 预热, 切换 UI 状态.
    private func enterVoiceInputMode() {
        // 切到语音模式前先检查 LIVE 语音模型是否完整, 避免用户进入后才发现不能用。
        if !liveVoiceModelsReady {
            showVoiceModelsRequiredPrompt()
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
            ? tr("正在准备...", "Preparing...", "準備中...")
            : (isHoldRecording ? tr("松开 结束", "Release to Stop", "離して終了") : tr("按住 说话", "Hold to Talk", "押して話す"))
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
                Text(importedAudioFilename ?? tr("音频文件", "Audio File", "音声ファイル"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(String(format: tr("%.1f 秒 · %d kHz", "%.1f s · %d kHz", "%.1f 秒 · %d kHz"), snapshot.duration, Int(snapshot.sampleRate / 1000)))
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

    private var hasComposedInput: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
            || !selectedImages.isEmpty
            || hasCompletedDraft
            || importedAudioSnapshot != nil
    }

    private var shouldShowComposerPromptCarousel: Bool {
        inputText.isEmpty
            && !hasComposedInput
            && engine.messages.isEmpty
            && !engine.isProcessing
            && !engine.isModelGenerating
    }

    private var canSend: Bool {
        hasComposedInput && !engine.isProcessing && engine.isModelReady
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
        engine.isModelReady && currentModelCapabilities.supportsLive && liveVoiceModelsReady
    }

    private var liveVoiceModelsReady: Bool {
        LiveModelDefinition.isAvailable
    }

    /// 当前选中模型是否支持 thinking。顶部 T 始终保留位置, 但非 thinking 模型置灰。
    private var currentModelSupportsThinking: Bool {
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
        let lastDisplayItemID = displayItems.last?.id
        let forcedContextAct = pendingContextFollowUpDraft == text
            && pendingContextFollowUpTargetItemID == lastDisplayItemID
            ? pendingContextFollowUpAct
            : nil
        pendingContextFollowUpAct = nil
        pendingContextFollowUpDraft = nil
        pendingContextFollowUpTargetItemID = nil
        showAttachmentTray = false
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
        await engine.processInput(text, images: images, audio: audioSnapshot, forcedContextAct: forcedContextAct)
    }

    private func enterLiveMode() {
        guard liveVoiceModelsReady else {
            showVoiceModelsRequiredPrompt()
            return
        }
        guard engine.isModelReady else {
            showTransientTopNotice(tr("请先下载模型", "Download a model first", "先にモデルをダウンロード"))
            return
        }
        guard currentModelCapabilities.supportsLive else {
            showTransientTopNotice(tr("当前模型不支持 LIVE", "Current model does not support LIVE", "現在のモデルは LIVE に非対応"))
            return
        }

        showLiveMode = true

        engine.cancelActiveGeneration()
        if audioCapture.isCapturing {
            _ = audioCapture.stopCapture()
        }
        _ = audioCapture.consumeLatestSnapshot()
        isInputFocused = false
        showAttachmentTray = false
    }

    private func showVoiceModelsRequiredPrompt() {
        withAnimation(.easeInOut(duration: 0.16)) {
            showVoiceModelPrompt = true
        }
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
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — 音频解码失败]", "[Attachment: \(filename) — audio decode failed]", "[添付: \(filename) — 音声のデコードに失敗]")
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
                        inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — PDF 无法提取文字]", "[Attachment: \(filename) — couldn't extract text from PDF]", "[添付: \(filename) — PDF からテキストを抽出できません]")
                    } else {
                        // 限制长度避免超出上下文
                        let maxChars = 4000
                        let content = trimmed.count > maxChars
                            ? String(trimmed.prefix(maxChars)) + tr("\n...(已截断)", "\n...(truncated)", "\n...(省略)")
                            : trimmed
                        inputText += (inputText.isEmpty ? "" : "\n") + tr("以下是 \(filename) 的内容:\n\(content)", "Contents of \(filename):\n\(content)", "\(filename) の内容:\n\(content)")
                    }
                    print("[UI] PDF imported: \(filename) (\(pdfDoc.numberOfPages) pages)")
                } else {
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename) — PDF 打开失败]", "[Attachment: \(filename) — couldn't open PDF]", "[添付: \(filename) — PDF を開けません]")
                }
            }
            // 文本文件 → 直接读取
            else if ["txt", "md", "json", "csv", "xml", "html", "swift", "py", "js"].contains(ext) {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let maxChars = 4000
                    let trimmed = content.count > maxChars
                        ? String(content.prefix(maxChars)) + tr("\n...(已截断)", "\n...(truncated)", "\n...(省略)")
                        : content
                    inputText += (inputText.isEmpty ? "" : "\n") + tr("以下是 \(filename) 的内容:\n\(trimmed)", "Contents of \(filename):\n\(trimmed)", "\(filename) の内容:\n\(trimmed)")
                    print("[UI] Text file imported: \(filename)")
                } catch {
                    print("[UI] Failed to read text file: \(error)")
                }
            }
            // 其他 → 标注文件名
            else {
                inputText += (inputText.isEmpty ? "" : "\n") + tr("[附件: \(filename)]", "[Attachment: \(filename)]", "[添付: \(filename)]")
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


private struct ComposerPromptCarousel: View {
    let prompts: [String]
    @State private var index = 0

    private var promptIdentity: String {
        prompts.joined(separator: "\u{1F}")
    }

    private var currentPrompt: String {
        guard !prompts.isEmpty else { return tr("问点什么…", "Ask anything...", "なんでも聞いてください…") }
        return prompts[index % prompts.count]
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(currentPrompt)
                .id("\(promptIdentity)-\(index)")
                .font(.system(size: UIScale.pillPlaceholderTextSize, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.textTertiary.opacity(0.52))
                .lineLimit(1)
                .truncationMode(.tail)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.chipDiameter, alignment: .leading)
        .clipped()
        .task(id: promptIdentity) {
            await MainActor.run { index = 0 }
            guard prompts.count > 1 else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_700_000_000)
                } catch {
                    return
                }

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.38)) {
                        index = (index + 1) % prompts.count
                    }
                }
            }
        }
    }
}


// LiveModeView has been extracted to LiveModeUI.swift

private struct SessionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var engine: AgentEngine
    @State private var showSettings = false

    private var dateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: LanguageService.shared.current.isJapanese ? "ja" : (LanguageService.shared.current.isChinese ? "zh-Hans" : "en"))
        formatter.unitsStyle = .short
        return formatter
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                historyTopBar

                Group {
                    if sessions.isEmpty {
                        emptyState
                    } else {
                        historyList
                    }
                }
                .padding(.top, 46)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .fullScreenCover(isPresented: $showSettings) {
            ConfigurationsView(engine: engine)
        }
    }

    private var sessions: [ChatSessionSummary] {
        engine.sessionStore.sessionSummaries
    }

    private var historyTopBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.bgHover.opacity(UIScale.topStatusChipBgOpacity))
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(0.58)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(tr("历史记录", "History", "履歴"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .opacity(0.72)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: UIScale.gearIconSize, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(UIScale.gearIconOpacity)
                    .frame(
                        width: UIScale.topStatusChipDiameter,
                        height: UIScale.topStatusChipDiameter
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(tr("设置", "Settings", "設定")))
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
    }

    private var historyList: some View {
        List {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                VStack(spacing: 0) {
                    sessionRow(session)

                    if index < sessions.count - 1 {
                        Rectangle()
                            .fill(Theme.borderSubtle)
                            .frame(height: 1)
                            .opacity(0.9)
                            .padding(.vertical, 18)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        engine.deleteSession(id: session.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text(tr("删除", "Delete", "削除")))
                    .tint(Theme.accentMuted)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        engine.deleteSession(id: session.id)
                    } label: {
                        Label(tr("删除", "Delete", "削除"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private func sessionRow(_ session: ChatSessionSummary) -> some View {
        Button {
            engine.loadSession(id: session.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if session.id == engine.sessionStore.currentSessionID {
                        Circle()
                            .fill(Theme.accentMuted)
                            .frame(width: 5, height: 5)
                            .opacity(0.72)
                    }

                    Spacer(minLength: 0)
                }

                Text(session.preview)
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(0.9)
                    .lineLimit(2)

                Text(dateFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("暂无历史", "No History", "履歴なし"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Button {
                engine.startNewSession()
                dismiss()
            } label: {
                Text(tr("新会话", "New Chat", "新しいチャット"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accentMuted)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34)
    }
}

// MARK: - 用户气泡

struct UserBubble: View, Equatable {
    let text: String
    let images: [UIImage]
    let audios: [ChatAudioAttachment]

    static func == (lhs: UserBubble, rhs: UserBubble) -> Bool {
        lhs.text == rhs.text
            && lhs.images.count == rhs.images.count
            && lhs.audios.map(\.id) == rhs.audios.map(\.id)
    }

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
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(Theme.userText)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Theme.userBubble,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Theme.userBubbleStroke, lineWidth: 1)
                        )
                }
            }
        }
    }
}

// Audio, Response, and Shared UI components have been extracted to:
// - AudioUI.swift
// - ResponseUI.swift
// - SharedUI.swift

// MARK: - 模型切换弹层 (聊天右上 cpu 图标 → 本地/远程已就绪模型, 点即切换)
//
// 只列「现在能用的」:已下载的本地模型 + 已配对 Mac 的远程模型。下载/配对走设置页,
// 这里不放跳转入口。视觉沿用 Theme,不套 stock List/Form。

private struct ModelSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    var engine: AgentEngine

    /// 已就绪的本地模型 (已下载;artifactPath 存在才算可切)。
    private var localModels: [ModelDescriptor] {
        engine.availableModels.filter {
            !$0.id.hasPrefix("remote::") && engine.installer.artifactPath(for: $0) != nil
        }
    }

    /// 已配对 Mac 的远程模型 (refreshRemoteModels 灌进 catalog 的)。
    private var remoteModels: [ModelDescriptor] {
        engine.availableModels.filter { $0.id.hasPrefix("remote::") }
    }

    private var isEmpty: Bool { localModels.isEmpty && remoteModels.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(tr("切换模型", "Switch Model", "モデル切替"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .opacity(0.72)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                if isEmpty {
                    emptyHint
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !localModels.isEmpty {
                                section(tr("本地模型", "Local", "ローカル"), models: localModels)
                            }
                            if !remoteModels.isEmpty {
                                section(tr("远程模型", "Remote", "リモート"), models: remoteModels)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .onAppear { Task { await engine.refreshRemoteModels() } }
    }

    private func section(_ title: String, models: [ModelDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 8)

            ForEach(Array(models.enumerated()), id: \.element.id) { idx, model in
                modelRow(model)
                if idx < models.count - 1 {
                    Rectangle()
                        .fill(Theme.borderSubtle)
                        .frame(height: 1)
                        .opacity(0.9)
                }
            }
        }
    }

    private func modelRow(_ model: ModelDescriptor) -> some View {
        let isCurrent = model.id == engine.config.selectedModelID
        let subtitle = rowSubtitle(model)
        return Button {
            select(model)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(model))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentMuted)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 远程行只显示模型名 (从 id "remote::<macID>::<model>" 取 model,去掉机器名);本地用 displayName。
    private func rowTitle(_ model: ModelDescriptor) -> String {
        if model.id.hasPrefix("remote::") {
            return LANConnectionManager.remoteDisplayParts(for: model).title
        }
        return model.displayName
    }

    private func rowSubtitle(_ model: ModelDescriptor) -> String? {
        guard model.id.hasPrefix("remote::") else { return nil }
        return LANConnectionManager.remoteDisplayParts(for: model).subtitle
    }

    private var emptyHint: some View {
        Text(tr(
            "还没有可用模型,去设置里下载或连接 Mac",
            "No models yet — download one or connect a Mac in Settings",
            "モデルがありません。設定でダウンロード、または Mac に接続してください"
        ))
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func select(_ model: ModelDescriptor) {
        guard model.id != engine.config.selectedModelID else { dismiss(); return }
        engine.config.selectedModelID = model.id
        engine.reloadModel()   // 持久化 + reconcile + coordinator.load(选中模型)
        dismiss()
    }
}
