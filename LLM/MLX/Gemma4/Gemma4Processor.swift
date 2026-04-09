import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

private enum Gemma4AudioProcessingError: LocalizedError {
    case urlInputNotSupported(URL)
    case multipleAudioInputs(Int)

    var errorDescription: String? {
        switch self {
        case .urlInputNotSupported(let url):
            return "暂不支持从文件 URL 直接读取音频：\(url.lastPathComponent)"
        case .multipleAudioInputs(let count):
            return "当前版本一次只支持 1 段音频，收到 \(count) 段。"
        }
    }
}

public struct Gemma4Processor: UserInputProcessor {
    // E4B runs close to the jetsam limit on-device; keep the visual token
    // budget conservative so single-image turns stay stable.
    private static let defaultMobileSoftTokenCap = 160
    private static let runtimeBudgetLock = NSLock()
    private static var runtimeImageSoftTokenCapOverride: Int?

    private let config: Gemma4ProcessorConfiguration
    private let tokenizer: any Tokenizer

    private let imageToken = "<|image|>"
    private let boiToken = "<|image>"
    private let eoiToken = "<image|>"
    private let audioToken = "<|audio|>"
    private let boaToken = "<|audio>"
    private let eoaToken = "<audio|>"

    public init(_ config: Gemma4ProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = config
        self.tokenizer = tokenizer
    }

    public static func setRuntimeImageSoftTokenCap(_ cap: Int?) {
        runtimeBudgetLock.lock()
        runtimeImageSoftTokenCapOverride = cap
        runtimeBudgetLock.unlock()
    }

    private static func currentImageSoftTokenCap(
        config: Gemma4ProcessorConfiguration
    ) -> Int {
        runtimeBudgetLock.lock()
        let override = runtimeImageSoftTokenCapOverride
        runtimeBudgetLock.unlock()

        let configuredCap = min(
            config.imageProcessor.maxSoftTokens,
            config.imageSeqLength,
            defaultMobileSoftTokenCap
        )
        guard let override else { return configuredCap }
        return max(32, min(configuredCap, override))
    }

    private func preprocessAudio(_ audio: UserInput.Audio) throws -> LMInput.ProcessedAudio {
        let pcm: UserInput.Audio.PCM
        switch audio {
        case .pcm(let value):
            pcm = value
        case .url(let url):
            throw Gemma4AudioProcessingError.urlInputNotSupported(url)
        }

        guard let featureConfig = config.featureExtractor else {
            let sampleCount = pcm.samples.count
            let tokenCount = min(
                config.audioSeqLength,
                max(
                    1,
                    Int(Foundation.ceil((pcm.duration * 1000.0) / Double(config.audioMsPerToken ?? 40)))
                )
            )
            let features = MLXArray(pcm.samples).expandedDimensions(axis: 0).expandedDimensions(axis: -1)
            let invalidMask = MLXArray(Array(repeating: false, count: sampleCount))
                .expandedDimensions(axis: 0)
            return LMInput.ProcessedAudio(
                features: features,
                invalidMask: invalidMask,
                sampleRate: pcm.sampleRate,
                channelCount: pcm.channelCount,
                duration: pcm.duration,
                sampleCount: sampleCount,
                tokenCount: tokenCount
            )
        }

        let extracted = Gemma4AudioFeatureExtractor(config: featureConfig).extract(from: pcm)
        let tokenCount = computeAudioTokenCount(
            sampleCount: extracted.sampleCount,
            sampleRate: featureConfig.samplingRate
        )
        return LMInput.ProcessedAudio(
            features: extracted.features,
            invalidMask: extracted.invalidMask,
            sampleRate: Double(featureConfig.samplingRate),
            channelCount: pcm.channelCount,
            duration: Double(extracted.sampleCount) / Double(featureConfig.samplingRate),
            sampleCount: extracted.sampleCount,
            tokenCount: tokenCount
        )
    }

    private func computeAudioTokenCount(sampleCount: Int, sampleRate: Int) -> Int {
        let msPerToken = max(config.audioMsPerToken ?? 40, 1)
        let durationMs = (Double(sampleCount) / Double(max(sampleRate, 1))) * 1000.0
        let rawCount = Int(Foundation.ceil(durationMs / Double(msPerToken)))
        return min(config.audioSeqLength, max(1, rawCount))
    }

    private func promptText(from input: UserInput) -> String {
        switch input.prompt {
        case .text(let text):
            return text
        case .messages(let messages):
            return messages.map { "\($0)" }.joined(separator: "\n")
        case .chat(let messages):
            return messages.map(\.content).joined(separator: "\n")
        }
    }

    private func aspectRatioPreservingResize(
        _ image: CIImage
    ) -> CIImage {
        let imageProcessor = config.imageProcessor
        let patchSize = imageProcessor.patchSize
        let maxSoftTokens = Self.currentImageSoftTokenCap(config: config)
        let poolingKernelSize = imageProcessor.poolingKernelSize
        let maxPatches = maxSoftTokens * poolingKernelSize * poolingKernelSize

        let height = image.extent.height
        let width = image.extent.width
        let targetPixelBudget = CGFloat(maxPatches * patchSize * patchSize)
        let factor = sqrt(targetPixelBudget / max(height * width, 1))
        let sideMultiple = CGFloat(poolingKernelSize * patchSize)

        var targetHeight = floor(factor * height / sideMultiple) * sideMultiple
        var targetWidth = floor(factor * width / sideMultiple) * sideMultiple

        let maxSideLength =
            CGFloat(maxPatches / (poolingKernelSize * poolingKernelSize)) * sideMultiple

        if targetHeight == 0 && targetWidth == 0 {
            targetHeight = sideMultiple
            targetWidth = sideMultiple
        } else if targetHeight == 0 {
            targetHeight = sideMultiple
            targetWidth = min(floor(width / height) * sideMultiple, maxSideLength)
        } else if targetWidth == 0 {
            targetWidth = sideMultiple
            targetHeight = min(floor(height / width) * sideMultiple, maxSideLength)
        }

        if Int(targetHeight.rounded()) == Int(height.rounded())
            && Int(targetWidth.rounded()) == Int(width.rounded())
        {
            return image
        }

        return MediaProcessing.resampleBicubic(
            image,
            to: CGSize(width: targetWidth, height: targetHeight)
        )
    }

    private func preprocessImage(
        _ image: CIImage,
        processing: UserInput.Processing?
    ) throws -> (LMInput.ProcessedImage, Int) {
        var processed = MediaProcessing.apply(image, processing: processing)

        if config.imageProcessor.doConvertRgb {
            processed = MediaProcessing.inSRGBToneCurveSpace(processed)
        }
        if config.imageProcessor.doResize {
            processed = aspectRatioPreservingResize(processed)
        }
        if config.imageProcessor.doNormalize {
            processed = MediaProcessing.normalize(
                processed,
                mean: config.imageProcessor.imageMeanTuple,
                std: config.imageProcessor.imageStdTuple
            )
        }

        var pixelValues = MediaProcessing.asMLXArray(processed)
        if config.imageProcessor.doRescale {
            let maxPixel = pixelValues.max().item(Float.self)
            if maxPixel > 1.5 {
                pixelValues = pixelValues * MLXArray(config.imageProcessor.rescaleFactor)
            }
        }
        let pixelHeight = pixelValues.dim(2)
        let pixelWidth = pixelValues.dim(3)
        let numSoftTokens = Self.currentImageSoftTokenCap(config: config)

        let processedImage = LMInput.ProcessedImage(
            pixels: pixelValues,
            frames: [THW(1, pixelHeight, pixelWidth)],
            softTokenCount: numSoftTokens
        )
        return (processedImage, numSoftTokens)
    }

    private func expandImageTokens(in prompt: String, imageSoftTokenCount: Int) -> String {
        let expanded = boiToken + String(repeating: imageToken, count: imageSoftTokenCount) + eoiToken
        if prompt.contains(imageToken) {
            return prompt.replacingOccurrences(of: imageToken, with: expanded)
        }
        return prompt + "\n" + expanded
    }

    private func expandImageTokens(in promptTokens: [Int], imageSoftTokenCount: Int) -> [Int] {
        guard imageSoftTokenCount > 0 else { return promptTokens }

        let imageTokenId = tokenizer.encode(text: imageToken, addSpecialTokens: false).first
        let boiTokenId = tokenizer.encode(text: boiToken, addSpecialTokens: false).first
        let eoiTokenId = tokenizer.encode(text: eoiToken, addSpecialTokens: false).first

        guard let imageTokenId, let boiTokenId, let eoiTokenId else {
            return promptTokens
        }

        var expanded: [Int] = []
        expanded.reserveCapacity(promptTokens.count + imageSoftTokenCount + 2)

        for token in promptTokens {
            if token == imageTokenId {
                expanded.append(boiTokenId)
                expanded.append(contentsOf: repeatElement(imageTokenId, count: imageSoftTokenCount))
                expanded.append(eoiTokenId)
            } else {
                expanded.append(token)
            }
        }

        return expanded
    }

    private func expandAudioTokens(in prompt: String, audioSoftTokenCount: Int) -> String {
        guard audioSoftTokenCount > 0 else { return prompt }
        let expanded = boaToken + String(repeating: audioToken, count: audioSoftTokenCount) + eoaToken
        if prompt.contains(audioToken) {
            return prompt.replacingOccurrences(of: audioToken, with: expanded)
        }
        return prompt + "\n" + expanded
    }

    private func expandAudioTokens(in promptTokens: [Int], audioSoftTokenCount: Int) -> [Int] {
        guard audioSoftTokenCount > 0 else { return promptTokens }

        let audioTokenId = tokenizer.encode(text: audioToken, addSpecialTokens: false).first
        let boaTokenId = tokenizer.encode(text: boaToken, addSpecialTokens: false).first
        let eoaTokenId = tokenizer.encode(text: eoaToken, addSpecialTokens: false).first

        guard let audioTokenId, let boaTokenId, let eoaTokenId else {
            return promptTokens + [boaTokenId, eoaTokenId].compactMap { $0 }
        }

        let expandedSequence =
            [boaTokenId]
            + Array(repeating: audioTokenId, count: audioSoftTokenCount)
            + [eoaTokenId]

        var expanded: [Int] = []
        expanded.reserveCapacity(promptTokens.count + audioSoftTokenCount + 2)
        var replacedExistingPlaceholder = false

        for token in promptTokens {
            if token == audioTokenId {
                expanded.append(contentsOf: expandedSequence)
                replacedExistingPlaceholder = true
            } else {
                expanded.append(token)
            }
        }

        if !replacedExistingPlaceholder {
            expanded.append(contentsOf: expandedSequence)
        }
        return expanded
    }

    public func prepare(input: UserInput) async throws -> LMInput {
        if input.images.count > 1 {
            throw VLMError.singleImageAllowed
        }
        if input.audios.count > 1 {
            throw Gemma4AudioProcessingError.multipleAudioInputs(input.audios.count)
        }

        var processedImage: LMInput.ProcessedImage?
        var processedAudio: LMInput.ProcessedAudio?
        var softTokenCount = 0

        if let image = input.images.first {
            let ciImage = try image.asCIImage()
            let (imageData, derivedSoftTokenCount) = try preprocessImage(
                ciImage,
                processing: input.processing
            )
            processedImage = imageData
            softTokenCount = derivedSoftTokenCount
        }

        if let audio = input.audios.first {
            processedAudio = try preprocessAudio(audio)
            if let featureExtractor = config.featureExtractor {
                let frameLength = Int(
                    round(Double(featureExtractor.samplingRate) * 20 / 1000.0)
                )
                print(
                    "[AUDIO] prompt prepared — samples=\(processedAudio!.sampleCount), "
                        + "sampleRate=\(featureExtractor.samplingRate), "
                        + "mel=\(featureExtractor.numMelFilters), "
                        + "fft=\(Gemma4AudioFeatureExtractor.effectiveFFTLength(configuredFFTLength: featureExtractor.fftLength, frameLength: frameLength)), "
                        + "hop=\(featureExtractor.hopLength), "
                        + "chunk=\(featureExtractor.chunkDuration)s"
                )
            } else {
                print(
                    "[AUDIO] prompt prepared — samples=\(processedAudio!.sampleCount), "
                        + "sampleRate=\(Int(processedAudio!.sampleRate))"
                )
            }
        }

        let promptTokens: [Int]
        if case .chat(let chatMessages) = input.prompt {
            let messages = Gemma3StructuredMessageGenerator().generate(messages: chatMessages)
            let templatedTokens = try tokenizer.applyChatTemplate(
                messages: messages,
                tools: input.tools,
                additionalContext: input.additionalContext
            )
            var expandedTokens = templatedTokens
            if softTokenCount > 0 {
                expandedTokens = expandImageTokens(in: expandedTokens, imageSoftTokenCount: softTokenCount)
            }
            if let processedAudio {
                expandedTokens = expandAudioTokens(in: expandedTokens, audioSoftTokenCount: processedAudio.tokenCount)
            }
            promptTokens = expandedTokens
        } else {
            var prompt = promptText(from: input)
            if processedImage != nil {
                prompt = expandImageTokens(in: prompt, imageSoftTokenCount: softTokenCount)
            }
            if let processedAudio {
                prompt = expandAudioTokens(in: prompt, audioSoftTokenCount: processedAudio.tokenCount)
            }
            promptTokens = tokenizer.encode(text: prompt, addSpecialTokens: false)
        }

        if let processedAudio {
            let audioTokenId = tokenizer.encode(text: audioToken, addSpecialTokens: false).first
            let boaTokenId = tokenizer.encode(text: boaToken, addSpecialTokens: false).first
            let eoaTokenId = tokenizer.encode(text: eoaToken, addSpecialTokens: false).first
            let actualAudioTokenCount = audioTokenId.map { id in
                promptTokens.reduce(into: 0) { count, token in
                    if token == id { count += 1 }
                }
            } ?? 0
            print(
                "[AUDIO] token expansion — "
                    + "boa=\(boaTokenId.map(String.init) ?? "nil"), "
                    + "audio=\(audioTokenId.map(String.init) ?? "nil"), "
                    + "eoa=\(eoaTokenId.map(String.init) ?? "nil"), "
                    + "planned=\(processedAudio.tokenCount), "
                    + "actual=\(actualAudioTokenCount)"
            )
        }

        if processedImage != nil {
            let imageTokenId = tokenizer.encode(text: imageToken, addSpecialTokens: false).first
            let boiTokenId = tokenizer.encode(text: boiToken, addSpecialTokens: false).first
            let eoiTokenId = tokenizer.encode(text: eoiToken, addSpecialTokens: false).first
            let imageTokenCount = imageTokenId.map { id in
                promptTokens.reduce(into: 0) { count, token in
                    if token == id { count += 1 }
                }
            } ?? 0
            print(
                "[VLM] image prompt prepared — "
                    + "boi=\(boiTokenId.map(String.init) ?? "nil"), "
                    + "image=\(imageTokenId.map(String.init) ?? "nil"), "
                    + "eoi=\(eoiTokenId.map(String.init) ?? "nil"), "
                    + "softTokens=\(imageTokenCount), "
                    + "pixels=\(processedImage!.pixels.shape)"
            )
        }
        let promptArray = MLXArray(promptTokens).expandedDimensions(axis: 0)
        let mask = ones(like: promptArray).asType(.int8)

        return LMInput(
            text: .init(tokens: promptArray, mask: mask),
            image: processedImage,
            audio: processedAudio
        )
    }
}
