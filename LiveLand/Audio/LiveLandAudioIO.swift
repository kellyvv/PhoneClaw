import Foundation
import AVFoundation

// MARK: - LiveLandAudioIO
//
// LiveLand input-only audio engine. It owns microphone capture, 16kHz conversion,
// idle detection, and interruption recovery.
//
// 架构:
//   inputNode ──permanent tap──▶ audioInputHandler (set by LiveLandVADService)
//
// Tap 在 engine.start() 前安装, 保证 buffer 正常流动。
// LiveLandVADService 通过 set/clear audioInputHandler 控制是否处理输入。

class LiveLandAudioIO {

    let engine = AVAudioEngine()

    /// VAD 通过设置此回调接收 16kHz mono Float32 采样。
    /// nil = 输入被忽略 (相当于 VAD 停止)。
    var audioInputHandler: (([Float]) -> Void)?

    /// Runtime transport 直接接收 16kHz mono AVAudioPCMBuffer，避免额外 Array 复制。
    var audioInputBufferHandler: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?

    /// 可视化层 — input（mic）侧：piggybacking VAD 已有的 16kHz [Float]
    /// 在 audioInputHandler 调用后立即触发，无额外分配
    var visualisationInputHandler: (([Float]) -> Void)?

    /// 可视化层 — input（mic）原始硬件侧：直接传 input tap 的原始 Float32 指针。
    /// 这条链不经过 16kHz 重采样，更接近原始 audio-orb 对原生输入节点做 AnalyserNode 的语义。
    var visualisationInputRawHandler: ((UnsafePointer<Float>, Int) -> Void)?

    /// Audio input idle detection — fires once when tap hasn't received
    /// new data for audioIdleTimeout seconds (e.g., mic muted, system interrupt).
    /// Edge-triggered: fires once per idle period, resets when audio resumes.
    var onAudioInputIdle: (() -> Void)?
    var audioIdleTimeout: TimeInterval = 3.0

    /// Idle detection state
    private var lastTapTime = CFAbsoluteTimeGetCurrent()
    private var idleTriggered = false
    private var idleCheckTask: Task<Void, Never>?

    /// 16kHz mono float32 — VAD/ASR 标准格式
    private let vadSampleRate: Double = 16000
    private var converter: AVAudioConverter?

    /// 中断恢复观察者
    private var interruptionObserver: Any?

    // MARK: - Lifecycle

    func start() throws {
        try Self.configureAndActivateAudioSession()
        try startEngine()
    }

    func startForLiveLand() async throws {
        try await Self.configureAndActivateAudioSessionOffMainThread()
        try startEngine()
    }

    private static func configureAndActivateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // LiveLand only records microphone input. Do not use .voiceChat or
        // inputNode voice processing here: that routes through VoiceProcessingIO,
        // which is meant for duplex call-style audio and can spam render errors
        // when there is no TTS/output reference path.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        try session.setActive(true)
    }

    private static func configureAndActivateAudioSessionOffMainThread() async throws {
        try await Task.detached(priority: .userInitiated) {
            try configureAndActivateAudioSession()
        }.value
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // 监听音频中断（下拉控制中心、来电、Siri 等）
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // ── Input path ──
        // Permanent tap: installed BEFORE engine.start() to guarantee buffer delivery.
        // Audio is converted to 16kHz mono and forwarded to audioInputHandler.
        let inputNode = engine.inputNode

        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[LiveLandAudioIO] Input-only session mode=\(session.mode.rawValue), voiceProcessing=\(inputNode.isVoiceProcessingEnabled)")
        print("[LiveLandAudioIO] Input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: vadSampleRate,
            channels: 1,
            interleaved: false
        )!
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        // 512-frame quantum keeps VAD semantics unchanged while improving
        // orb visualisation responsiveness versus the original 1024/4096 path.
        inputNode.installTap(onBus: 0, bufferSize: 512, format: hwFormat) { [weak self] buffer, time in
            guard let self else { return }

            // Update idle tracking BEFORE handler check — audio IS flowing
            // even if handler hasn't been set yet (during init)
            self.lastTapTime = CFAbsoluteTimeGetCurrent()
            self.idleTriggered = false

            if let rawHandler = self.visualisationInputRawHandler,
               let channelData = buffer.floatChannelData {
                rawHandler(channelData[0], Int(buffer.frameLength))
            }

            guard self.audioInputHandler != nil
                    || self.audioInputBufferHandler != nil
                    || self.visualisationInputHandler != nil
            else { return }
            guard let converter = self.converter else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.vadSampleRate / buffer.format.sampleRate
            )
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            self.audioInputBufferHandler?(converted, time)

            if let channelData = converted.floatChannelData {
                let count = Int(converted.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
                self.audioInputHandler?(samples)
                // 可视化层在 mic 路径上也保持常驻，避免被 VAD 状态机短路
                self.visualisationInputHandler?(samples)
            }
        }

        // Start idle checker — also auto-restarts engine if it was killed
        // (e.g. Control Center pull-down on iOS 26 doesn't fire interruptionNotification)
        lastTapTime = CFAbsoluteTimeGetCurrent()
        idleTriggered = false
        idleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // Check every 1s
                guard let self else { break }

                // Auto-restart engine if it stopped unexpectedly
                if !self.engine.isRunning {
                    do {
                        try await Self.configureAndActivateAudioSessionOffMainThread()
                        try self.engine.start()
                        self.lastTapTime = CFAbsoluteTimeGetCurrent()
                        self.idleTriggered = false
                        print("[LiveLandAudioIO] ✅ Engine auto-restarted")
                        continue
                    } catch {
                        print("[LiveLandAudioIO] ❌ Engine restart failed: \(error)")
                    }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - self.lastTapTime
                if elapsed > self.audioIdleTimeout, !self.idleTriggered {
                    self.idleTriggered = true  // Edge trigger — fire once
                    print("[LiveLandAudioIO] ⚠️ Audio input idle (\(String(format: "%.1f", elapsed))s)")
                    self.onAudioInputIdle?()
                }
            }
        }

        engine.prepare()
        try engine.start()

        print("[LiveLandAudioIO] Engine started (input tap installed)")
    }

    func stop() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        audioInputHandler = nil
        audioInputBufferHandler = nil
        visualisationInputHandler = nil
        visualisationInputRawHandler = nil
        idleCheckTask?.cancel()
        idleCheckTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("[LiveLandAudioIO] Engine stopped")
        print("[LiveLandAudioIO] stop() caller stack:")
        for symbol in Thread.callStackSymbols.prefix(8) {
            print("  \(symbol)")
        }
    }

    // MARK: - Audio Session Interruption

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            print("[LiveLandAudioIO] ⚠️ Audio session interrupted")
        case .ended:
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
                ?? true
            if shouldResume {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Self.configureAndActivateAudioSessionOffMainThread()
                        try engine.start()
                        print("[LiveLandAudioIO] ✅ Engine resumed after interruption")
                    } catch {
                        print("[LiveLandAudioIO] ❌ Failed to resume after interruption: \(error)")
                    }
                }
            }
        @unknown default:
            break
        }
    }
}
