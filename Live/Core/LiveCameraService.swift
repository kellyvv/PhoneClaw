import AVFoundation
import CoreImage

// MARK: - Live Camera Service
//
// AVCaptureSession + 定时抽帧。
// 所有 session 操作（配置/启动/停止/移除）串行到 captureQueue。
// 快照通过 NSLock 保护，captureLatestFrame() 可从任意线程调用。

final class LiveCameraService: NSObject {

    // MARK: - Public State

    private(set) var isRunning = false
    /// 启动中标记，防止并发 start
    private(set) var isStarting = false
    /// stop() 被调用时置 true，让 in-flight start 在下一个检查点放弃
    private var isCancelled = false

    // MARK: - Frame Snapshot

    struct FrameSnapshot {
        let image: CIImage
        let capturedAt: CFAbsoluteTime
    }

    private let snapshotLock = NSLock()
    private var latestSnapshot: FrameSnapshot?
    private let freshnessWindow: TimeInterval = 6.0

    // MARK: - AVCapture

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.phoneclaw.livecam", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var rawBuffer: CMSampleBuffer?    // 最新原始帧，captureQueue 上写
    private let rawBufferLock = NSLock()

    // MARK: - Timer

    private var frameTimer: DispatchSourceTimer?
    private let captureInterval: TimeInterval = 3.0
    private let maxFrameSize: CGFloat = 768

    // MARK: - Preview

    private(set) lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    // MARK: - Start / Stop

    /// 异步启动摄像头。返回 true 表示成功，false 表示设备不可用或权限被拒。
    func start(position: AVCaptureDevice.Position = .back) async -> Bool {
        guard !isRunning, !isStarting else { return isRunning }
        isStarting = true
        isCancelled = false
        defer { isStarting = false }

        // 1. 检查权限
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                print("[LiveCam] ❌ Camera permission denied by user")
                return false
            }
        case .authorized:
            break
        default:
            print("[LiveCam] ❌ Camera permission status: \(status.rawValue)")
            return false
        }

        // 检查点：权限弹窗期间 stop() 可能已被调用
        guard !isCancelled else {
            print("[LiveCam] Start cancelled during permission")
            return false
        }

        // 2. 获取设备
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            print("[LiveCam] ❌ No camera device for position \(position.rawValue)")
            return false
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            print("[LiveCam] ❌ Camera input error: \(error)")
            return false
        }

        // 3. 配置 + 启动全部在 captureQueue 上串行执行
        let success = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            captureQueue.async { [weak self] in
                guard let self, !self.isCancelled else {
                    cont.resume(returning: false)
                    return
                }

                self.session.beginConfiguration()
                self.session.sessionPreset = .medium

                guard self.session.canAddInput(input) else {
                    print("[LiveCam] ❌ Cannot add camera input")
                    self.session.commitConfiguration()
                    cont.resume(returning: false)
                    return
                }
                self.session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                guard self.session.canAddOutput(output) else {
                    print("[LiveCam] ❌ Cannot add video output")
                    self.session.commitConfiguration()
                    cont.resume(returning: false)
                    return
                }
                self.session.addOutput(output)
                self.videoOutput = output

                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                }

                self.session.commitConfiguration()

                // 最后检查：配置完成后 stop() 可能已被调用
                guard !self.isCancelled else {
                    self.teardownSession()
                    cont.resume(returning: false)
                    return
                }

                self.session.startRunning()
                cont.resume(returning: true)
            }
        }

        // 检查点：captureQueue 完成后再次确认
        guard success, !isCancelled else {
            if success {
                // session 已启动但被取消，需要停掉
                captureQueue.async { [weak self] in self?.teardownSession() }
            }
            return false
        }

        startFrameTimer()
        isRunning = true
        print("[LiveCam] ✅ Camera started (position=\(position.rawValue), interval=\(captureInterval)s)")
        return true
    }

    func stop() {
        // 无条件设 cancelled，让 in-flight start 在下一个检查点放弃
        isCancelled = true

        guard isRunning else { return }
        isRunning = false

        // 停 timer
        frameTimer?.cancel()
        frameTimer = nil

        // 停 session + 移除 inputs/outputs — 全部在 captureQueue 上串行
        captureQueue.async { [weak self] in
            self?.teardownSession()
        }

        // 清快照
        snapshotLock.lock()
        latestSnapshot = nil
        snapshotLock.unlock()

        rawBufferLock.lock()
        rawBuffer = nil
        rawBufferLock.unlock()

        print("[LiveCam] Camera stopped")
    }

    /// captureQueue 上调用：停 session + 清 input/output
    private func teardownSession() {
        session.stopRunning()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoOutput = nil
    }

    // MARK: - Public: 取帧（线程安全）

    /// 取最新帧。帧在 freshnessWindow 内可复用，不会被清空。
    func captureLatestFrame() -> CIImage? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard let snap = latestSnapshot,
              CFAbsoluteTimeGetCurrent() - snap.capturedAt < freshnessWindow
        else { return nil }
        return snap.image
    }

    // MARK: - Private: Timer

    private func startFrameTimer() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: captureInterval)
        timer.setEventHandler { [weak self] in
            self?.processRawBufferToSnapshot()
        }
        timer.resume()
        frameTimer = timer
    }

    private func processRawBufferToSnapshot() {
        rawBufferLock.lock()
        let buffer = rawBuffer
        rawBufferLock.unlock()

        guard let buffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // 方向归一化：从 sample buffer 中读取方向并应用到 CIImage
        // （connection 已设为 portrait，但保险起见处理元数据）
        if let orientationRaw = CMGetAttachment(buffer, key: kCGImagePropertyOrientation, attachmentModeOut: nil) as? UInt32,
           let cgOrientation = CGImagePropertyOrientation(rawValue: orientationRaw) {
            ciImage = ciImage.oriented(cgOrientation)
        }

        // 缩放到 maxFrameSize
        let extent = ciImage.extent
        let maxDim = max(extent.width, extent.height)
        if maxDim > maxFrameSize {
            let scale = maxFrameSize / maxDim
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let snapshot = FrameSnapshot(image: ciImage, capturedAt: CFAbsoluteTimeGetCurrent())
        snapshotLock.lock()
        latestSnapshot = snapshot
        snapshotLock.unlock()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension LiveCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 只缓存最新一帧（captureQueue 上执行）
        rawBufferLock.lock()
        rawBuffer = sampleBuffer
        rawBufferLock.unlock()
    }
}
