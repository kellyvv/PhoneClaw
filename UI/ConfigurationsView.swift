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
    @State private var preferredBackend: String = "cpu"   // "gpu" / "cpu"
    @State private var enableSpeculativeDecoding: Bool = false
    @State private var systemPrompt: String = ""
    @State private var permissionStatuses: [AppPermissionKind: AppPermissionStatus] = [:]
    @State private var requestingPermission: AppPermissionKind?
    @State private var liveDownloader = LiveModelStore()
    @State private var didLoadCurrentSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab 切换
                HStack(spacing: 0) {
                    tabButton(tr("模型设置", "Model Settings"), tag: 0)
                    tabButton(tr("系统提示词", "System Prompt"), tag: 1)
                    tabButton(tr("权限", "Permissions"), tag: 2)
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
                        Label(tr("Skills", "Skills"), systemImage: "puzzlepiece.extension")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Button(tr("取消", "Cancel")) { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                    Button(tr("确定", "OK")) {
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
            .navigationTitle(tr("配置", "Configurations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Theme.bgElevated)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didLoadCurrentSettings else { return }
            didLoadCurrentSettings = true
            loadCurrentSettings()
        }
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
                languageSection
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
                        .allowsHitTesting(false)
                )

            Button(tr("恢复默认", "Restore Default")) {
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
            Text(tr("模型", "Model"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(modelHeaderText)
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
                                    Text(tr(
                                        "轻量款 · 聊天 / 翻译 / 单轮查询。多轮工具对话能力有限。",
                                        "Lightweight · chat / translate / single-turn. Limited multi-turn tool use."
                                    ))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                        .padding(.top, 2)
                                } else if model.id.contains("e4b") {
                                    Text(tr(
                                        "完整款 · 多轮工具对话 + 复杂 agent 能力。更吃存储。",
                                        "Full · multi-turn tool use + complex agent. Uses more storage."
                                    ))
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

                        if let detail = modelStateDetail(state, modelID: model.id) {
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
                            .allowsHitTesting(false)
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
                .allowsHitTesting(false)
        )
    }

    private var modelHeaderText: String {
        if engine.isModelReady {
            return tr("当前已加载：", "Loaded: ") + engine.catalog.modelDisplayName
        }

        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }) else {
            return tr("请选择一个模型。", "Select a model.")
        }

        let state = engine.installer.installState(for: selectedModel.id)
        switch state {
        case .notInstalled:
            if engine.installer.hasResumableDownload(for: selectedModel.id) {
                return tr(
                    "可继续下载 \(selectedModel.displayName)",
                    "Resume \(selectedModel.displayName)"
                )
            }
            return tr(
                "请先下载模型",
                "Download a model first"
            )
        case .checkingSource:
            return tr(
                "准备下载 \(selectedModel.displayName)",
                "Preparing \(selectedModel.displayName)"
            )
        case .downloading:
            return tr(
                "正在下载 \(selectedModel.displayName)",
                "Downloading \(selectedModel.displayName)"
            )
        case .downloaded:
            return tr(
                "\(selectedModel.displayName) 已下载，点确定加载",
                "\(selectedModel.displayName) downloaded. Tap OK"
            )
        case .bundled:
            return tr(
                "\(selectedModel.displayName) 已内置",
                "\(selectedModel.displayName) bundled"
            )
        case .failed:
            return tr(
                "\(selectedModel.displayName) 下载失败",
                "\(selectedModel.displayName) download failed"
            )
        }
    }

    // MARK: - 推理 Backend (GPU / CPU)

    /// 当前选中模型的 family。用于 gate 那些只对特定家族有意义的 UI 控件
    /// (例如 MTP 推测解码只 Gemma 4 .litertlm 才有, MiniCPM-V 没有这个概念)。
    /// 找不到 descriptor 时返回 nil, 调用方按需 fallback。
    private var currentModelFamily: ModelFamily? {
        engine.availableModels.first(where: { $0.id == selectedModelID })?.family
    }

    /// 按 model + backend 实测/估算的 decode tok/s.
    /// - Gemma 4 E2B: iPhone 17 Pro Max 实测 (LiteRT-LM)
    /// - Gemma 4 E4B: GPU 实测, CPU 按 E2B 比例推算
    /// - MiniCPM-V 4.6: iPhone 17 Pro Max 实测 (llama.cpp Metal + ANE vision)
    ///   纯文本 ~10-15 tok/s, vision turn ~5-7 tok/s. 取保守中位数。
    ///   Hybrid Mamba/GDN op 在 Metal 上的优化不如纯 transformer GEMM 成熟, 比
    ///   Gemma 4 慢一半左右 (详见 LLM/Backends/MiniCPMV/MiniCPMVBackend.swift 注释)。
    private var estimatedSpeedText: String {
        let fastLabel = tr("较快", "fast")
        let slowLabel = tr("较慢", "slower")
        let mediumLabel = tr("中等", "medium")

        // MiniCPM-V 走独立分支 — model-family 一对应 (id 前缀 minicpm-v)。
        if selectedModelID.hasPrefix("minicpm-v") {
            switch preferredBackend {
            case "gpu":
                return tr("MiniCPM-V · 推理速度 ~10 tok/s (\(mediumLabel))",
                          "MiniCPM-V · Inference ~10 tok/s (\(mediumLabel))")
            case "cpu":
                return tr("MiniCPM-V · 推理速度 ~3 tok/s (\(slowLabel))",
                          "MiniCPM-V · Inference ~3 tok/s (\(slowLabel))")
            default:
                return ""
            }
        }

        // Gemma 4 (E2B / E4B) 原有逻辑保持。
        let isE4B = selectedModelID.contains("e4b")
        switch (preferredBackend, isE4B) {
        case ("gpu", false): return tr("E2B · 推理速度 ~25 tok/s (\(fastLabel))",
                                               "E2B · Inference ~25 tok/s (\(fastLabel))")
        case ("gpu", true):  return tr("E4B · 推理速度 ~20 tok/s (\(fastLabel))",
                                               "E4B · Inference ~20 tok/s (\(fastLabel))")
        case ("cpu", false): return tr("E2B · 推理速度 ~8 tok/s (\(slowLabel))",
                                               "E2B · Inference ~8 tok/s (\(slowLabel))")
        case ("cpu", true):  return tr("E4B · 推理速度 ~4 tok/s (\(slowLabel))",
                                               "E4B · Inference ~4 tok/s (\(slowLabel))")
        default:             return ""
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("推理后端", "Inference Backend"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            // 自己拼的 segmented control. 替代之前的 Picker(.segmented),
            // 因为后者在当前 iOS / SwiftUI 版本组合下死活不响应点击。
            // 用纯 Button 拼: 每个按钮自己 onTap 写 @State, 没有 SwiftUI Picker
            // 的 hit-test 黑魔法干扰. 视觉跟系统 segmented 接近但是显式控制。
            CustomSegmentedPicker(
                selection: $preferredBackend,
                options: [
                    (value: "gpu", label: "GPU (Metal)"),
                    (value: "cpu", label: "CPU"),
                ]
            )

            // 当前 model + backend 组合下的速度 (随 model/backend 选择动态变化)
            Text(estimatedSpeedText)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

            // 内存提醒 — 这条只对 Gemma 4 LiteRT GPU 路径成立。LiteRT GPU 模式
            // 会 pin ~800 MB 用于 Metal 张量, 跟 CPU 相比内存压力大很多, 低内存
            // 机型容易撞 jetsam 上限。
            // MiniCPM-V 走 llama.cpp Metal, Metal 缓存只用临时空间 (~500 MB 模型
            // 权重 mmap, KV 48 MB, compute buffer ~500 MB), 内存占用跟 CPU 接近,
            // 同时 GPU 速度比 CPU 快 ~3×。给 MiniCPM-V 用户看 "建议选 CPU 省内存"
            // 反而把人引导到差体验。所以这条 warning 只对 Gemma 4 显示。
            if currentModelFamily == .gemma4 {
                Label(
                    tr(
                        "低内存手机建议选 CPU — GPU 占内存较高。",
                        "Low-memory devices: prefer CPU — GPU is memory-heavy."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Gemma 4 MTP speculative decoding 仅对 Gemma 4 .litertlm 有效
            // (它的 mtp_drafter section 是模型一部分, 别的家族没有)。
            // MiniCPM-V / 未来其它家族进来后, 整段藏起来 — 别让用户看到一个
            // 点了 no-op 的开关误以为没生效。
            if currentModelFamily == .gemma4 {
                Divider().background(Theme.border).padding(.vertical, 2)

                // MTP speculative decoding. drafter 预测 K=3 个候选, verifier 一次接受/拒绝。
                //
                // 实测 (iPhone GPU + Metal, 2026-05): MTP 是不是净赢由两个独立闸门决定 —
                //   (1) drafter accept rate ≥ ~30% (E2B 中文 19% / 英文 29% 都不够,
                //       E4B 36% 才稳过算法层闸门);
                //   (2) 全程 headroom > ~1500 MB (长输出会让 KV cache 把 headroom 压垮,
                //       系统逼近 jetsam 阈值后 Metal 调度被限速, MTP 反而变慢)。
                //
                // 实测矩阵:
                //   E2B 中/英长输出 : -27% / -43% (卡闸门 1, 接受率不足)
                //   E4B 英文短输出  : +37%        (两个闸门都过)
                //   E4B 中文长输出  : -25%        (卡闸门 2, 内存压力)
                //
                // 默认关闭, 用户自行 opt-in。
                Toggle(isOn: $enableSpeculativeDecoding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("MTP 推测解码", "MTP speculative decoding"))
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text(tr(
                            "Gemma 4 E4B 短回复可能加速；E2B 或长回复反而变慢",
                            "Gemma 4 E4B + short replies may speed up; E2B or long replies slow down"
                        ))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.accent)
            }
        }
        .padding(16)
        // iOS 17/18: .background(_:in:) 让 Shape 注册成 hit-test 目标会吃掉
        // 内部 Picker 的点击. 改成 ZStack 把背景放底层 + clipShape 切角,
        // 背景不参与 hit testing, Picker 拿到完整触控.
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.bg)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Language

    /// Language preference picker — Auto (跟随系统) / 中文 / English。
    /// 读写 `LanguageService.shared.selected`, 绑定是直接的 Binding 封装
    /// (比 @Bindable + @Observable 的混搭更显式, 也不需要额外 @State 镜像)。
    /// 切换立即触发 SwiftUI observation, 整个 app 视图重渲染新语言。
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Config.language)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            // 同 backendSection: 用自定义 segmented control 替代 SwiftUI Picker.
            // setter 里只快速 set LanguageService 让 UI 立即重渲染拿到新文案;
            // 重活 (reload skill / 改 SYSPROMPT / 重置 statusMessage) 推到下个
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
                        //   5. inference.statusMessage: 存的是 tr() 当时的快照 string, 重写
                        Task { @MainActor in
                            _ = engine.skillRegistry.reloadAll()
                            engine.reloadSkills()
                            engine.loadSystemPrompt()
                            systemPrompt = engine.config.systemPrompt
                            if !engine.isModelReady {
                                if let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }),
                                   engine.installer.artifactPath(for: selectedModel) == nil {
                                    engine.inference.statusMessage = tr("请先下载模型", "Download a model first")
                                } else {
                                    engine.inference.statusMessage = tr("等待加载模型...", "Waiting to load model...")
                                }
                            }
                        }
                    }
                ),
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
            )

            Text(L10n.Config.languageFooter)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        // 同 backendSection: 避开 .background(_:in:) 吃 Picker 点击的 SwiftUI 行为
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.bg)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
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
                    Text(tr("LIVE 语音模型", "LIVE Voice Models"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(tr(
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
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var liveModelStateButton: some View {
        switch liveDownloader.installState {
        case .notInstalled:
            let completedAssets = liveDownloader.completedAssetCount
            let canResume = completedAssets > 0 || liveDownloader.resumableAssetCount > 0
            Button(canResume ? tr("继续下载", "Resume") : tr("下载", "Download")) {
                Task { await liveDownloader.downloadAll() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        case .checkingSource:
            modelBadge(tr("检查中", "Checking"))
        case .downloading:
            EmptyView()
        case .downloaded:
            Button(tr("删除", "Delete")) {
                Task { try? await liveDownloader.removeAll() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: Capsule())
        case .bundled:
            modelBadge(tr("内置", "Bundled"), color: Theme.accentGreen)
        case .failed:
            Button(tr("重试", "Retry")) {
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

                Button(tr("取消", "Cancel")) {
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
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("权限", "Permissions"))
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
                .allowsHitTesting(false)
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
                           ? tr("请求中...", "Requesting...")
                           : tr("请求权限", "Request Access")) {
                        requestPermission(kind)
                    }
                    .disabled(requestingPermission != nil)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                }

                Button(tr("去设置", "Open Settings")) {
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
            let isResumable = engine.installer.hasResumableDownload(for: model.id)
            Button(isResumable ? tr("继续下载", "Resume") : tr("下载", "Download")) {
                selectedModelID = model.id
                Task {
                    try await engine.installer.install(model: model)
                    if engine.installer.artifactPath(for: model) != nil,
                       selectedModelID == model.id,
                       (!engine.isModelReady || engine.catalog.loadedModel?.id != model.id) {
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
            modelBadge(tr("检查中", "Checking"))
        case .downloading(let completedFiles, let totalFiles, _):
            downloadProgressBadge(
                modelID: model.id,
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        case .downloaded:
            modelBadge(tr("已下载", "Downloaded"), color: Theme.accentGreen)
        case .bundled:
            modelBadge(tr("内置", "Bundled"), color: Theme.accentGreen)
        case .failed:
            Button(tr("重试", "Retry")) {
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
        let metrics = engine.installer.downloadProgress[modelID]
        let activeFileFraction = metrics?.fractionCompleted.map { min(1, max(0, $0)) } ?? 0
        let value = min(Double(safeTotal), Double(min(completedFiles, safeTotal)) + activeFileFraction)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(
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

                Button(tr("取消", "Cancel")) {
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

    private func modelStateDetail(_ state: ModelInstallState, modelID: String) -> String? {
        switch state {
        case .notInstalled:
            if engine.installer.hasResumableDownload(for: modelID) {
                if let metrics = engine.installer.downloadProgress[modelID] {
                    let progress = downloadMetricsText(metrics)
                    if !progress.isEmpty {
                        return tr("可继续下载 · \(progress)", "Ready to resume · \(progress)")
                    }
                }
                return tr("可继续下载", "Ready to resume")
            }
            return tr("未安装", "Not Installed")
        case .checkingSource:
            return tr("正在准备下载。", "Preparing download.")
        case .downloading:
            return nil
        case .downloaded:
            return tr("已下载到手机本地，可直接加载。", "Downloaded on device and ready to load.")
        case .bundled:
            return tr("模型已随 App 内置。", "This model is bundled inside the app.")
        case .failed(let message):
            return message
        }
    }

    private var modelFooterText: String {
        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }) else {
            return tr("点右侧按钮下载模型后再点击确定。", "Download a model first, then tap OK.")
        }

        if engine.installer.artifactPath(for: selectedModel) == nil {
            return tr("先下载选中的模型，再点击确定加载。", "Download the selected model first, then tap OK to load it.")
        }

        if selectedModelID == engine.catalog.selectedModel.id,
           engine.catalog.loadedModel?.id == selectedModelID,
           engine.isModelReady {
            return tr("点击确定会保留当前模型。", "Tap OK to keep the current model.")
        }

        return tr("点击确定后会卸载当前模型并重新加载新模型。", "Tap OK to unload the current model and reload the new one.")
    }

    // MARK: - 加载 / 应用

    private func permissionTitle(_ kind: AppPermissionKind) -> String {
        switch kind {
        case .microphone:
            return tr("麦克风", "Microphone")
        case .camera:
            return tr("摄像头", "Camera")
        case .calendar:
            return tr("日历", "Calendar")
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
        liveDownloader.refreshState()
        selectedModelID = engine.catalog.loadedModel?.id ?? engine.config.selectedModelID
        preferredBackend = engine.config.preferredBackend
        enableSpeculativeDecoding = engine.config.enableSpeculativeDecoding
        systemPrompt = engine.config.systemPrompt
        refreshPermissionStatuses()
    }

    private func applySettings() -> Bool {
        let modelChanged = engine.config.selectedModelID != selectedModelID
        let backendChanged = engine.config.preferredBackend != preferredBackend
        let mtpChanged = engine.config.enableSpeculativeDecoding != enableSpeculativeDecoding

        engine.config.systemPrompt = systemPrompt
        engine.config.preferredBackend = preferredBackend
        engine.config.enableSpeculativeDecoding = enableSpeculativeDecoding

        // 同步采样参数到 LLM (沿用 ModelConfig 默认值; 下次生成立即生效)
        engine.applySamplingConfig()

        guard let selectedModel = engine.availableModels.first(where: { $0.id == selectedModelID }),
              engine.installer.artifactPath(for: selectedModel) != nil else {
            engine.inference.statusMessage = tr("请先下载模型", "Download a model first")
            return false
        }

        engine.config.selectedModelID = selectedModelID
        let needsLoad = !engine.isModelReady || engine.catalog.loadedModel?.id != selectedModelID
        // backend / MTP 变更也要 reload — LiteRTLMEngine 在 load 时构造,
        // 这两个参数都不可热切换。
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
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            // 只有选中段渲染 thumb 背景, 用 matchedGeometryEffect
                            // 让它在不同 segment 之间连贯滑动.
                            ZStack {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.bgHover)
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
                .fill(Theme.bgElevated.opacity(0.6))
                .allowsHitTesting(false)
        )
    }
}
