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

    let llm: MLXLocalLLMService
    /// 用户在 SYSPROMPT.md 编辑的 system prompt（来自 AgentEngine.config.systemPrompt）。
    /// 透传到 LiveModeEngine，与 live voice 强约束拼接成完整 system prompt。
    let userSystemPrompt: String?

    @State private var liveEngine = LiveModeEngine()
    @State private var animatePulse = false
    @State private var camera = LiveCameraService()
    @State private var isCameraEnabled = false
    @State private var isCameraStarting = false

    private var accentColor: Color {
        switch liveEngine.state {
        case .idle: return Theme.textTertiary
        case .listening: return Theme.accentGreen
        case .recording: return Theme.accent
        case .processing: return Theme.accent
        case .speaking: return Theme.accentGreen
        }
    }

    private var headline: String {
        if liveEngine.statusMessage == "正在准备 Live" {
            return "正在准备"
        }
        switch liveEngine.state {
        case .idle: return "LIVE 未启动"
        case .listening: return "我在听"
        case .recording: return "正在听你说"
        case .processing: return "正在理解"
        case .speaking: return "正在回答"
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

            // ── 前景 UI 层 ──
            VStack(spacing: 0) {
                // ── 顶栏 ──
                topBar

                // ── 状态胶囊（顶栏下方） ──
                statusCapsule
                    .padding(.top, 12)

                Spacer()

                // ── 对话文字区 ──
                captionArea
                    .padding(.horizontal, 20)
                    .frame(maxHeight: 140)

                // ── 底部按钮 ──
                endButton
            }
        }
        .preferredColorScheme(.dark)
        .task {
            liveEngine.setup(llm: llm)
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

            Button(action: toggleCamera) {
                Image(systemName: isCameraEnabled ? "camera.fill" : "camera")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isCameraEnabled ? Theme.accent : .white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - 状态胶囊

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: liveIconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
                .contentTransition(.symbolEffect(.replace))

            Text(headline)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Group {
                if liveEngine.state == .speaking || liveEngine.state == .processing {
                    Text("可以直接打断")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                        .offset(y: 24)
                }
            }
        )
        .animation(.easeInOut(duration: 0.3), value: liveEngine.state)
    }

    // MARK: - 对话文字区

    private var captionArea: some View {
        VStack(spacing: 8) {
            // 用户文字（ASR 实时 / 最终转录）
            if let caption = realtimeCaption {
                userCaptionBubble(label: "识别中", text: caption, isLive: true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !liveEngine.lastTranscript.isEmpty {
                userCaptionBubble(label: "你", text: liveEngine.lastTranscript, isLive: false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // AI 回复
            if realtimeCaption == nil, !liveEngine.lastReply.isEmpty {
                replyCaptionBubble(text: liveEngine.lastReply)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: liveEngine.lastTranscript)
        .animation(.easeInOut(duration: 0.25), value: liveEngine.lastReply)
        .animation(.easeInOut(duration: 0.2), value: realtimeCaption)
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

    private var endButton: some View {
        Button(action: close) {
            HStack(spacing: 10) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("结束")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
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
