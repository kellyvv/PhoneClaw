import Foundation
import MLX
import MLXLMCommon

struct Gemma4ExtractedAudioFeatures {
    let features: MLXArray
    let invalidMask: MLXArray
    let tokenCount: Int
    let sampleCount: Int
}

struct Gemma4AudioFeatureExtractor {
    private static let frameLengthMilliseconds: Double = 20
    private static let maxInputSamples = 480_000
    private static let melFloor: Float = 1e-3

    private let config: Gemma4ProcessorConfiguration.AudioFeatureExtractor
    private let frameLength: Int
    private let fftLength: Int
    private let window: MLXArray
    private let melFilters: MLXArray

    init(config: Gemma4ProcessorConfiguration.AudioFeatureExtractor) {
        self.config = config
        let frameLength = Int(
            round(Double(config.samplingRate) * Self.frameLengthMilliseconds / 1000.0)
        )
        self.frameLength = frameLength
        self.fftLength = Self.effectiveFFTLength(
            configuredFFTLength: config.fftLength,
            frameLength: frameLength
        )

        let windowValues: [Float] = (0..<frameLength).map { index in
            let argument = Float.pi * 2.0 / Float(frameLength)
            return 0.5 - (0.5 * Foundation.cos(argument * (Float(index) + 0.5)))
        }
        self.window = MLXArray(windowValues)
        let melFilterBank = Self.makeMelFilterBank(
            fftLength: fftLength,
            samplingRate: config.samplingRate,
            numMelFilters: config.numMelFilters
        )
        self.melFilters = MLXArray(melFilterBank.flatMap { $0 }).reshaped(
            melFilterBank.count,
            melFilterBank.first?.count ?? 0
        )
    }

    func extract(from pcm: UserInput.Audio.PCM) -> Gemma4ExtractedAudioFeatures {
        var waveform = pcm.samples
        if Int(round(pcm.sampleRate)) != config.samplingRate {
            waveform = resampleLinear(
                waveform,
                from: pcm.sampleRate,
                to: Double(config.samplingRate)
            )
        }

        if waveform.count > Self.maxInputSamples {
            waveform = Array(waveform.prefix(Self.maxInputSamples))
        }
        if waveform.count < frameLength {
            waveform.append(contentsOf: repeatElement(0, count: frameLength - waveform.count))
        }

        let frames = buildFrames(from: waveform)
        let frameCount = max(frames.count, 1)

        let flattened = frames.flatMap { $0 }
        var frameArray = MLXArray(flattened).reshaped(frameCount, frameLength)
        frameArray = frameArray * window

        let spectrum = abs(rfft(frameArray, n: fftLength, axis: -1, stream: .cpu)).asType(.float32)
        let melSpec = matmul(spectrum, melFilters, stream: .cpu)
        let floored = MLX.where(
            melSpec .< MLXArray(Self.melFloor),
            MLXArray(Self.melFloor),
            melSpec
        )
        let logMel = log(floored, stream: .cpu).asType(.float32)

        let invalidMask = MLXArray(Array(repeating: false, count: frameCount))
            .expandedDimensions(axis: 0)
        let tokenCount = Self.downsampleLength(Self.downsampleLength(frameCount))

        return Gemma4ExtractedAudioFeatures(
            features: logMel.expandedDimensions(axis: 0),
            invalidMask: invalidMask,
            tokenCount: tokenCount,
            sampleCount: waveform.count
        )
    }

    private func buildFrames(from waveform: [Float]) -> [[Float]] {
        let windowSize = frameLength
        let hop = config.hopLength
        guard waveform.count >= windowSize else {
            return [Array(waveform.prefix(frameLength)) + Array(repeating: 0, count: max(0, frameLength - waveform.count))]
        }

        let frameCount = max(1, ((waveform.count - windowSize) / hop) + 1)
        return (0..<frameCount).map { frameIndex in
            let start = frameIndex * hop
            let end = start + frameLength
            return Array(waveform[start..<end])
        }
    }

    private func resampleLinear(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, abs(sourceRate - targetRate) > 1 else { return samples }
        let newCount = max(1, Int(round(Double(samples.count) * targetRate / sourceRate)))
        if newCount == samples.count { return samples }

        let scale = Double(samples.count - 1) / Double(max(newCount - 1, 1))
        return (0..<newCount).map { outputIndex in
            let position = Double(outputIndex) * scale
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private static func downsampleLength(_ inputLength: Int) -> Int {
        max(1, ((inputLength + 2 - 3) / 2) + 1)
    }

    static func effectiveFFTLength(
        configuredFFTLength: Int,
        frameLength: Int
    ) -> Int {
        let safeFrameLength = max(frameLength, 1)
        let baseFFTLength = 1 << Int(Foundation.ceil(Foundation.log2(Double(safeFrameLength))))

        // Gemma 4's reference extractor defaults fft_overdrive=True.
        // When processor_config only stores the base FFT length (512 for 20 ms @ 16 kHz),
        // we need to double it here to match the reference pipeline.
        if configuredFFTLength > baseFFTLength {
            return configuredFFTLength
        }
        return baseFFTLength * 2
    }

    private static func makeMelFilterBank(
        fftLength: Int,
        samplingRate: Int,
        numMelFilters: Int
    ) -> [[Float]] {
        let numFrequencyBins = (fftLength / 2) + 1
        let melMin = hzToMel(0)
        let melMax = hzToMel(Float(samplingRate) / 2)
        let melPoints: [Float] = (0..<(numMelFilters + 2)).map { index in
            let ratio = Float(index) / Float(numMelFilters + 1)
            return melMin + (melMax - melMin) * ratio
        }
        let freqPoints = melPoints.map(melToHz)
        let allFreqs: [Float] = (0..<numFrequencyBins).map { index in
            Float(index) * (Float(samplingRate) / (2 * Float(max(numFrequencyBins - 1, 1))))
        }

        return (0..<numFrequencyBins).map { bin in
            let frequency = allFreqs[bin]
            return (0..<numMelFilters).map { filterIndex in
                let lower = freqPoints[filterIndex]
                let center = freqPoints[filterIndex + 1]
                let upper = freqPoints[filterIndex + 2]
                let rising = (frequency - lower) / max(center - lower, 1e-10)
                let falling = (upper - frequency) / max(upper - center, 1e-10)
                return max(0, min(rising, falling))
            }
        }
    }

    private static func hzToMel(_ frequency: Float) -> Float {
        2595 * Foundation.log10(1 + frequency / 700)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700 * (pow(10, mel / 2595) - 1)
    }
}
