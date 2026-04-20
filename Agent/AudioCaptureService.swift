import AVFoundation
import Foundation
import Observation

struct AudioCaptureSnapshot: Sendable {
    let pcm: [Float]
    let sampleRate: Double
    let channelCount: Int
    let duration: TimeInterval
}

@MainActor
@Observable
final class AudioCaptureService: NSObject, @preconcurrency AVAudioRecorderDelegate {
    private static let preferredSampleRate: Double = 16_000

    var permissionStatus: AppPermissionStatus = .notDetermined
    var isCapturing = false
    var duration: TimeInterval = 0
    var peakLevel: Float = 0
    var statusText = ""
    var lastErrorMessage: String?

    // AVAudioRecorder 直接录到文件 —— 与文件导入走完全相同的解码路径
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var decodedSnapshot: AudioCaptureSnapshot?

    override init() {
        super.init()
        refreshPermissionStatus()
    }

    // MARK: - 旧接口兼容属性 (UI 仍然读这些)
    var sampleRate: Double { Self.preferredSampleRate }
    var channelCount: Int { 1 }
    var capturedSampleCount: Int { Int(duration * Self.preferredSampleRate) }
    var bufferedSampleCount: Int { capturedSampleCount }

    func refreshPermissionStatus() {
        switch audioSession.recordPermission {
        case .granted:
            permissionStatus = .granted
        case .denied:
            permissionStatus = .denied
        case .undetermined:
            permissionStatus = .notDetermined
        @unknown default:
            permissionStatus = .restricted
        }
    }

    @discardableResult
    func toggleCapture() async -> Bool {
        if isCapturing {
            stopCapture()
            return true
        } else {
            return await startCapture()
        }
    }

    @discardableResult
    func startCapture() async -> Bool {
        refreshPermissionStatus()
        if permissionStatus == .notDetermined {
            let granted = await requestPermission()
            guard granted else {
                lastErrorMessage = "麦克风权限未授予，无法开始录音。"
                return false
            }
        }

        guard permissionStatus.isGranted else {
            lastErrorMessage = "麦克风权限不可用，请到系统设置中开启。"
            return false
        }

        guard !isCapturing else { return true }

        lastErrorMessage = nil
        statusText = "准备录音..."
        decodedSnapshot = nil

        // 录音文件路径
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("mic_recording_\(UUID().uuidString).m4a")
        recordingURL = url

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try audioSession.setActive(true)

            // 录制为 AAC (M4A) — iOS 原生支持，高质量
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true
            rec.prepareToRecord()

            guard rec.record() else {
                lastErrorMessage = "AVAudioRecorder.record() 返回 false"
                return false
            }

            recorder = rec
            isCapturing = true
            duration = 0
            startMeterUpdates()
            return true
        } catch {
            stopCapture(deactivateSession: false)
            lastErrorMessage = "启动录音失败：\(error.localizedDescription)"
            statusText = lastErrorMessage ?? ""
            return false
        }
    }

    @discardableResult
    func stopCapture(deactivateSession: Bool = true) -> AudioCaptureSnapshot? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil

        if deactivateSession {
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        }

        isCapturing = false
        peakLevel = 0

        // 用与文件导入完全相同的路径解码录音文件
        if let url = recordingURL {
            do {
                let snapshot = try Self.decodeAudioFile(url: url)
                decodedSnapshot = snapshot
                statusText = String(
                    format: "已录制 %.1f 秒音频，可以直接发送给模型。",
                    snapshot.duration
                )
                print("[AudioCapture] Recording decoded: \(Int(snapshot.pcm.count)) samples @ \(Int(snapshot.sampleRate))Hz, \(String(format: "%.1f", snapshot.duration))s")
            } catch {
                lastErrorMessage = "录音解码失败: \(error.localizedDescription)"
                statusText = lastErrorMessage ?? ""
                print("[AudioCapture] Failed to decode recording: \(error)")
            }
            // 清理临时文件
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        return decodedSnapshot
    }

    func clearStatus() {
        statusText = ""
        lastErrorMessage = nil
    }

    func consumeLatestSnapshot() -> AudioCaptureSnapshot? {
        let snapshot = decodedSnapshot
        decodedSnapshot = nil
        clearStatus()
        return snapshot
    }

    func latestSnapshot() -> AudioCaptureSnapshot? {
        decodedSnapshot
    }

    // MARK: - Audio File Decoder (与 ContentView.decodeAudioFile 完全一致)

    /// 解码任意音频文件为 16kHz mono PCM Float
    static func decodeAudioFile(url: URL) throws -> AudioCaptureSnapshot {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

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

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioDecode", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create source buffer"])
        }
        try file.read(into: srcBuffer)

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

    // MARK: - Private

    private func requestPermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        refreshPermissionStatus()
        return granted
    }

    private func startMeterUpdates() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder, rec.isRecording else { return }
                rec.updateMeters()
                self.duration = rec.currentTime
                // 将 dB 转换为 0-1 范围的 peak level
                let avgPower = rec.averagePower(forChannel: 0)
                let peakPower = rec.peakPower(forChannel: 0)
                // dB 范围通常 -160 到 0, 映射到 0-1
                let normalizedPeak = max(0, min(1, (peakPower + 50) / 50))
                self.peakLevel = normalizedPeak
                self.updateStatusText()
            }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func updateStatusText() {
        guard isCapturing else { return }
        statusText = String(
            format: "录音中 %.1f 秒",
            duration
        )
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor in
                self.lastErrorMessage = "录音意外终止"
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.lastErrorMessage = "录音编码错误: \(error?.localizedDescription ?? "未知")"
        }
    }
}
