import Foundation
import AVFoundation

// MARK: - LiveAudioIO
//
// 共享音频引擎: 麦克风输入 (VAD) 和 TTS 输出都走同一个 AVAudioEngine。
// 这是 AEC (回声消除) 正常工作的前提 — iOS 需要知道输出信号才能从输入中消除它。
//
// 架构:
//   inputNode ──permanent tap──▶ audioInputHandler (set by VADService)
//   playerNode ──▶ mainMixerNode ──▶ outputNode (speaker)
//
// Tap 在 engine.start() 前安装, 保证 buffer 正常流动。
// VADService 通过 set/clear audioInputHandler 控制是否处理输入。

class LiveAudioIO {

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

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

    /// 可视化层 — output（TTS）侧：直接传 AVAudioPCMBuffer 原始指针，零 Array 分配
    /// 签名与 output analyser 的 process(pointer:count:) 匹配
    var visualisationOutputHandler: ((UnsafePointer<Float>, Int) -> Void)?

    /// Audio input idle detection — fires once when tap hasn't received
    /// new data for audioIdleTimeout seconds (e.g., mic muted, system interrupt).
    /// Edge-triggered: fires once per idle period, resets when audio resumes.
    var onAudioInputIdle: (() -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onPlaybackStopped: (() -> Void)?
    var audioIdleTimeout: TimeInterval = 3.0

    /// TTS 播放状态
    private(set) var isPlaying = false

    private let continuationLock = NSLock()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Idle detection state
    private var lastTapTime = CFAbsoluteTimeGetCurrent()
    private var idleTriggered = false
    private var idleCheckTask: Task<Void, Never>?

    /// 16kHz mono float32 — VAD/ASR 标准格式
    private let vadSampleRate: Double = 16000
    /// TTS 输出格式 (sherpa-onnx keqing = 22050Hz mono)
    private let playbackSampleRate: Double = 22050
    private var converter: AVAudioConverter?

    /// 中断恢复观察者
    private var interruptionObserver: Any?

    // MARK: - Lifecycle

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        // 监听音频中断（下拉控制中心、来电、Siri 等）
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // ── Output path ──
        // Connect ONCE with a fixed format. Never reconnect during playback —
        // reconnecting disrupts AEC's reference signal tracking.
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // ── Input path ──
        // Permanent tap: installed BEFORE engine.start() to guarantee buffer delivery.
        // Audio is converted to 16kHz mono and forwarded to audioInputHandler.
        let inputNode = engine.inputNode

        // Explicitly enable voice processing (AEC + AGC + noise suppression).
        // This is how iOS cancels the playerNode's output from the mic input.
        try inputNode.setVoiceProcessingEnabled(true)
        inputNode.isVoiceProcessingBypassed = false
        inputNode.isVoiceProcessingAGCEnabled = true

        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioIO] VP enabled=\(inputNode.isVoiceProcessingEnabled) bypassed=\(inputNode.isVoiceProcessingBypassed) AGC=\(inputNode.isVoiceProcessingAGCEnabled)")
        print("[AudioIO] Input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

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
                        try AVAudioSession.sharedInstance().setActive(true)
                        try self.engine.start()
                        self.lastTapTime = CFAbsoluteTimeGetCurrent()
                        self.idleTriggered = false
                        print("[AudioIO] ✅ Engine auto-restarted")
                        continue
                    } catch {
                        print("[AudioIO] ❌ Engine restart failed: \(error)")
                    }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - self.lastTapTime
                if elapsed > self.audioIdleTimeout, !self.idleTriggered {
                    self.idleTriggered = true  // Edge trigger — fire once
                    print("[AudioIO] ⚠️ Audio input idle (\(String(format: "%.1f", elapsed))s)")
                    self.onAudioInputIdle?()
                }
            }
        }

        engine.prepare()
        try engine.start()

        // ── Output visualisation tap（mixer output 侧，TTS 播放时触发） ──
        // mixer 在 voiceProcessing 模式下只接收 playerNode 输出（纯净 TTS 信号）
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: mixerFormat) {
            [weak self] buffer, _ in
            guard let handler = self?.visualisationOutputHandler,
                  let channelData = buffer.floatChannelData else { return }
            // 直接传原始指针，零 Array 构造
            handler(channelData[0], Int(buffer.frameLength))
        }

        print("[AudioIO] Engine started (tap installed, duplex ready)")
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
        visualisationOutputHandler = nil
        onPlaybackStarted = nil
        onPlaybackStopped = nil
        idleCheckTask?.cancel()
        idleCheckTask = nil
        playerNode.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        isPlaying = false
        resumeContinuation()
        print("[AudioIO] Engine stopped")
        print("[AudioIO] stop() caller stack:")
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
            print("[AudioIO] ⚠️ Audio session interrupted")
        case .ended:
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
                ?? true
            if shouldResume {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try engine.start()
                    print("[AudioIO] ✅ Engine resumed after interruption")
                } catch {
                    print("[AudioIO] ❌ Failed to resume after interruption: \(error)")
                }
            }
        @unknown default:
            break
        }
    }

    // MARK: - Output (for TTS)

    func playWAV(_ wavData: Data) async {
        guard let buffer = wavDataToPCMBuffer(wavData) else {
            print("[AudioIO] ❌ Failed to parse WAV data")
            return
        }

        await playBuffer(buffer)
    }

    func playBuffer(_ buffer: AVAudioPCMBuffer) async {
        if playerNode.engine == nil {
            let playbackFormat = buffer.format
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        }

        // Do NOT reconnect playerNode here — connection is fixed in start().
        // Reconnecting disrupts AEC reference signal tracking.
        playerNode.stop()
        isPlaying = true

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuationLock.withLock {
                self.playbackContinuation = continuation
            }
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.isPlaying = false
                print("[AudioIO] ✅ Playback done")
                self.onPlaybackStopped?()
                self.resumeContinuation()
            }
            playerNode.play()
            // 回调在 play() 之后触发 — 此时音频已开始播放
            onPlaybackStarted?()
        }
    }

    func stopPlayback() {
        playerNode.stop()
        isPlaying = false
        onPlaybackStopped?()
        resumeContinuation()
    }

    // MARK: - Continuation

    private func resumeContinuation() {
        continuationLock.withLock {
            let c = playbackContinuation
            playbackContinuation = nil
            c?.resume()
        }
    }

    // MARK: - WAV → AVAudioPCMBuffer

    private func wavDataToPCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44 else { return nil }

        let sampleRate: UInt32 = data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 24, as: UInt32.self)
        }

        let pcmData = data.dropFirst(44)
        let sampleCount = pcmData.count / 2

        guard sampleCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Double(sampleRate),
                                          channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(sampleCount))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(sampleCount)

        let floatData = buffer.floatChannelData![0]
        pcmData.withUnsafeBytes { ptr in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floatData[i] = Float(int16Ptr[i]) / 32767.0
            }
        }

        return buffer
    }
}
