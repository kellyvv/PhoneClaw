import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM

public struct Gemma4Processor: UserInputProcessor {
    // Gemma 4 E2B has enough headroom on-device to use the processor's
    // native visual length instead of an aggressively compressed budget.
    private static let mobileSoftTokenCap = 280

    private let config: Gemma4ProcessorConfiguration
    private let tokenizer: any Tokenizer

    private let imageToken = "<|image|>"
    private let boiToken = "<|image>"
    private let eoiToken = "<image|>"

    public init(_ config: Gemma4ProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = config
        self.tokenizer = tokenizer
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
        let maxSoftTokens = min(imageProcessor.maxSoftTokens, Self.mobileSoftTokenCap)
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
        let patchSize = config.imageProcessor.patchSize
        let poolingKernel = config.imageProcessor.poolingKernelSize
        let numPatches = (pixelHeight / patchSize) * (pixelWidth / patchSize)
        let numSoftTokens = min(config.imageProcessor.imageSeqLength, Self.mobileSoftTokenCap)

        let processedImage = LMInput.ProcessedImage(
            pixels: pixelValues,
            frames: [THW(1, pixelHeight, pixelWidth)]
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

    public func prepare(input: UserInput) async throws -> LMInput {
        if input.images.count > 1 {
            throw VLMError.singleImageAllowed
        }

        var processedImage: LMInput.ProcessedImage?
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

        let promptTokens: [Int]
        if !input.images.isEmpty, case .chat(let chatMessages) = input.prompt {
            let messages = Qwen2VLMessageGenerator().generate(messages: chatMessages)
            let templatedTokens = try tokenizer.applyChatTemplate(
                messages: messages,
                tools: input.tools,
                additionalContext: input.additionalContext
            )
            promptTokens = expandImageTokens(in: templatedTokens, imageSoftTokenCount: softTokenCount)
        } else {
            var prompt = promptText(from: input)
            if processedImage != nil {
                prompt = expandImageTokens(in: prompt, imageSoftTokenCount: softTokenCount)
            }
            promptTokens = tokenizer.encode(text: prompt, addSpecialTokens: false)
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
            image: processedImage
        )
    }
}
