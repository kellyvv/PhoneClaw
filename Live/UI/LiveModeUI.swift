import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Live Mode 全屏界面

struct LiveModeView: View {
    @Binding var isPresented: Bool

    let inference: InferenceService
    let catalog: ModelCatalog
    /// 用户在 SYSPROMPT.md 编辑的 system prompt（来自 AgentEngine.config.systemPrompt）。
    /// 透传到 LiveModeEngine，与 live voice 强约束拼接成完整 system prompt。
    let userSystemPrompt: String?

    @State private var liveEngine = LiveModeEngine()
    @State private var animatePulse = false
    @State private var camera = LiveCameraService()
    @State private var isCameraEnabled = false
    @State private var isCameraStarting = false

    /// Live 进入前用户的模型 ID. 仅当 Live 内强制切 E2B 时才记下,
    /// 退出 Live 在 onDisappear 切回, 让 service 恢复用户偏好.
    /// UserDefaults 全程不动 — 用户在 Configurations 的持久化偏好不被 Live 污染.
    @State private var preLiveModelID: String? = nil

    private var accentColor: Color {
        switch liveEngine.state {
        case .idle: return Theme.textTertiary
        case .listening: return Theme.accentGreen
        case .recording: return Theme.accent
        case .processing: return Theme.accent
        case .speaking: return Theme.accentGreen
        }
    }

    private var isPreparingLive: Bool {
        liveEngine.statusMessage.hasPrefix("正在准备")
    }

    /// 基于 engine.state 的状态文字. 对齐原始设计 (6d0b310) ——
    /// "正在准备 Live" 特例放在 switch 之前, 覆盖任何 state 字面;
    /// 因为 engine.start() 启动瞬间就把 state 设成 .listening, 加载期间
    /// 这个特例是唯一能显示加载字面的路径.
    ///
    /// 相对原始版本两处增量 (都是你明确要求过的):
    ///   1. .idle 分支不再显示 "LIVE 未启动" (返回 nil)
    ///   2. "正在准备" 改叫 "正在加载"
    private var headline: String? {
        if isPreparingLive {
            return "正在加载"
        }
        switch liveEngine.state {
        case .idle:       return nil
        case .listening:  return "我在听"
        case .recording:  return "正在听你说"
        case .processing: return "正在理解"
        case .speaking:   return "正在回答"
        }
    }

    private var liveIconName: String {
        switch liveEngine.state {
        case .idle: return "waveform.slash"
        case .listening: return "ear.fill"
        case .recording: return "mic.fill"
        case .processing: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var realtimeCaption: String? {
        let trimmed = liveEngine.liveCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard liveEngine.state == .recording else { return nil }
        return trimmed
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── 最底层兜底色 ──
            // OrbSceneView 的 WKWebView 初始加载 (~100-300ms) 是透明的, 不给底色
            // 会穿到上一层 view 或系统背景造成白闪. 同时 Orb 在 "准备中" 期间会
            // 保持暗灰状态 (state == .idle), 这个底色也要和 Orb 暗态视觉连贯.
            Color(red: 0.08, green: 0.06, blue: 0.10)
                .ignoresSafeArea()

            // ── 背景层 ──
            if isCameraEnabled {
                CameraPreviewView(previewLayer: camera.previewLayer)
                    .ignoresSafeArea()
            } else {
                #if canImport(UIKit)
                OrbSceneView(
                    inputAnalyser: liveEngine.inputAnalyser,
                    outputAnalyser: liveEngine.outputAnalyser,
                    state: liveEngine.state
                )
                .ignoresSafeArea()
                #else
                OrbBackgroundView()
                    .ignoresSafeArea()
                #endif
            }

            // ── 加载蒙版 (Orb 之上、UI 之下) ──
            // Orb 本身永远用完整 active 参数渲染金色 (shader 一次编完, 0 race).
            // 用 SwiftUI 叠一层深黑完全遮住, 加载完 (statusMessage 被 engine 清空)
            // easeOut 淡出 —— 视觉效果就是 "黑 → 金" 过度, 和 shader 零耦合.
            // 相机模式下不蒙, 那时 Orb 已经被相机画面替换.
            if !isCameraEnabled {
                Color.black
                    .opacity(isPreparingLive ? 0.55 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.6), value: isPreparingLive)
            }

            // ── 前景 UI 层 ──
            VStack(spacing: 0) {
                // ── 顶栏 ──
                topBar

                Spacer()

                // ── 状态提示 (Orb 下方, 和文字信息聚在一起, 不干扰 Orb) ──
                statusCapsule
                    .padding(.bottom, 10)

                // ── 对话文字区 ──
                captionArea
                    .padding(.horizontal, 20)
                    .frame(maxHeight: 140)

                // ── 底部按钮 ──
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // E4B 在 Live 模式下物理超 jetsam (真机 2026-04-16 验证):
            //   E4B 权重 4 GB + Live runtime (TTS Keqing/AudioIO/VAD/Orb) ~800 MB
            //   + KV cache prefill 临时 buffer ~500 MB ≈ 5.3 GB baseline,
            //   推理任意 spike 都突破 jetsam 6144. 不论是否开摄像头.
            //
            // 强制切 E2B (~2.5 GB), Live runtime + 推理总 < 4.5 GB, 安全.
            // 退出 Live (LiveModeView 销毁) 后, 用户原选模型保留在 ChatUI 不丢.
            // 注意: 这是单向切换 — 我们不在 onDisappear 回切, 因为 Live 退出
            // 后用户回到 ChatUI 自己选, InferenceService 还是 E2B 没问题.
            // 如果用户想用 E4B 文本, 在 Configurations 里手动切回去即可.
            // E4B 在 Live 模式下物理超 jetsam, 强制切 E2B.
            if catalog.loadedModel?.id.contains("e4b") == true {
                print("[Live] ⚠️ E4B 在 Live 模式内存超限, 自动切到 E2B")
                _ = catalog.select(modelID: "gemma-4-e2b-it-litert")
                inference.unload()
                try? await inference.load(modelID: "gemma-4-e2b-it-litert")
            }
            liveEngine.setup(inference: inference)
            liveEngine.userSystemPrompt = userSystemPrompt
            await liveEngine.start()
        }
        .onAppear {
            animatePulse = true
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            camera.stop()
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            Task { await liveEngine.stop() }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        // 摄像头按钮已移到底部 bottomBar 里, 顶栏只留 X 关闭
        // (close 和底部"结束"功能等价, 都触发 close() — 给用户右上和左下两个退出入口)
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - 状态胶囊

    private var statusCapsule: some View {
        // 极简: 无图标, 极细字体 + condensed + tracking = 冷静的科技感
        // speaking/processing 时在主文字下方挂一行 "可以直接打断" 提示 (原始行为)
        Group {
            if let text = headline {
                VStack(spacing: 4) {
                    Text(text)
                        .font(.system(size: 14, weight: .thin))
                        .fontWidth(.condensed)
                        .tracking(2.0)
                        .foregroundStyle(.white.opacity(0.55))

                    if liveEngine.state == .speaking || liveEngine.state == .processing {
                        Text("可以直接打断")
                            .font(.system(size: 10, weight: .light, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: headline)
        .animation(.easeInOut(duration: 0.3), value: liveEngine.state)
    }

    // MARK: - 对话文字区

    /// 合并 realtime partial 和 final transcript 到"同一个 bubble"原地更新。
    /// 之前的设计在 barge-in 时 realtimeCaption 非空 → 干掉了 final bubble, 待
    /// realtimeCaption 清空又重新 mount final bubble, 哪怕文本和上一次 identical
    /// 也会播一次 transition 动画 — 用户感知就是"弹两次"。
    /// 现在只要有转写内容 (无论 live 还是 final) 都绑同一个 bubble 身份 (user-caption),
    /// SwiftUI 只会 diff 文本, 不会 unmount/remount. 同文本时视觉零变化.
    private var currentUserCaption: (label: String, text: String, isLive: Bool)? {
        if let caption = realtimeCaption {
            return (label: "识别中", text: caption, isLive: true)
        }
        let trimmed = liveEngine.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return (label: "你", text: trimmed, isLive: false)
        }
        return nil
    }

    // 色温方案: user 冷灰, AI 暖琥珀 (和 Orb 同色系, 说话时颜色呼应)
    private static let userCaptionColor = Color(white: 0.78)     // 冷中性灰
    private static let aiCaptionColor   = Color(red: 1.00, green: 0.72, blue: 0.40)  // 暖琥珀

    private var captionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 用户文字 — 冷灰
            if let current = currentUserCaption {
                Text(current.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Self.userCaptionColor.opacity(current.isLive ? 0.45 : 0.65))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.interpolate)
                    .id("user-caption")
                    .transition(.opacity)
            }

            // AI 回复 — 暖琥珀, 流式追加不加任何动画 (LLM 40ms/token, 任何 >0 的动画
            // duration 都会和下一帧更新碰撞; 直接随 lastReply 变化原样刷新, 天然是
            // "一个字一个字长出来"的打字机效果, 和 TTS 发声进度同步)
            if realtimeCaption == nil, !liveEngine.lastReply.isEmpty {
                Text(liveEngine.lastReply)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Self.aiCaptionColor.opacity(0.70))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("ai-reply")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 只对 user caption 做短动画 (它只变一次 partial → final);
        // AI reply 随 token 高频更新, 不加 animation value, 避免动画互相打断.
        .animation(.easeOut(duration: 0.18), value: currentUserCaption?.text)
    }

    // MARK: - 用户文字气泡

    @ViewBuilder
    private func userCaptionBubble(label: String, text: String, isLive: Bool) -> some View {
        HStack(spacing: 0) {
            // 左侧装饰竖线
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isLive ? Theme.accent : Theme.accent.opacity(0.6))
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent.opacity(0.8))

                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .contentTransition(.interpolate)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isCameraEnabled ? Color.black.opacity(0.45) : Color.white.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - AI 回复气泡

    @ViewBuilder
    private func replyCaptionBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                (isCameraEnabled ? Color.black.opacity(0.5) : Color.white.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentTransition(.interpolate)
    }

    // MARK: - 底部按钮

    private var bottomBar: some View {
        // 双按钮: 左 = 摄像头 toggle, 右 = 结束 Live.
        // 左按钮承担两个状态 (开/关), 文案随 isCameraEnabled 变化.
        HStack(spacing: 12) {
            // 左: 摄像头开关
            Button(action: toggleCamera) {
                HStack(spacing: 8) {
                    Image(systemName: isCameraEnabled ? "camera.fill" : "camera")
                        .font(.system(size: 14, weight: .bold))
                    Text(isCameraEnabled ? "关闭摄像头" : "开摄像头")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(isCameraEnabled ? Theme.accent : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)

            // 右: 结束 Live
            Button(action: close) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("结束")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .padding(.top, 16)
    }

    // MARK: - Actions

    private func close() {
        camera.stop()
        Task {
            await liveEngine.stop()
            isPresented = false
        }
    }

    private func toggleCamera() {
        if isCameraEnabled {
            camera.stop()
            liveEngine.frameProvider = nil
            isCameraEnabled = false
        } else {
            guard !isCameraStarting else { return }
            isCameraStarting = true
            Task {
                defer { isCameraStarting = false }
                let ok = await camera.start()
                if ok {
                    liveEngine.frameProvider = { [camera] in camera.captureLatestFrame() }
                    isCameraEnabled = true
                } else {
                    print("[Live] Camera start failed — permission denied or device unavailable")
                }
            }
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

#if canImport(UIKit)
private class CameraPreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView(previewLayer: previewLayer)
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}
#endif
