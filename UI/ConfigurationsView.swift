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

    // 本地编辑状态（确认后才应用）
    @State private var selectedModelID = MLXLocalLLMService.defaultModel.id
    @State private var maxTokens: Double = 4000
    @State private var topK: Double = 64
    @State private var topP: Double = 0.95
    @State private var temperature: Double = 1.0
    @State private var systemPrompt: String = ""
    @State private var permissionStatuses: [AppPermissionKind: AppPermissionStatus] = [:]
    @State private var requestingPermission: AppPermissionKind?

    private var isChineseSystem: Bool {
        Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab 切换
                HStack(spacing: 0) {
                    tabButton(localized("模型设置", "Model Settings"), tag: 0)
                    tabButton(localized("系统提示词", "System Prompt"), tag: 1)
                    tabButton(localized("权限", "Permissions"), tag: 2)
                }
                .padding(.horizontal)

                Rectangle().fill(Theme.border).frame(height: 1)

                Group {
                    if selectedTab == 0 {
                        modelConfigsTab
                    } else if selectedTab == 1 {
                        systemPromptTab
                    } else {
                        permissionsTab
                    }
                }

                Rectangle().fill(Theme.border).frame(height: 1)

                // 底部按钮
                HStack(spacing: 20) {
                    Spacer()
                    Button(localized("取消", "Cancel")) { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                    Button(localized("确定", "OK")) {
                        if applySettings() {
                            dismiss()
                        }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                }
                .padding()
            }
            .navigationTitle(localized("配置", "Configurations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Theme.bgElevated)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadCurrentSettings() }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            engine.llm.refreshModelInstallStates()
            refreshPermissionStatuses()
        }
        #endif
    }

    // MARK: - Tab 按钮

    private func tabButton(_ title: String, tag: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tag }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(selectedTab == tag ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tag ? Theme.textPrimary : Theme.textTertiary)

                Rectangle()
                    .fill(selectedTab == tag ? Theme.accent : .clear)
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Model Configs

    private var modelConfigsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modelSection
                configSlider(
                    title: localized("最大 Token 数", "Max Tokens"),
                    value: $maxTokens,
                    range: 128...8192,
                    displayValue: "\(Int(maxTokens))"
                )
                configSlider(
                    title: localized("采样 TopK", "TopK"),
                    value: $topK,
                    range: 1...128,
                    displayValue: "\(Int(topK))"
                )
                configSlider(
                    title: localized("采样 TopP", "TopP"),
                    value: $topP,
                    range: 0...1,
                    displayValue: String(format: "%.2f", topP)
                )
                configSlider(
                    title: localized("温度", "Temperature"),
                    value: $temperature,
                    range: 0...2,
                    displayValue: String(format: "%.2f", temperature)
                )
            }
            .padding()
        }
    }

    // MARK: - System Prompt

    private var systemPromptTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $systemPrompt)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )

            Button(localized("恢复默认", "Restore Default")) {
                systemPrompt = engine.defaultSystemPrompt
            }
            .font(.subheadline)
            .foregroundStyle(Theme.accent)
        }
        .padding()
    }

    private var permissionsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsSection
            }
            .padding()
        }
    }

    // MARK: - 配置 Slider

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("模型", "Model"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(engine.llm.isLoaded
                 ? localized("当前已加载：", "Loaded: ") + engine.llm.modelDisplayName
                 : engine.llm.statusMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 10) {
                ForEach(engine.availableModels) { model in
                    let state = engine.llm.installState(for: model)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(model.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.textTertiary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 8) {
                                modelStateControl(for: model, state: state)

                                if selectedModelID == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }

                        if let detail = modelStateDetail(state) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(state.isFailure ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedModelID == model.id ? Theme.accentSubtle : Theme.bg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                selectedModelID == model.id ? Theme.accent : Theme.border,
                                lineWidth: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        selectedModelID = model.id
                    }
                }
            }

            Text(modelFooterText)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("权限", "Permissions"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            ForEach(AppPermissionKind.allCases) { kind in
                permissionRow(for: kind)
            }
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func permissionRow(for kind: AppPermissionKind) -> some View {
        let status = permissionStatuses[kind] ?? .notDetermined

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(permissionTitle(kind))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(permissionStatusLabel(status))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status.isGranted ? Theme.accentGreen : Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (status.isGranted ? Theme.accentGreen : Theme.accent)
                                    .opacity(0.14),
                                in: Capsule()
                            )
                    }

                    Text(permissionDescription(kind))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    Text(permissionStatusDetail(status))
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 10) {
                if !status.isGranted {
                    Button(requestingPermission == kind
                           ? localized("请求中...", "Requesting...")
                           : localized("请求权限", "Request Access")) {
                        requestPermission(kind)
                    }
                    .disabled(requestingPermission != nil)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                }

                Button(localized("去设置", "Open Settings")) {
                    openAppSettings()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.bg, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func configSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .tint(Theme.accent)

                Text(displayValue)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))
                    .frame(width: 56)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func modelStateControl(for model: BundledModelOption, state: ModelInstallState) -> some View {
        switch state {
        case .notInstalled:
            Button(localized("下载", "Download")) {
                selectedModelID = model.id
                Task {
                    await engine.llm.downloadModel(id: model.id)
                    if engine.llm.isModelAvailable(model),
                       selectedModelID == model.id,
                       (!engine.llm.isLoaded || engine.llm.loadedModelID != model.id) {
                        engine.config.selectedModelID = model.id
                        engine.reloadModel()
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        case .checkingSource:
            modelBadge(localized("检查中", "Checking"))
        case .downloading(let completedFiles, let totalFiles, _):
            modelBadge(localized("下载中 \(completedFiles)/\(totalFiles)", "Downloading \(completedFiles)/\(totalFiles)"))
        case .downloaded:
            modelBadge(localized("已下载", "Downloaded"), color: Theme.accentGreen)
        case .bundled:
            modelBadge(localized("内置", "Bundled"), color: Theme.accentGreen)
        case .failed:
            Button(localized("重试", "Retry")) {
                selectedModelID = model.id
                Task {
                    await engine.llm.downloadModel(id: model.id)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        }
    }

    private func modelBadge(_ text: String, color: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func modelStateDetail(_ state: ModelInstallState) -> String? {
        switch state {
        case .notInstalled:
            return localized("未安装", "Not Installed")
        case .checkingSource:
            return localized("正在检查模型下载源。", "Checking the model download source.")
        case .downloading(_, _, let currentFile):
            return localized("正在下载：", "Downloading: ") + currentFile
        case .downloaded:
            return localized("已下载到手机本地，可直接加载。", "Downloaded on device and ready to load.")
        case .bundled:
            return localized("模型已随 App 内置。", "This model is bundled inside the app.")
        case .failed(let message):
            return message
        }
    }

    private var modelFooterText: String {
        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }) else {
            return localized("点右侧按钮下载模型后再点击确定。", "Download a model first, then tap OK.")
        }

        if !engine.llm.isModelAvailable(selectedModel) {
            return localized("先下载选中的模型，再点击确定加载。", "Download the selected model first, then tap OK to load it.")
        }

        if selectedModelID == engine.llm.selectedModelID,
           engine.llm.loadedModelID == selectedModelID,
           engine.llm.isLoaded {
            return localized("点击确定会保留当前模型。", "Tap OK to keep the current model.")
        }

        return localized("点击确定后会卸载当前模型并重新加载新模型。", "Tap OK to unload the current model and reload the new one.")
    }

    // MARK: - 加载 / 应用

    private func localized(_ zh: String, _ en: String) -> String {
        isChineseSystem ? zh : en
    }

    private func permissionTitle(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return localized("麦克风", "Microphone")
        case .calendar:
            return localized("日历", "Calendar")
        case .reminders:
            return localized("提醒事项", "Reminders")
        case .contacts:
            return localized("通讯录", "Contacts")
        }
    }

    private func permissionDescription(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return localized("允许录音并采集实时音频输入", "Allow recording and capturing realtime audio input")
        case .calendar:
            return localized("允许创建和写入日历事项", "Allow creating and writing calendar events")
        case .reminders:
            return localized("允许创建提醒和待办", "Allow creating reminders and tasks")
        case .contacts:
            return localized("允许保存和更新联系人", "Allow saving and updating contacts")
        }
    }

    private func permissionStatusLabel(_ status: AppPermissionStatus) -> String {
        switch status {
        case .notDetermined:
            return localized("未请求", "Not Requested")
        case .denied:
            return localized("已拒绝", "Denied")
        case .restricted:
            return localized("受限制", "Restricted")
        case .granted:
            return localized("已授权", "Granted")
        }
    }

    private func permissionStatusDetail(_ status: AppPermissionStatus) -> String {
        switch status {
        case .notDetermined:
            return localized("首次使用时会弹出系统授权框", "The system permission dialog will appear on first use")
        case .denied:
            return localized("请到系统设置里手动开启权限", "Please enable this permission manually in Settings")
        case .restricted:
            return localized("当前设备限制了这项权限", "This permission is restricted on the current device")
        case .granted:
            return localized("可以直接执行相关 Skill", "Related skills can run directly")
        }
    }

    private func loadCurrentSettings() {
        engine.llm.refreshModelInstallStates()
        selectedModelID = engine.llm.loadedModelID ?? engine.config.selectedModelID
        maxTokens = Double(engine.config.maxTokens)
        topK = Double(engine.config.topK)
        topP = engine.config.topP
        temperature = engine.config.temperature
        systemPrompt = engine.config.systemPrompt
        refreshPermissionStatuses()
    }

    private func applySettings() -> Bool {
        let modelChanged = engine.config.selectedModelID != selectedModelID

        engine.config.maxTokens = Int(maxTokens)
        engine.config.topK = Int(topK)
        engine.config.topP = topP
        engine.config.temperature = temperature
        engine.config.systemPrompt = systemPrompt

        // 同步采样参数到 LLM（下次生成立即生效）
        engine.applySamplingConfig()

        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }),
              engine.llm.isModelAvailable(selectedModel) else {
            if let missingModel = engine.availableModels.first(where: { $0.id == selectedModelID }) {
                engine.llm.statusMessage = localized("请先在配置中下载 ", "Please download ")
                    + missingModel.displayName
                    + localized(" 模型", " first")
            }
            return false
        }

        engine.config.selectedModelID = selectedModelID
        let needsLoad = !engine.llm.isLoaded || engine.llm.loadedModelID != selectedModelID
        if modelChanged || needsLoad {
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
