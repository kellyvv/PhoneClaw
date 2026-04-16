import Foundation
import Accelerate

// MARK: - OrbAudioAnalyser
//
// 实时音频频率分析器，为 OrbSceneView 提供 16 个频率 bin（对应 audio-orb 的 AnalyserNode）。
//
// FFT 正确用法（vDSP_fft_zrip）：
//   对 N=32 个实数样本做实数 FFT，需先用 vDSP_ctoz 将时域样本
//   打包为 split-complex（偶数索引→realp，奇数索引→imagp），
//   再调用 vDSP_fft_zrip(log2n=5)，输出 16 个复数频率 bin。
//   直接把样本写进 realp/imagp=0 是错误的（会得到无意义的频谱）。
//
// 实时线程安全：全 UnsafeMutablePointer，无 CoW，os_unfair_lock 保护 64-byte pubPtr

final class OrbAudioAnalyser {

    // MARK: - 常量

    private let log2n:   vDSP_Length = 5   // 2^5 = 32 = fftSize
    private let fftSize: Int = 32
    private let halfN:   Int = 16          // N/2 = split-complex 元素数 = 输出 bin 数

    // MARK: - 预分配缓冲区（init 时全量分配，process() 零分配）

    private let fftSetup: FFTSetup

    /// 时域样本临时区（interleaved，用于 vDSP_ctoz 输入）
    private let interleavedBuf: UnsafeMutablePointer<Float>  // 32 floats

    /// Split-complex 实部（16 floats）
    private let realPtr: UnsafeMutablePointer<Float>
    /// Split-complex 虚部（16 floats）
    private let imagPtr: UnsafeMutablePointer<Float>
    /// 幅度工作区（16 floats）
    private let magPtr:  UnsafeMutablePointer<Float>
    /// dB 工作区（16 floats）
    private let dbPtr:   UnsafeMutablePointer<Float>
    /// 平滑后的 dB（16 floats）
    private let smoothPtr: UnsafeMutablePointer<Float>
    /// Blackman 窗（32 floats）— 更接近 WebAudio AnalyserNode 的频谱前处理
    private let windowPtr: UnsafeMutablePointer<Float>
    /// 发布区：CADisplayLink 读取（16 floats，0-255 scale）
    private let pubPtr:  UnsafeMutablePointer<Float>

    private var splitComplex: DSPSplitComplex

    // MARK: - 线程安全

    private var lock = os_unfair_lock_s()
    private var version: UInt64 = 0
    private let smoothingTimeConstant: Float
    private let minDecibels: Float = -100
    private let maxDecibels: Float = -30
    private let visualGain: Float
    private let envelopeGain: Float
    private let envelopeCoupling: Float
    private let envelopeMinDecibels: Float = -58
    private let envelopeMaxDecibels: Float = -18

    // MARK: - Init / Deinit

    init(
        visualGain: Float = 1.0,
        smoothingTimeConstant: Float = 0.8,
        envelopeGain: Float = 1.0,
        envelopeCoupling: Float = 0.0
    ) {
        self.visualGain = visualGain
        self.smoothingTimeConstant = smoothingTimeConstant
        self.envelopeGain = envelopeGain
        self.envelopeCoupling = envelopeCoupling
        fftSetup = vDSP_create_fftsetup(5, FFTRadix(FFT_RADIX2))!

        interleavedBuf = .allocate(capacity: 32)
        realPtr        = .allocate(capacity: 16)
        imagPtr        = .allocate(capacity: 16)
        magPtr         = .allocate(capacity: 16)
        dbPtr          = .allocate(capacity: 16)
        smoothPtr      = .allocate(capacity: 16)
        windowPtr      = .allocate(capacity: 32)
        pubPtr         = .allocate(capacity: 16)

        interleavedBuf.initialize(repeating: 0, count: 32)
        realPtr.initialize(repeating: 0, count: 16)
        imagPtr.initialize(repeating: 0, count: 16)
        magPtr.initialize(repeating:  0, count: 16)
        dbPtr.initialize(repeating: minDecibels, count: 16)
        smoothPtr.initialize(repeating: minDecibels, count: 16)
        for i in 0..<fftSize {
            let phase = (2 * Float.pi * Float(i)) / Float(fftSize - 1)
            windowPtr[i] = 0.42 - 0.5 * cosf(phase) + 0.08 * cosf(2 * phase)
        }
        pubPtr.initialize(repeating:  0, count: 16)

        splitComplex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        interleavedBuf.deallocate()
        realPtr.deallocate()
        imagPtr.deallocate()
        magPtr.deallocate()
        dbPtr.deallocate()
        smoothPtr.deallocate()
        windowPtr.deallocate()
        pubPtr.deallocate()
    }

    // MARK: - 音频线程 API（零分配）

    /// output path：直接接 AVAudioPCMBuffer.floatChannelData[0] 原始指针，无 Array 构造
    func process(pointer: UnsafePointer<Float>, count: Int) {
        let n = min(count, fftSize)
        guard n > 0 else { return }

        // ── Mic envelope（RMS） ──
        // 仅靠前三个 FFT bin 在 iOS voice processing 链路上对真人说话偏弱，
        // 所以额外提取一次真实音量包络，并在发布前注入到低频 bins。
        // 这样 orb 会像原版一样被“说话强度”直接推起来，而不只是依赖稀疏频谱。
        var rms: Float = 0
        vDSP_rmsqv(pointer, 1, &rms, vDSP_Length(count))
        let envelopeRange = envelopeMaxDecibels - envelopeMinDecibels
        let envelopeDb = 20 * log10f(max(rms, 1e-7))
        let envelopeNormalized = (envelopeDb - envelopeMinDecibels) / envelopeRange
        let envelopeByte = min(max(envelopeNormalized * 255 * envelopeGain, 0), 255)

        // ── Step 1: 取最近的 32 个采样 ──
        // WebAudio 的 AnalyserNode 分析的是“最新一帧”，不是当前回调开头的 32 个样本。
        vDSP_vclr(interleavedBuf, 1, vDSP_Length(fftSize))
        let sourceStart = count > fftSize ? pointer.advanced(by: count - fftSize) : pointer
        let destination = count >= fftSize
            ? interleavedBuf
            : interleavedBuf.advanced(by: fftSize - n)
        vDSP_mmov(sourceStart, destination, vDSP_Length(n), 1, 1, 1)

        // ── Step 2: Blackman window ──
        vDSP_vmul(interleavedBuf, 1, windowPtr, 1, interleavedBuf, 1, vDSP_Length(fftSize))

        // ── Step 3: vDSP_ctoz — 时域样本 → split-complex ──
        // 将 interleavedBuf 重新解释为 DSPComplex（每对相邻 float 构成一个复数），
        // 偶数索引样本 → realp，奇数索引样本 → imagp
        // 这是 vDSP_fft_zrip 正确的输入打包方式
        interleavedBuf.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
            // stride=1: 读 complexPtr[0]...[15]（共 16 个 DSPComplex，正好覆盖 32 floats）
            // stride=2 是错的: 会访问 complexPtr[16]...[30] 越界，读到 heap 上随机值
            vDSP_ctoz(complexPtr, 1, &splitComplex, 1, vDSP_Length(halfN))
        }

        // ── Step 4: N=32 点实数 FFT ──
        // 输入：16 个 split-complex 元素（打包自 32 个实数样本）
        // 输出：16 个频率 bin（DC 到 Nyquist）
        splitComplex.realp = realPtr
        splitComplex.imagp = imagPtr
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // ── Step 5: 幅度平方 → magPtr ──
        vDSP_zvmags(&splitComplex, 1, magPtr, 1, vDSP_Length(halfN))

        // ── Step 6: 近似 WebAudio AnalyserNode.getByteFrequencyData ──
        // 1. power -> magnitude
        // 2. 转 dB
        // 3. smoothingTimeConstant = 0.8
        // 4. min/max dB 映射到 0...255
        let range = maxDecibels - minDecibels
        for i in 0..<halfN {
            let magnitude = sqrtf(max(magPtr[i], 1e-12))
            let db = 20 * log10f(max(magnitude, 1e-12))
            dbPtr[i] = db
            let smoothed = smoothingTimeConstant * smoothPtr[i] + (1 - smoothingTimeConstant) * db
            smoothPtr[i] = smoothed
            let normalized = (smoothed - minDecibels) / range
            magPtr[i] = min(max(normalized * 255 * visualGain, 0), 255)
        }

        if envelopeCoupling > 0 {
            magPtr[0] = max(magPtr[0], envelopeByte * 0.95 * envelopeCoupling)
            magPtr[1] = max(magPtr[1], envelopeByte * 0.62 * envelopeCoupling)
            magPtr[2] = max(magPtr[2], envelopeByte * 0.42 * envelopeCoupling)
        }

        // ── Step 7: 写入发布区（临界区 = 64-byte memcpy，< 1μs） ──
        os_unfair_lock_lock(&lock)
        memcpy(pubPtr, magPtr, halfN * MemoryLayout<Float>.size)
        version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// input path：从已存在的 [Float] 进入（复用 VAD 路径已有分配，无新开销）
    func process(samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            process(pointer: base, count: buf.count)
        }
    }

    // MARK: - 主线程 API（CADisplayLink 60fps 调用）

    /// 读取单个 bin（0-255 scale，对应 JS data[index]）
    func bin(_ index: Int) -> Float {
        guard index < halfN else { return 0 }
        os_unfair_lock_lock(&lock)
        let v = pubPtr[index]
        os_unfair_lock_unlock(&lock)
        return v
    }

    /// 批量读取前三个 bin（displayLink 最常用入口，减少加锁次数）
    func topBins() -> (b0: Float, b1: Float, b2: Float) {
        os_unfair_lock_lock(&lock)
        let t = (pubPtr[0], pubPtr[1], pubPtr[2])
        os_unfair_lock_unlock(&lock)
        return t
    }

    /// 批量读取前三个 bin + 发布版本。
    /// Coordinator 可用 version 跳过无变化帧，避免每帧都跨进程 bridge 到 WKWebView。
    func snapshot3() -> (b0: Float, b1: Float, b2: Float, version: UInt64) {
        os_unfair_lock_lock(&lock)
        let snapshot = (pubPtr[0], pubPtr[1], pubPtr[2], version)
        os_unfair_lock_unlock(&lock)
        return snapshot
    }
}

// MARK: - OrbAnalyserFeed
//
// 原版 audio-orb 的 mic 视觉路径是：
//   MediaStreamSource -> GainNode -> AnalyserNode
// 同时录音发送链路再单独接 ScriptProcessor(256 frames)。
//
// 这里用固定 256-sample frame 把 16k mic 流喂给 OrbAudioAnalyser，
// 尽量贴近原版的输入节奏，而不是把任意大小的 ASR/VAD chunk 直接扔进去。

final class OrbAnalyserFeed {
    private let analyser: OrbAudioAnalyser
    private let frameSize: Int
    private let scratch: UnsafeMutablePointer<Float>
    private var fillCount: Int = 0

    init(analyser: OrbAudioAnalyser, frameSize: Int = 256) {
        self.analyser = analyser
        self.frameSize = frameSize
        self.scratch = .allocate(capacity: frameSize)
        self.scratch.initialize(repeating: 0, count: frameSize)
    }

    deinit {
        scratch.deallocate()
    }

    func process(samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard var source = buffer.baseAddress else { return }
            var remaining = buffer.count

            while remaining > 0 {
                let writable = min(frameSize - fillCount, remaining)
                memcpy(
                    scratch.advanced(by: fillCount),
                    source,
                    writable * MemoryLayout<Float>.size
                )
                fillCount += writable
                source = source.advanced(by: writable)
                remaining -= writable

                if fillCount == frameSize {
                    analyser.process(pointer: UnsafePointer(scratch), count: frameSize)
                    fillCount = 0
                }
            }
        }
    }
}
