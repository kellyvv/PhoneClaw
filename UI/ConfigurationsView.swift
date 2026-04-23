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

    // 本地编辑状态（确认后才应用）
    @State private var selectedModelID = ModelDescriptor.defaultModel.id
    @State private var preferredBackend: String = "gpu"   // "gpu" / "cpu"
    @State private var systemPrompt: String = ""
    @State private var permissionStatuses: [AppPermissionKind: AppPermissionStatus] = [:]
    @State private var requestingPermission: AppPermissionKind?
    @State private var liveDownloader = LiveModelDownloader()

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
                    Button {
                        showSkillsManager = true
                    } label: {
                        Label(localized("Skills", "Skills"), systemImage: "puzzlepiece.extension")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

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
        .sheet(isPresented: $showSkillsManager) {
            SkillsManagerView(engine: engine)
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
                backendSection
                liveModelSection
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

            Text(engine.inference.isLoaded
                 ? localized("当前已加载：", "Loaded: ") + engine.catalog.modelDisplayName
                 : engine.inference.statusMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 10) {
                ForEach(engine.availableModels) { model in
                    let state = engine.installer.installState(for: model.id)
                    let isDownloading: Bool = {
                        if case .downloading = state { return true }
                        return false
                    }()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(model.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.textTertiary)
                                // 模型定位提示 — 用户通常只装一个, 不做"请切换 X" 的无效建议,
                                // 直接声明各自能力边界, 让用户基于场景选一个。
                                if model.id.contains("e2b") {
                                    Text("轻量款 · 聊天 / 翻译 / 单轮查询。多轮工具对话能力有限。")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.top, 2)
                                } else if model.id.contains("e4b") {
                                    Text("完整款 · 多轮工具对话 + 复杂 agent 能力。更吃存储。")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.top, 2)
                                }
                            }

                            Spacer()

                            if isDownloading {
                                if selectedModelID == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            } else {
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
                        }

                        if case let .downloading(completedFiles, totalFiles, _) = state {
                            downloadProgressBadge(
                                modelID: model.id,
                                completedFiles: completedFiles,
                                totalFiles: totalFiles
                            )
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

    // MARK: - 推理 Backend (GPU / CPU)

    /// 按 model + backend 实测/估算的 decode tok/s.
    /// - E2B: iPhone 17 Pro Max 实测
    /// - E4B: GPU 实测, CPU 按 E2B 比例推算
    private var estimatedSpeedText: String {
        let isE4B = selectedModelID.contains("e4b")
        let fastLabel = localized("较快", "fast")
        let slowLabel = localized("较慢", "slower")
        switch (preferredBackend, isE4B) {
        case ("gpu", false): return localized("E2B · 推理速度 ~25 tok/s (\(fastLabel))",
                                               "E2B · Inference ~25 tok/s (\(fastLabel))")
        case ("gpu", true):  return localized("E4B · 推理速度 ~20 tok/s (\(fastLabel))",
                                               "E4B · Inference ~20 tok/s (\(fastLabel))")
        case ("cpu", false): return localized("E2B · 推理速度 ~8 tok/s (\(slowLabel))",
                                               "E2B · Inference ~8 tok/s (\(slowLabel))")
        case ("cpu", true):  return localized("E4B · 推理速度 ~4 tok/s (\(slowLabel))",
                                               "E4B · Inference ~4 tok/s (\(slowLabel))")
        default:             return ""
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("推理后端", "Inference Backend"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Picker(localized("推理后端", "Inference Backend"), selection: $preferredBackend) {
                Text("GPU (Metal)").tag("gpu")
                Text("CPU").tag("cpu")
            }
            .pickerStyle(.segmented)

            // 当前 model + backend 组合下的速度 (随 model/backend 选择动态变化)
            Text(estimatedSpeedText)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            // 始终可见的内存提醒
            Label(
                localized(
                    "低内存手机建议选 CPU — GPU 占内存较高。",
                    "Low-memory devices: prefer CPU — GPU uses significantly more memory."
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    // MARK: - LIVE 语音模型

    private var liveModelSection: some View {
        let state = liveDownloader.installState
        let isDownloading: Bool = {
            if case .downloading = state { return true }
            return false
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("LIVE 语音模型", "LIVE Voice Models"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(localized(
                        "LIVE 实时语音模式需要的模型。",
                        "Required for LIVE real-time voice mode."
                    ))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                }

                Spacer()

                if !isDownloading {
                    VStack(alignment: .trailing, spacing: 8) {
                        liveModelStateButton
                    }
                }
            }

            if case let .downloading(completedFiles, totalFiles, _) = state {
                liveDownloadProgressView(
                    completedFiles: completedFiles,
                    totalFiles: totalFiles
                )
            }

            if let detail = liveStateDetail(state) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(state.isFailure ? Theme.accent : Theme.textTertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var liveModelStateButton: some View {
        switch liveDownloader.installState {
        case .notInstalled:
            Button(localized("下载", "Download")) {
                Task { await liveDownloader.downloadAll() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        case .checkingSource:
            modelBadge(localized("检查中", "Checking"))
        case .downloading:
            EmptyView()
        case .downloaded:
            modelBadge(localized("已下载", "Downloaded"), color: Theme.accentGreen)
        case .bundled:
            modelBadge(localized("内置", "Bundled"), color: Theme.accentGreen)
        case .failed:
            Button(localized("重试", "Retry")) {
                Task { await liveDownloader.downloadAll() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        }
    }

    private func liveDownloadProgressView(
        completedFiles: Int,
        totalFiles: Int
    ) -> some View {
        let safeTotal = max(totalFiles, 1)
        let value = Double(min(completedFiles, safeTotal))
        let metrics = liveDownloader.downloadMetrics

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized(
                        "下载中 \(completedFiles)/\(totalFiles)",
                        "Downloading \(completedFiles)/\(totalFiles)"
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                    if let metrics {
                        Text(liveDownloadMetricsText(metrics))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(localized("取消", "Cancel")) {
                    liveDownloader.cancelDownload()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.bg, in: Capsule())
                .fixedSize(horizontal: true, vertical: true)
            }

            ProgressView(value: value, total: Double(safeTotal))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.textTertiary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveDownloadMetricsText(_ metrics: ModelDownloadMetrics) -> String {
        let speedText = formattedSpeed(metrics.bytesPerSecond)
        if let totalBytes = metrics.totalBytes, totalBytes > 0 {
            return "\(formattedBytes(metrics.bytesReceived)) / \(formattedBytes(totalBytes)) · \(speedText)"
        }
        return "\(formattedBytes(metrics.bytesReceived)) · \(speedText)"
    }

    private func liveStateDetail(_ state: ModelInstallState) -> String? {
        switch state {
        case .notInstalled:
            return localized("未安装 (~\(LiveModelDefinition.estimatedSizeMB)MB)", "Not installed (~\(LiveModelDefinition.estimatedSizeMB)MB)")
        case .downloaded:
            return localized("已下载到手机本地。", "Downloaded to device.")
        case .failed(let msg):
            return msg
        default:
            return nil
        }
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

    @ViewBuilder
    private func modelStateControl(for model: ModelDescriptor, state: ModelInstallState) -> some View {
        switch state {
        case .notInstalled:
            Button(localized("下载", "Download")) {
                selectedModelID = model.id
                Task {
                    try await engine.installer.install(model: model)
                    if engine.installer.artifactPath(for: model) != nil,
                       selectedModelID == model.id,
                       (!engine.inference.isLoaded || engine.catalog.loadedModel?.id != model.id) {
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
            downloadProgressBadge(
                modelID: model.id,
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        case .downloaded:
            modelBadge(localized("已下载", "Downloaded"), color: Theme.accentGreen)
        case .bundled:
            modelBadge(localized("内置", "Bundled"), color: Theme.accentGreen)
        case .failed:
            Button(localized("重试", "Retry")) {
                selectedModelID = model.id
                Task {
                    try await engine.installer.install(model: model)
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

    private func downloadProgressBadge(
        modelID: String,
        completedFiles: Int,
        totalFiles: Int
    ) -> some View {
        let safeTotal = max(totalFiles, 1)
        let value = Double(min(completedFiles, safeTotal))
        let metrics = engine.installer.downloadProgress[modelID]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized(
                        "下载中 \(completedFiles)/\(totalFiles)",
                        "Downloading \(completedFiles)/\(totalFiles)"
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                    if let metrics {
                        Text(downloadMetricsText(metrics))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(localized("取消", "Cancel")) {
                    engine.installer.cancelInstall(modelID: modelID)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.bg, in: Capsule())
                .fixedSize(horizontal: true, vertical: true)
            }

            ProgressView(value: value, total: Double(safeTotal))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.textTertiary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
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

    private func modelStateDetail(_ state: ModelInstallState) -> String? {
        switch state {
        case .notInstalled:
            return localized("未安装", "Not Installed")
        case .checkingSource:
            return localized("正在准备下载。", "Preparing download.")
        case .downloading:
            return nil
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

        if engine.installer.artifactPath(for: selectedModel) == nil {
            return localized("先下载选中的模型，再点击确定加载。", "Download the selected model first, then tap OK to load it.")
        }

        if selectedModelID == engine.catalog.selectedModel.id,
           engine.catalog.loadedModel?.id == selectedModelID,
           engine.inference.isLoaded {
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
        case .camera:
            return localized("摄像头", "Camera")
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
        case .camera:
            return localized("允许在 Live 模式中观察周围环境", "Allow camera access for Live mode visual grounding")
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
        engine.installer.refreshInstallStates()
        liveDownloader.refreshState()
        selectedModelID = engine.catalog.loadedModel?.id ?? engine.config.selectedModelID
        preferredBackend = engine.config.preferredBackend
        systemPrompt = engine.config.systemPrompt
        refreshPermissionStatuses()
    }

    private func applySettings() -> Bool {
        let modelChanged = engine.config.selectedModelID != selectedModelID
        let backendChanged = engine.config.preferredBackend != preferredBackend

        engine.config.systemPrompt = systemPrompt
        engine.config.preferredBackend = preferredBackend

        // 同步采样参数到 LLM (沿用 ModelConfig 默认值; 下次生成立即生效)
        engine.applySamplingConfig()

        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }),
              engine.installer.artifactPath(for: selectedModel) != nil else {
            if let missingModel = engine.availableModels.first(where: { $0.id == selectedModelID }) {
                engine.inference.statusMessage = localized("请先在配置中下载 ", "Please download ")
                    + missingModel.displayName
                    + localized(" 模型", " first")
            }
            return false
        }

        engine.config.selectedModelID = selectedModelID
        let needsLoad = !engine.inference.isLoaded || engine.catalog.loadedModel?.id != selectedModelID
        // backend 变更也要 reload — LiteRTLMEngine 在 load 时构造, backend 参数不可热切换。
        if modelChanged || backendChanged || needsLoad {
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
