import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Configurations 弹窗（iOS 版，适配 Theme 暖色系）

struct ConfigurationsView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedTab = 0  // 0=Model Settings, 1=System Prompt, 2=Permissions
    @State private var showSkillsManager = false
    @State private var showPrivacyPolicy = false

    // 本地编辑状态（确认后才应用）
    @State private var selectedModelID = ModelDescriptor.defaultModel.id
    @State private var preferredBackend: String = ModelConfig.defaultPreferredBackend   // "gpu" / "cpu"
    @State private var enableSpeculativeDecoding: Bool = false
    @State private var systemPrompt: String = ""
    @State private var permissionStatuses: [AppPermissionKind: AppPermissionStatus] = [:]
    @State private var requestingPermission: AppPermissionKind?
    @State private var liveDownloader = LiveModelStore()
    @State private var didLoadCurrentSettings = false
    @State private var activeInfoTopic: SettingsInfoTopic?
    @State private var modelSelectionMessage: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                settingsTopBar

                settingsTabs
                    .padding(.top, 34)

                Group {
                    if selectedTab == 0 {
                        modelConfigsTab
                    } else if selectedTab == 1 {
                        systemPromptTab
                    } else {
                        permissionsTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 28)

                settingsBottomBar
            }

            if let topic = activeInfoTopic {
                InfoDisclosureOverlay(
                    title: topic.title,
                    message: topic.message
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeInfoTopic = nil
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                .zIndex(10)
            }
        }
        .onAppear {
            guard !didLoadCurrentSettings else { return }
            didLoadCurrentSettings = true
            loadCurrentSettings()
        }
        .fullScreenCover(isPresented: $showSkillsManager) {
            SkillsManagerView(engine: engine)
        }
        .fullScreenCover(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            engine.installer.refreshInstallStates()
            liveDownloader.refreshState()
            refreshPermissionStatuses()
        }
        #endif
    }

    // MARK: - Tab 按钮

    private var settingsTopBar: some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                ZStack {
                    Circle()
                        .fill(SettingsStyle.controlFill)
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SettingsStyle.secondary)
                        .opacity(0.58)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(tr("模型设置", "Model Settings"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsStyle.muted)

            Spacer()

            Color.clear
                .frame(
                    width: UIScale.topStatusChipDiameter,
                    height: UIScale.topStatusChipDiameter
                )
        }
        .padding(.horizontal, Theme.inputPadH)
        .padding(.vertical, 10)
    }

    private var settingsTabs: some View {
        HStack(spacing: 8) {
            tabButton(tr("模型", "Model"), tag: 0)
            tabButton(tr("提示词", "Prompt"), tag: 1)
            tabButton(tr("权限", "Access"), tag: 2)
        }
        .padding(.horizontal, 34)
    }

    private var settingsBottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelSelectionMessage ?? " ")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SettingsStyle.danger)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .opacity(modelSelectionMessage == nil ? 0 : 1)
                .frame(height: 16, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                Button {
                    showSkillsManager = true
                } label: {
                    Label(tr("技能", "Skills"), systemImage: "puzzlepiece.extension")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SettingsStyle.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    showPrivacyPolicy = true
                } label: {
                    Label(tr("隐私", "Privacy"), systemImage: "hand.raised")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SettingsStyle.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(tr("取消", "Cancel")) {
                    dismiss()
                }
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(SettingsStyle.secondary)

                Button {
                    if applySettings() {
                        dismiss()
                    }
                } label: {
                    Text(tr("确定", "OK"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsStyle.onPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(SettingsStyle.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background(Theme.bg)
    }

    private func tabButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tag }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selectedTab == tag ? .medium : .regular))
                .foregroundStyle(selectedTab == tag ? SettingsStyle.ink : SettingsStyle.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    selectedTab == tag ? SettingsStyle.controlFill : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model Configs

    private var modelConfigsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                runtimeHeroSection
                modelSection
                liveModelSection
                backendSection
                languageSection
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - System Prompt

    private var systemPromptTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel(tr("系统提示词", "System Prompt"))

            TextEditor(text: $systemPrompt)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SettingsStyle.ink)
                .scrollContentBackground(.hidden)
                .lineSpacing(5)
                .padding(16)
                .frame(minHeight: 360)
                .background(SettingsStyle.selectedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SettingsStyle.hairline.opacity(0.62), lineWidth: 1)
                        .allowsHitTesting(false)
                )

            HStack {
                Spacer()

                Button(tr("恢复默认", "Restore Default")) {
                    systemPrompt = engine.defaultSystemPrompt
                }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(SettingsStyle.secondary)
                .opacity(0.72)
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 36)
    }

    private var permissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                permissionsSection
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - 模型

    private var selectedModel: ModelDescriptor? {
        engine.availableModels.first(where: { $0.id == selectedModelID })
    }

    private var runtimeHeroSection: some View {
        let model = selectedModel
        let state = model.map { engine.installer.installState(for: $0.id) } ?? .notInstalled

        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel(runtimeHeroLabel(for: model, state: state))

            Text(model?.displayName ?? tr("未选择模型", "No model selected"))
                .font(.system(size: 31, weight: .semibold))
                .foregroundStyle(SettingsStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(modelStateLine(for: model, state: state))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SettingsStyle.secondary)
        }
        .padding(.top, 4)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel(tr("模型", "Models"))

            VStack(spacing: 0) {
                ForEach(Array(engine.availableModels.enumerated()), id: \.element.id) { index, model in
                    modelCandidateRow(model)

                    if index < engine.availableModels.count - 1 {
                        Rectangle()
                            .fill(SettingsStyle.hairline)
                            .frame(height: 1)
                            .padding(.vertical, 12)
                    }
                }
            }

        }
    }

    private func modelCandidateRow(_ model: ModelDescriptor) -> some View {
        let state = engine.installer.installState(for: model.id)
        let isSelected = selectedModelID == model.id
        let isSelectable = modelIsSelectable(state)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(model.displayName)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelectable ? SettingsStyle.ink : SettingsStyle.secondary)
                            .lineLimit(1)

                        if let badge = modelRecommendationBadge(for: model) {
                            modelBadge(badge.text, color: badge.color)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }

                    Text(modelInstallLabel(for: state, model: model))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SettingsStyle.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                modelStateControl(for: model, state: state)

                if isSelected && isSelectable {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsStyle.ink)
                        .frame(width: 20, height: 20)
                }
            }

            if case let .downloading(completedFiles, totalFiles, _) = state {
                downloadProgressLine(
                    modelID: model.id,
                    completedFiles: completedFiles,
                    totalFiles: totalFiles
                )
            }

            if case let .failed(message) = state {
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(SettingsStyle.danger)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectable {
                selectedModelID = model.id
                modelSelectionMessage = nil
            }
        }
    }

    private func labelWithInfo(_ title: String, topic: SettingsInfoTopic, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 6 : 7) {
            sectionLabel(title, compact: compact)

            Button {
                activeInfoTopic = topic
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(SettingsStyle.tertiary.opacity(0.42), lineWidth: 0.8)
                        .frame(width: compact ? 12 : 13, height: compact ? 12 : 13)
                    Text("!")
                        .font(.system(size: compact ? 7 : 7.5, weight: .medium))
                        .foregroundStyle(SettingsStyle.tertiary.opacity(0.62))
                }
            }
            .buttonStyle(.plain)
            .opacity(0.78)
        }
    }

    private func sectionLabel(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(.system(size: compact ? 15 : 13, weight: compact ? .regular : .medium))
            .foregroundStyle(compact ? SettingsStyle.ink : SettingsStyle.secondary)
    }

    private func modelIsSelectable(_ state: ModelInstallState) -> Bool {
        switch state {
        case .downloaded, .bundled:
            return true
        default:
            return false
        }
    }

    private func modelRecommendationBadge(for model: ModelDescriptor) -> (text: String, color: Color)? {
        switch model.id {
        case ModelDescriptor.gemma4E2B.id:
            return (tr("推荐", "Recommended"), SettingsStyle.ink)
        case ModelDescriptor.gemma4E4B.id:
            return (tr("更强", "Stronger"), SettingsStyle.secondary)
        case ModelDescriptor.miniCPMV4_6.id:
            return (tr("视觉增强", "Vision+"), SettingsStyle.secondary)
        default:
            return nil
        }
    }

    private func modelRecommendationDetail(for model: ModelDescriptor) -> (zh: String, en: String)? {
        switch model.id {
        case ModelDescriptor.gemma4E2B.id:
            return (
                "日常聊天、写作、工具调用、LIVE",
                "Chat, writing, tools, LIVE"
            )
        case ModelDescriptor.gemma4E4B.id:
            return (
                "复杂任务和多工具规划",
                "Complex tasks and multi-tool planning"
            )
        case ModelDescriptor.miniCPMV4_6.id:
            return (
                "复杂图片分析和视觉增强",
                "Complex image analysis and vision assist"
            )
        default:
            return nil
        }
    }

    private func modelDownloadButtonTitle(for model: ModelDescriptor, isResumable: Bool) -> String {
        if isResumable {
            return tr("继续下载", "Resume")
        }
        if model.id == ModelDescriptor.gemma4E2B.id {
            return tr("下载推荐模型", "Download Recommended")
        }
        return tr("下载", "Download")
    }

    private func runtimeHeroLabel(for model: ModelDescriptor?, state: ModelInstallState) -> String {
        guard let model else {
            return tr("未选择模型", "No Model Selected")
        }

        guard modelIsSelectable(state) else {
            return tr("待下载模型", "Model Pending Download")
        }

        if engine.catalog.loadedModel?.id == model.id && engine.isModelReady {
            return tr("已加载模型", "Loaded Model")
        }

        return tr("已选择模型", "Selected Model")
    }

    private func modelInstallLabel(for state: ModelInstallState, model: ModelDescriptor) -> String {
        if let runtimeLabel = modelRuntimeLabel(for: model, includeBackend: true) {
            return runtimeLabel
        }

        let recommendationDetail = modelRecommendationDetail(for: model)

        switch state {
        case .downloaded, .bundled:
            if let recommendationDetail {
                return tr("已下载 · \(recommendationDetail.zh)", "Downloaded · \(recommendationDetail.en)")
            }
            return tr("已下载", "Downloaded")
        case .notInstalled:
            let isResumable = engine.installer.hasResumableDownload(for: model.id)
            if let recommendationDetail {
                return isResumable
                    ? tr("未下载 · 可继续 · \(recommendationDetail.zh)", "Not downloaded · resumable · \(recommendationDetail.en)")
                    : tr("未下载 · \(recommendationDetail.zh)", "Not downloaded · \(recommendationDetail.en)")
            }
            return isResumable
                ? tr("未下载 · 可继续", "Not downloaded · resumable")
                : tr("未下载", "Not downloaded")
        case .checkingSource:
            return tr("检查中", "Checking")
        case .downloading:
            if let metrics = engine.installer.downloadProgress[model.id] {
                return tr("下载中 · \(downloadMetricsText(metrics))", "Downloading · \(downloadMetricsText(metrics))")
            }
            return tr("下载中", "Downloading")
        case .failed:
            return tr("下载失败", "Download failed")
        }
    }

    private func modelStateLine(for model: ModelDescriptor?, state: ModelInstallState) -> String {
        guard let model else {
            return tr("请选择模型", "Select a model")
        }

        if let runtimeLabel = modelRuntimeLabel(for: model, includeBackend: true) {
            return runtimeLabel
        }

        let mode = preferredBackend.uppercased()
        switch state {
        case .downloaded, .bundled:
            return tr("已下载 · \(mode)", "Downloaded · \(mode)")
        case .notInstalled:
            if engine.installer.hasResumableDownload(for: model.id) {
                return tr("未下载 · 可继续", "Not downloaded · resumable")
            }
            return tr("未下载", "Not downloaded")
        case .checkingSource:
            return tr("检查中", "Checking")
        case .downloading:
            return tr("下载完成后可启用", "Available after download")
        case .failed:
            return tr("模型下载失败", "Download failed")
        }
    }

    private func modelRuntimeLabel(for model: ModelDescriptor, includeBackend: Bool) -> String? {
        switch engine.coordinator.sessionState {
        case .ready(let modelID, let backend):
            guard modelID == model.id else { return nil }
            return runtimeLabel(
                zh: "已加载",
                en: "Loaded",
                backend: includeBackend ? backend : nil
            )
        case .generating(let modelID, _):
            guard modelID == model.id else { return nil }
            return runtimeLabel(
                zh: "已加载",
                en: "Loaded",
                backend: includeBackend ? engine.config.preferredBackend : nil
            )
        case .loading(let modelID, _):
            guard modelID == model.id else { return nil }
            return runtimeLabel(
                zh: "加载中",
                en: "Loading",
                backend: includeBackend ? preferredBackend : nil
            )
        case .switching(_, let target):
            guard target.modelID == model.id else { return nil }
            return runtimeLabel(
                zh: "切换中",
                en: "Switching",
                backend: includeBackend ? target.backend : nil
            )
        case .unloading(let modelID):
            guard modelID == model.id else { return nil }
            return tr("卸载中", "Unloading")
        default:
            return nil
        }
    }

    private func runtimeLabel(zh: String, en: String, backend: String?) -> String {
        guard let backend, !backend.isEmpty else {
            return tr(zh, en)
        }
        let mode = backend.uppercased()
        return tr("\(zh) · \(mode)", "\(en) · \(mode)")
    }

    // MARK: - 推理

    /// 选中模型的 family。用于 gate 那些只对特定家族有意义的 UI 控件
    /// (例如 MTP 推测解码只 Gemma 4 .litertlm 才有, MiniCPM-V 没有这个概念)。
    /// 找不到 descriptor 时返回 nil, 调用方按需 fallback。
    private var currentModelFamily: ModelFamily? {
        engine.availableModels.first(where: { $0.id == selectedModelID })?.family
    }

    private var currentModelSupportsSpeculativeDecoding: Bool {
        currentModelFamily == .gemma4
    }

    private var speculativeDecodingToggleBinding: Binding<Bool> {
        Binding(
            get: {
                currentModelSupportsSpeculativeDecoding ? enableSpeculativeDecoding : false
            },
            set: { newValue in
                if currentModelSupportsSpeculativeDecoding {
                    enableSpeculativeDecoding = newValue
                }
            }
        )
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel(tr("推理", "Inference"))

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    sectionLabel(tr("推理方式", "Inference Mode"), compact: true)

                    Spacer(minLength: 16)

                    CustomSegmentedPicker(
                        selection: $preferredBackend,
                        options: [
                            (value: "gpu", label: "GPU"),
                            (value: "cpu", label: "CPU"),
                        ]
                    )
                    .frame(width: 184)
                }
                .padding(.vertical, 4)

                Rectangle()
                    .fill(SettingsStyle.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 16)

                HStack(alignment: .center, spacing: 12) {
                    labelWithInfo(tr("推测解码", "Speculative Decoding"), topic: .speculativeDecoding, compact: true)

                    Spacer()

                    Toggle("", isOn: speculativeDecodingToggleBinding)
                        .labelsHidden()
                        .tint(SettingsStyle.ink)
                        .disabled(!currentModelSupportsSpeculativeDecoding)
                }
                .opacity(currentModelSupportsSpeculativeDecoding ? 1 : 0.42)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Language

    /// Language preference picker — Auto (跟随系统) / 中文 / English。
    /// 读写 `LanguageService.shared.selected`, 绑定是直接的 Binding 封装
    /// (比 @Bindable + @Observable 的混搭更显式, 也不需要额外 @State 镜像)。
    /// 切换立即触发 SwiftUI observation, 整个 app 视图重渲染新语言。
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel(tr("语言", "Language"))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("界面语言", "Interface Language"))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SettingsStyle.ink)

                        Text(languageStatusLine)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(SettingsStyle.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)
                }

                // 同 backendSection: 用自定义 segmented control 替代 SwiftUI Picker.
                // setter 里只快速 set LanguageService 让 UI 立即重渲染拿到新文案;
                // 重活 (reload skill / 改 SYSPROMPT) 推到下个
                // runloop tick 异步跑, 防止按钮 tap 后阻塞主线程造成"按下不响应"的卡顿感。
                CustomSegmentedPicker(
                    selection: Binding(
                        get: { LanguageService.shared.selected },
                        set: { newValue in
                            guard newValue != LanguageService.shared.selected else { return }
                            // 立即生效的部分: LanguageService 写 UserDefaults + 触发 @Observable
                            // tr() 视图的重渲染. 这一步必须同步, 否则 segmented 按钮的视觉
                            // selected 状态会跟 LanguageService.current 短时间不一致。
                            LanguageService.shared.selected = newValue

                            // 重活异步跑. Locale 切换的 runtime cascade:
                            //   1. Registry bundle 层: reloadAll 重读 SKILL.en.md vs SKILL.md (磁盘 + YAML 解析, ~50-150ms)
                            //   2. Engine cache 层: reloadSkills 把 registry 的新 metadata 同步进
                            //      engine.skillEntries (UI chips 读的是这个数组)
                            //   3. SYSPROMPT.md 物理文件: 跑 locale-mismatch 迁移 (~10-30ms 磁盘 IO)
                            //   4. 本地 @State systemPrompt: TextEditor 绑的是这个, 必须手动重拉
                            //   5. Live 语音模型: active ASR/TTS 依赖当前语言, 切语言后必须刷新状态
                            Task { @MainActor in
                                _ = engine.skillRegistry.reloadAll()
                                engine.reloadSkills()
                                engine.loadSystemPrompt()
                                systemPrompt = engine.config.systemPrompt
                                liveDownloader.refreshState()
                            }
                        }
                    ),
                    options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
                )
            }

            Text(L10n.Config.languageFooter)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SettingsStyle.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languageStatusLine: String {
        let selected = LanguageService.shared.selected
        let resolved = LanguageService.shared.current.resolved

        switch selected {
        case .auto:
            return tr(
                "跟随系统 · 当前为 \(localizedLanguageName(resolved))",
                "Follows system · Currently \(localizedLanguageName(resolved))"
            )
        case .zhHans:
            return tr("已选择中文", "Chinese selected")
        case .en:
            return tr("已选择英文", "English selected")
        }
    }

    private func localizedLanguageName(_ language: AppLanguage) -> String {
        switch language {
        case .auto:
            return tr("自动", "Auto")
        case .zhHans:
            return tr("中文", "Chinese")
        case .en:
            return tr("英文", "English")
        }
    }

    // MARK: - LIVE 语音模型

    private var liveModelSection: some View {
        let state = liveDownloader.installState
        let isDownloading: Bool = {
            if case .downloading = state { return true }
            return false
        }()

        return VStack(alignment: .leading, spacing: 16) {
            labelWithInfo(tr("语音", "Voice"), topic: .liveVoice)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("实时语音模型", "Live Voice Models"))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(SettingsStyle.ink)

                    Text(liveModelStatusLine(for: state))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SettingsStyle.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if !isDownloading {
                    liveModelStateButton
                }
            }
            .padding(.vertical, 4)

            if case let .downloading(completedFiles, totalFiles, _) = state {
                liveDownloadProgressView(
                    completedFiles: completedFiles,
                    totalFiles: totalFiles
                )
            }

            if case let .failed(message) = state {
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(SettingsStyle.danger)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var liveModelStateButton: some View {
        switch liveDownloader.installState {
        case .notInstalled:
            let completedAssets = liveDownloader.completedAssetCount
            let canResume = completedAssets > 0 || liveDownloader.resumableAssetCount > 0
            Button(canResume ? tr("继续下载", "Resume Download") : tr("下载", "Download")) {
                Task { await liveDownloader.downloadAll() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SettingsStyle.selectedFill, in: Capsule())
        case .checkingSource:
            modelBadge(tr("检查中", "Checking"))
        case .downloading:
            EmptyView()
        case .downloaded:
            Button(tr("移除", "Remove")) {
                Task { try? await liveDownloader.removeAll() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SettingsStyle.controlFill, in: Capsule())
        case .bundled:
            modelBadge(tr("内置", "Bundled"), color: SettingsStyle.secondary)
        case .failed:
            Button(tr("重试", "Retry")) {
                Task { await liveDownloader.downloadAll() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SettingsStyle.selectedFill, in: Capsule())
        }
    }

    private func liveModelStatusLine(for state: ModelInstallState) -> String {
        switch state {
        case .notInstalled:
            let completedAssets = liveDownloader.completedAssetCount
            let resumableAssets = liveDownloader.resumableAssetCount
            if completedAssets > 0 || resumableAssets > 0 {
                return tr(
                    "未下载 · 可继续",
                    "Not downloaded · Resume available"
                )
            }
            return tr(
                "未下载 · 约 \(LiveModelDefinition.estimatedSizeMB) MB",
                "Not downloaded · About \(LiveModelDefinition.estimatedSizeMB) MB"
            )
        case .checkingSource:
            return tr("检查中", "Checking")
        case .downloading:
            return tr("下载中", "Downloading")
        case .downloaded:
            return tr("已下载", "Downloaded")
        case .bundled:
            return tr("已内置", "Bundled")
        case .failed:
            return tr("下载失败", "Download failed")
        }
    }

    private func liveDownloadProgressView(
        completedFiles: Int,
        totalFiles: Int
    ) -> some View {
        let safeTotal = max(totalFiles, 1)
        let metrics = liveDownloader.downloadMetrics
        let fileFraction = Double(min(completedFiles, safeTotal)) / Double(safeTotal)
        let byteFraction: Double?
        if let metrics, let totalBytes = metrics.totalBytes, totalBytes > 0 {
            byteFraction = min(1, max(0, Double(metrics.bytesReceived) / Double(totalBytes)))
        } else {
            byteFraction = nil
        }
        let combinedFraction = byteFraction ?? fileFraction
        let value = min(Double(safeTotal), max(0, combinedFraction) * Double(safeTotal))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(
                        "文件 \(completedFiles)/\(totalFiles)",
                        "Files \(completedFiles)/\(totalFiles)"
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SettingsStyle.ink)
                    .lineLimit(1)

                    if let metrics {
                        Text(liveDownloadMetricsText(metrics))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(SettingsStyle.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(tr("取消", "Cancel")) {
                    liveDownloader.cancelDownload()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(SettingsStyle.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SettingsStyle.selectedFill, in: Capsule())
                .fixedSize(horizontal: true, vertical: true)
            }

            ProgressView(value: value, total: Double(safeTotal))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SettingsStyle.controlFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveDownloadMetricsText(_ metrics: ModelDownloadMetrics) -> String {
        let speedText = formattedSpeed(metrics.bytesPerSecond)
        var result: String
        if let totalBytes = metrics.totalBytes, totalBytes > 0 {
            result = "\(formattedBytes(metrics.bytesReceived)) / \(formattedBytes(totalBytes))"
        } else {
            result = formattedBytes(metrics.bytesReceived)
        }
        if !speedText.isEmpty {
            result += " · \(speedText)"
        }
        return result
    }

    private func liveStateDetail(_ state: ModelInstallState) -> String? {
        switch state {
        case .notInstalled:
            let completedAssets = liveDownloader.completedAssetCount
            let resumableAssets = liveDownloader.resumableAssetCount
            if completedAssets > 0 || resumableAssets > 0 {
                let progressText = liveDownloader.downloadMetrics.map(liveDownloadMetricsText)
                let base: String
                if completedAssets > 0, resumableAssets > 0 {
                    base = tr(
                        "已完成 \(completedAssets)/\(LiveModelDefinition.all.count)，另有 \(resumableAssets) 个可继续下载。",
                        "\(completedAssets)/\(LiveModelDefinition.all.count) complete, \(resumableAssets) can resume."
                    )
                } else if completedAssets > 0 {
                    base = tr(
                        "已完成 \(completedAssets)/\(LiveModelDefinition.all.count)，可继续下载。",
                        "\(completedAssets)/\(LiveModelDefinition.all.count) complete. You can resume downloading."
                    )
                } else {
                    base = tr(
                        "已有下载进度，可继续下载。",
                        "Download progress found. You can resume downloading."
                    )
                }
                if let progressText, !progressText.isEmpty {
                    return "\(base) \(progressText)"
                }
                return base
            }
            return tr("未安装 (~\(LiveModelDefinition.estimatedSizeMB)MB)", "Not installed (~\(LiveModelDefinition.estimatedSizeMB)MB)")
        case .downloaded:
            return tr("已下载到手机本地。", "Downloaded to device.")
        case .failed(let msg):
            return msg
        default:
            return nil
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(tr("权限", "Permissions"))
                .padding(.bottom, 18)

            ForEach(Array(AppPermissionKind.allCases.enumerated()), id: \.element.id) { index, kind in
                permissionRow(for: kind)

                if index < AppPermissionKind.allCases.count - 1 {
                    Rectangle()
                        .fill(SettingsStyle.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private func permissionRow(for kind: AppPermissionKind) -> some View {
        let status = permissionStatuses[kind] ?? .notDetermined

        return HStack(alignment: .center, spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(SettingsStyle.secondary)
                    .opacity(0.76)
                    .frame(width: 24, height: 24)

            sectionLabel(permissionTitle(kind), compact: true)

            Spacer(minLength: 10)

            permissionAction(for: kind, status: status)

            Text(permissionStatusLabel(status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.isGranted ? SettingsStyle.ink : SettingsStyle.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    SettingsStyle.controlFill,
                    in: Capsule()
                )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func permissionAction(for kind: AppPermissionKind, status: AppPermissionStatus) -> some View {
        switch status {
        case .notDetermined:
            Button(requestingPermission == kind ? tr("请求中", "Requesting") : tr("请求", "Request")) {
                requestPermission(kind)
            }
            .disabled(requestingPermission != nil)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(SettingsStyle.selectedFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(SettingsStyle.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        case .denied, .restricted:
            Button(tr("设置", "Settings")) {
                openAppSettings()
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(SettingsStyle.secondary)
            .opacity(0.76)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        case .granted:
            EmptyView()
        }
    }

    @ViewBuilder
    private func modelStateControl(for model: ModelDescriptor, state: ModelInstallState) -> some View {
        switch state {
        case .notInstalled:
            let isResumable = engine.installer.hasResumableDownload(for: model.id)
            let canRemoveLocalData = isResumable || engine.installer.hasLocalArtifacts(for: model)
            HStack(spacing: 8) {
                Button(modelDownloadButtonTitle(for: model, isResumable: isResumable)) {
                    modelSelectionMessage = nil
                    installModelWithTelemetry(model)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsStyle.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SettingsStyle.selectedFill, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(SettingsStyle.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                )

                if canRemoveLocalData {
                    Button(tr("移除", "Remove")) {
                        removeInstalledModel(model)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsStyle.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SettingsStyle.controlFill, in: Capsule())
                }
            }
        case .checkingSource:
            modelBadge(tr("检查中", "Checking"))
        case .downloading:
            Button(tr("取消", "Cancel")) {
                engine.installer.cancelInstall(modelID: model.id)
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(SettingsStyle.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        case .downloaded:
            Button(tr("移除", "Remove")) {
                removeInstalledModel(model)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SettingsStyle.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(SettingsStyle.controlFill, in: Capsule())
        case .bundled:
            modelBadge(tr("内置", "Bundled"), color: SettingsStyle.secondary)
        case .failed:
            HStack(spacing: 8) {
                Button(tr("重试", "Retry")) {
                    modelSelectionMessage = nil
                    installModelWithTelemetry(model)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsStyle.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SettingsStyle.selectedFill, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(SettingsStyle.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                )

                Button(tr("移除", "Remove")) {
                    removeInstalledModel(model)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsStyle.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(SettingsStyle.controlFill, in: Capsule())
            }
        }
    }

    private func modelBadge(_ text: String, color: Color = SettingsStyle.tertiary) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(SettingsStyle.controlFill, in: Capsule())
    }

    private func modelInstallFailureMessage(_: Error) -> String {
        tr("下载失败，请重试。", "Download failed. Please try again.")
    }

    private func installModelWithTelemetry(_ model: ModelDescriptor) {
        Telemetry.recordModelInstall(modelID: model.id, outcome: .started)
        Task {
            do {
                try await engine.installer.install(model: model)
                Telemetry.recordModelInstall(modelID: model.id, outcome: .completed)
                await MainActor.run {
                    engine.installer.refreshInstallStates()
                    selectModelIfCurrentUnavailable(model)
                }
            } catch is CancellationError {
                Telemetry.recordModelInstall(modelID: model.id, outcome: .cancelled)
                await MainActor.run {
                    engine.installer.refreshInstallStates()
                    modelSelectionMessage = nil
                }
            } catch {
                Telemetry.recordModelInstall(
                    modelID: model.id,
                    outcome: .failed,
                    failureReason: Telemetry.failureReason(for: error)
                )
                await MainActor.run {
                    engine.installer.refreshInstallStates()
                    modelSelectionMessage = modelInstallFailureMessage(error)
                }
            }
        }
    }

    private func removeInstalledModel(_ model: ModelDescriptor) {
        Task {
            await engine.removeModel(model)
            await MainActor.run {
                if selectedModelID == model.id {
                    selectedModelID = resolvedInitialModelID()
                }
                modelSelectionMessage = nil
            }
        }
    }

    private func downloadProgressLine(
        modelID: String,
        completedFiles: Int,
        totalFiles: Int
    ) -> some View {
        let safeTotal = max(totalFiles, 1)
        let metrics = engine.installer.downloadProgress[modelID]
        let activeFileFraction = metrics?.fractionCompleted.map { min(1, max(0, $0)) } ?? 0
        let value = min(Double(safeTotal), Double(min(completedFiles, safeTotal)) + activeFileFraction)

        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let fraction = min(1, max(0, value / Double(safeTotal)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SettingsStyle.hairline)
                    Capsule()
                        .fill(Theme.accentMuted.opacity(0.92))
                        .frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .frame(height: 3)

            Text(tr(
                "文件 \(completedFiles)/\(totalFiles)",
                "Files \(completedFiles)/\(totalFiles)"
            ))
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(SettingsStyle.tertiary)
            .lineLimit(1)
        }
        .padding(.top, 2)
    }

    private func downloadMetricsText(_ metrics: DownloadProgress) -> String {
        let speedText = formattedSpeed(metrics.bytesPerSecond)
        var result: String
        if let totalBytes = metrics.totalBytes, totalBytes > 0 {
            result = "\(formattedBytes(metrics.bytesReceived)) / \(formattedBytes(totalBytes))"
        } else {
            result = formattedBytes(metrics.bytesReceived)
        }
        if !speedText.isEmpty {
            result += " · \(speedText)"
        }
        return result
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedSpeed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else {
            return ""
        }
        return formattedBytes(Int64(bytesPerSecond)) + "/s"
    }

    // MARK: - 加载 / 应用

    private func permissionTitle(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return tr("麦克风", "Microphone")
        case .camera:
            return tr("摄像头", "Camera")
        case .calendar:
            return tr("日历写入", "Calendar Write")
        case .calendarRead:
            return tr("日历读取", "Calendar Read")
        case .reminders:
            return tr("提醒事项", "Reminders")
        case .contacts:
            return tr("通讯录", "Contacts")
        }
    }

    private func permissionDescription(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return tr("允许录音并采集实时音频输入", "Allow recording and capturing realtime audio input")
        case .camera:
            return tr("允许在 Live 模式中观察周围环境", "Allow camera access for Live mode visual grounding")
        case .calendar:
            return tr("允许创建和写入日历事项", "Allow creating and writing calendar events")
        case .calendarRead:
            return tr("允许读取日程用于本地分析", "Allow reading calendar events for local analysis")
        case .reminders:
            return tr("允许创建提醒和待办", "Allow creating reminders and tasks")
        case .contacts:
            return tr("允许保存和更新联系人", "Allow saving and updating contacts")
        }
    }

    private func permissionStatusLabel(_ status: AppPermissionStatus) -> String {
        switch status {
        case .notDetermined:
            return tr("未请求", "Not Requested")
        case .denied:
            return tr("已拒绝", "Denied")
        case .restricted:
            return tr("受限制", "Restricted")
        case .granted:
            return tr("已授权", "Granted")
        }
    }

    private func permissionStatusDetail(_ status: AppPermissionStatus) -> String {
        switch status {
        case .notDetermined:
            return tr("首次使用时会弹出系统授权框", "The system permission dialog will appear on first use")
        case .denied:
            return tr("请到系统设置里手动开启权限", "Please enable this permission manually in Settings")
        case .restricted:
            return tr("当前设备限制了这项权限", "This permission is restricted on the current device")
        case .granted:
            return tr("可以直接执行相关 Skill", "Related skills can run directly")
        }
    }

    private func loadCurrentSettings() {
        engine.installer.refreshInstallStates()
        _ = engine.reconcileSelectedModelIfUnavailable()
        liveDownloader.refreshState()
        selectedModelID = resolvedInitialModelID()
        preferredBackend = engine.config.preferredBackend
        enableSpeculativeDecoding = engine.config.enableSpeculativeDecoding
        systemPrompt = engine.config.systemPrompt
        modelSelectionMessage = nil
        refreshPermissionStatuses()
    }

    private func resolvedInitialModelID() -> String {
        engine.installedModelID(preferredIDs: [
            engine.catalog.loadedModel?.id,
            engine.config.selectedModelID
        ]) ?? engine.config.selectedModelID
    }

    private func selectModelIfCurrentUnavailable(_ model: ModelDescriptor) {
        guard engine.installer.artifactPath(for: model) != nil else {
            return
        }

        if let currentModel = selectedModel,
           engine.installer.artifactPath(for: currentModel) != nil {
            return
        }

        selectedModelID = model.id
    }

    private func runtimeNeedsLoad(for modelID: String) -> Bool {
        let runtimeState = engine.coordinator.sessionState
        let runtimeModelID = runtimeState.activeModelID ?? engine.catalog.loadedModel?.id
        guard runtimeModelID == modelID else {
            return true
        }

        switch runtimeState {
        case .idle, .failed:
            return true
        case .loading, .ready, .generating, .switching, .unloading:
            return false
        }
    }

    private func applySettings() -> Bool {
        let modelChanged = engine.config.selectedModelID != selectedModelID
        let backendChanged = engine.config.preferredBackend != preferredBackend

        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }),
              engine.installer.artifactPath(for: selectedModel) != nil else {
            modelSelectionMessage = tr(
                "请选择已下载模型，或先下载当前模型。",
                "Choose an installed model, or download the current model first."
            )
            return false
        }

        // 非 Gemma 4 模型不支持 MTP; UI 的 toggle binding 已经 gate 住交互,
        // 但 @State `enableSpeculativeDecoding` 可能仍保留上次 Gemma 4 时的
        // true 值。这里按 selectedModel 重算 effective 值, 避免 "UI 显示关闭
        // 但写回 config 是 true" 的不一致 (会被 reloadModel 持久化)。
        let effectiveSpeculativeDecoding =
            selectedModel.family == .gemma4 ? enableSpeculativeDecoding : false
        let mtpChanged = engine.config.enableSpeculativeDecoding != effectiveSpeculativeDecoding

        modelSelectionMessage = nil
        engine.config.systemPrompt = systemPrompt
        engine.config.preferredBackend = preferredBackend
        engine.config.enableSpeculativeDecoding = effectiveSpeculativeDecoding

        // 同步采样参数到 LLM (沿用 ModelConfig 默认值; 下次生成立即生效)
        engine.applySamplingConfig()

        engine.config.selectedModelID = selectedModelID
        let needsLoad = runtimeNeedsLoad(for: selectedModelID)
        // backend / MTP 变更也要 reload — LiteRTLMEngine 在 load 时构造,
        // 这两个参数都不可热切换。needsLoad 覆盖「模型刚下载完成但
        // selectedModelID 没变」的场景，同时避免已加载模型反复 reload。
        if modelChanged || backendChanged || mtpChanged || needsLoad {
            engine.reloadModel()
        }
        return true
    }

    private func refreshPermissionStatuses() {
        permissionStatuses = engine.permissionStatuses()
    }

    private func requestPermission(_ kind: AppPermissionKind) {
        requestingPermission = kind
        Task {
            _ = await engine.requestPermission(kind)
            await MainActor.run {
                refreshPermissionStatuses()
                requestingPermission = nil
            }
        }
    }

    private func openAppSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }
}

private extension ModelInstallState {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private var sections: [(title: String, body: String)] {
        [
            (
                tr("本地优先", "Local-first"),
                tr(
                    "PhoneClaw 的聊天、图片理解、语音和工具执行默认在设备本地处理。聊天内容、图片和个人数据不会上传到 PhoneClaw 服务器。",
                    "PhoneClaw processes chat, image understanding, voice, and tool execution locally by default. Chat content, images, and personal data are not uploaded to PhoneClaw servers."
                )
            ),
            (
                tr("权限", "Permissions"),
                tr(
                    "麦克风、摄像头、日历、提醒事项、通讯录和健康数据只会在你启用相关功能时访问。健康数据只读使用, 用于本地生成摘要和建议。",
                    "Microphone, camera, calendar, reminders, contacts, and Health data are accessed only when you enable related features. Health data is read-only and used locally for summaries and insights."
                )
            ),
            (
                tr("模型下载", "Model Downloads"),
                tr(
                    "你选择下载模型时, App 会连接模型源获取模型文件。下载的是模型数据, 不是可执行代码。模型文件保存在本机。",
                    "When you choose to download a model, the app connects to model sources to fetch model files. These downloads are model data, not executable code, and are stored on device."
                )
            ),
            (
                tr("跟踪", "Tracking"),
                tr(
                    "PhoneClaw 不使用 App Tracking Transparency 跟踪你, 不将数据用于跨 App 或网站追踪。",
                    "PhoneClaw does not use App Tracking Transparency tracking and does not use your data to track you across apps or websites."
                )
            )
        ]
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button {
                        dismiss()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(SettingsStyle.controlFill)
                                .frame(
                                    width: UIScale.topStatusChipDiameter,
                                    height: UIScale.topStatusChipDiameter
                                )
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(SettingsStyle.secondary)
                                .opacity(0.58)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(tr("隐私", "Privacy"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SettingsStyle.muted)

                    Spacer()

                    Color.clear
                        .frame(
                            width: UIScale.topStatusChipDiameter,
                            height: UIScale.topStatusChipDiameter
                        )
                }
                .padding(.horizontal, Theme.inputPadH)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(tr("隐私政策", "Privacy Policy"))
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(SettingsStyle.ink)
                            .padding(.top, 30)

                        Text(tr(
                            "这份说明概述 PhoneClaw 如何在设备本地处理数据, 以及何时访问系统权限。",
                            "This summary explains how PhoneClaw handles data locally on device and when it accesses system permissions."
                        ))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(SettingsStyle.secondary)
                        .lineSpacing(5)

                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(SettingsStyle.ink)
                                Text(section.body)
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(SettingsStyle.secondary)
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                SettingsStyle.controlFill,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct InfoDisclosureOverlay: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Self.ink)

                    Spacer(minLength: 12)

                    Button(action: onDismiss) {
                        ZStack {
                            Circle()
                                .fill(Self.controlFill)
                                .frame(width: 28, height: 28)
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Self.secondary)
                                .opacity(0.72)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(tr("关闭", "Close")))
                }

                Text(message)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Self.secondary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 330, alignment: .leading)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Self.outline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 28, y: 14)
            .padding(.horizontal, 34)
        }
    }

    private static let ink = Color(light: "303033", dark: "EEE9DF")
    private static let secondary = Color(light: "6F6A63", dark: "BEB4A8")
    private static let surface = Color(light: "F9F7F1", dark: "24211B").opacity(0.96)
    private static let controlFill = Color(light: "ECE8E0", dark: "343027").opacity(0.84)
    private static let outline = Color(light: "FFFFFF", dark: "3C362C").opacity(0.72)
}

private enum SettingsInfoTopic: Identifiable {
    case enabledModel
    case models
    case liveVoice
    case inference
    case inferenceMode
    case speculativeDecoding
    case language
    case systemPrompt
    case permissions
    case permission(AppPermissionKind)

    var id: String {
        switch self {
        case .enabledModel: return "enabledModel"
        case .models: return "models"
        case .liveVoice: return "liveVoice"
        case .inference: return "inference"
        case .inferenceMode: return "inferenceMode"
        case .speculativeDecoding: return "speculativeDecoding"
        case .language: return "language"
        case .systemPrompt: return "systemPrompt"
        case .permissions: return "permissions"
        case .permission(let kind): return "permission-\(kind.id)"
        }
    }

    var title: String {
        switch self {
        case .enabledModel:
            return tr("已启用模型", "Enabled Model")
        case .models:
            return tr("模型", "Models")
        case .liveVoice:
            return tr("语音", "Voice")
        case .inference:
            return tr("推理", "Inference")
        case .inferenceMode:
            return tr("推理方式", "Inference Mode")
        case .speculativeDecoding:
            return tr("推测解码", "Speculative Decoding")
        case .language:
            return tr("语言", "Language")
        case .systemPrompt:
            return tr("系统提示词", "System Prompt")
        case .permissions:
            return tr("权限", "Permissions")
        case .permission(let kind):
            return permissionTitle(kind)
        }
    }

    var message: String {
        switch self {
        case .enabledModel:
            return tr("正在使用的模型。切换模型后点确定生效。", "The model in use. Changes apply after tapping OK.")
        case .models:
            return tr("未下载的模型需要先下载，完成后才能选择。", "Models must be downloaded before they can be selected.")
        case .liveVoice:
            return tr(
                "实时语音和按住说话需要语音识别、语音合成与语音检测模型。",
                "Live voice and hold-to-talk require speech recognition, speech synthesis, and voice detection models."
            )
        case .inference:
            return tr("这里控制模型生成时使用的方式。", "Controls how the model generates responses.")
        case .inferenceMode:
            return tr("GPU 通常速度更高，CPU 通常更省内存。", "GPU is usually faster; CPU usually uses less memory.")
        case .speculativeDecoding:
            return tr(
                "仅 Gemma 4 可用；部分短回复可能更快，默认关闭。",
                "Available for Gemma 4 only. Some short replies may be faster. Off by default."
            )
        case .language:
            return tr(
                "默认跟随系统。手动选择后，界面会立即切换，新对话会使用新的语言偏好。",
                "Defaults to system. Manual changes update the interface immediately and apply to new chats."
            )
        case .systemPrompt:
            return tr("控制助手默认行为和语气。修改后点确定生效。", "Controls default behavior and tone. Changes apply after tapping OK.")
        case .permissions:
            return tr("授权后，相关 Skill 才能访问对应系统能力。", "Permissions allow related skills to access system capabilities.")
        case .permission(let kind):
            return permissionMessage(kind)
        }
    }

    private func permissionTitle(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return tr("麦克风", "Microphone")
        case .camera:
            return tr("摄像头", "Camera")
        case .calendar:
            return tr("日历写入", "Calendar Write")
        case .calendarRead:
            return tr("日历读取", "Calendar Read")
        case .reminders:
            return tr("提醒事项", "Reminders")
        case .contacts:
            return tr("通讯录", "Contacts")
        }
    }

    private func permissionMessage(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return tr("用于录音和实时语音输入。", "Used for recording and live voice input.")
        case .camera:
            return tr("用于 Live 模式观察周围环境。", "Used by Live mode to observe the surroundings.")
        case .calendar:
            return tr("用于创建和写入日历事项。", "Used to create and write calendar events.")
        case .calendarRead:
            return tr("用于读取指定时间范围的日程，并在本地做时间安排分析。", "Used to read calendar events in a chosen time range for local schedule analysis.")
        case .reminders:
            return tr("用于创建提醒和待办。", "Used to create reminders and tasks.")
        case .contacts:
            return tr("用于保存和更新联系人。", "Used to save and update contacts.")
        }
    }
}

private enum SettingsStyle {
    static let ink = Color(light: "303033", dark: "EEE9DF")
    static let primary = Color(light: "2F3033", dark: "EEE9DF")
    static let onPrimary = Color(light: "FFFFFF", dark: "1D1A16")
    static let secondary = Color(light: "7A756E", dark: "B9AFA3")
    static let muted = Color(light: "8B857C", dark: "A89F94")
    static let tertiary = Color(light: "B9B0A5", dark: "7F766A")
    static let hairline = Color(light: "E8E2D8", dark: "373128")
    static let controlFill = Color(light: "ECE8E0", dark: "2C2821").opacity(0.76)
    static let selectedFill = Color(light: "FFFFFF", dark: "211E19").opacity(0.72)
    static let segmentThumb = Color(light: "FFFFFF", dark: "3A342B").opacity(0.88)
    static let pressedFill = Color(light: "F0ECE5", dark: "383229")
    static let danger = Color(light: "9E554D", dark: "E08B80")
}

// MARK: - CustomSegmentedPicker
//
// SwiftUI 的 `Picker(.segmented)` 在当前 iOS / Theme 配色下死活不响应点击,
// 复现稳定 (推理后端 + 语言两个都不行). 怀疑是 ScrollView 内 .background +
// .pickerStyle(.segmented) 组合的 hit-test 黑魔法, 改 background 写法 / 加
// allowsHitTesting 都没效果. 直接用纯 Button 拼一个看着像 segmented 的控件,
// 每个 button 自己 onTap 写 selection, 完全显式, 没有任何 SwiftUI 内部行为
// 干扰. 视觉上跟 iOS 原生 segmented control 接近 (圆角胶囊背景 + 选中态 thumb).
//
// thumb 滑动动画: 用 matchedGeometryEffect 把 "selected 背景" 在不同 segment
// 之间做连贯过渡, 避免单纯切换 background 颜色那种生硬感。

struct CustomSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var thumbNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    if option.value != selection {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            selection = option.value
                        }
                    }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SettingsStyle.ink : SettingsStyle.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            // 只有选中段渲染 thumb 背景, 用 matchedGeometryEffect
                            // 让它在不同 segment 之间连贯滑动.
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(SettingsStyle.segmentThumb)
                                        .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                                }
                            }
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SettingsStyle.controlFill)
                .allowsHitTesting(false)
        )
    }
}
