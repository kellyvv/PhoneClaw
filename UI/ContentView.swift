import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 主入口

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = AgentEngine()
    @State private var inputText = ""
    @State private var selectedImages: [UIImage] = []
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showConfigurations = false
    @State private var showSkillsManager = false
    /// 记录每个 skill 卡片的展开状态（key = SkillCard.id）
    @State private var expandedSkills: Set<UUID> = []
    @FocusState private var isInputFocused: Bool

    private var displayItems: [DisplayItem] {
        buildDisplayItems(from: engine.messages, isProcessing: engine.isProcessing)
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
            guard newPhase != .active else { return }
            engine.cancelActiveGeneration()
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
                            UserBubble(text: msg.content, images: msg.images.compactMap(\.uiImage))
                        case .response(let block):
                            AIResponseView(
                                block: block,
                                expandedSkills: expandedSkills,
                                onToggle: { toggleExpand($0) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.chatPadH)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .onChange(of: engine.messages.count) { scrollTo(proxy) }
            .onChange(of: engine.isProcessing) { scrollTo(proxy) }
        }
    }

    private func scrollTo(_ proxy: ScrollViewProxy) {
        guard let last = displayItems.last else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(last.id, anchor: .bottom)
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

    private var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespaces).isEmpty || !selectedImages.isEmpty)
        && !engine.isProcessing && engine.llm.isLoaded
    }

    private func send() async {
        let text = inputText
        let images = selectedImages
        inputText = ""
        selectedImages = []
        selectedPhotoItem = nil
        isInputFocused = false
        await engine.processInput(text, images: images)
    }

    @MainActor
    private func loadSelectedPhoto() async {
        #if canImport(PhotosUI)
        guard let selectedPhotoItem else { return }
        do {
            if let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImages = [image]
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
    var body: some View {
        HStack {
            Spacer(minLength: Theme.bubbleMinSpacer)
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
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
    let onToggle: (UUID) -> Void

    private var hasSkill: Bool { !block.skills.isEmpty }
    private var isPureThinking: Bool { !hasSkill && block.responseText == nil && block.isThinking }

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
