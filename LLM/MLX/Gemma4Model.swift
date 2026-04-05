import MLX
import MLXFast
import MLXLMCommon
import MLXNN
import MLXVLM

// MARK: - Gemma 4 Top-Level Model

public class Gemma4Model: Module, VLMModel, KVCacheDimensionProvider {

    @ModuleInfo(key: "language_model") var languageModel: Gemma4LanguageModel
    @ModuleInfo(key: "vision_tower") var visionTower: Gemma4VisionModel
    @ModuleInfo(key: "embed_vision") var embedVision: Gemma4MultimodalProjector

    public let config: Gemma4ModelConfiguration

    public var kvHeads: [Int] { languageModel.kvHeads }

    public init(_ config: Gemma4ModelConfiguration) {
        self.config = config
        self._languageModel.wrappedValue = Gemma4LanguageModel(config.textConfig)

        let visionConfig = config.visionConfig ?? Gemma4VisionConfiguration(
            modelType: "gemma4_vision",
            hiddenSize: 768,
            intermediateSize: 3072,
            numHiddenLayers: 16,
            numAttentionHeads: 12,
            numKeyValueHeads: 12,
            headDim: 64,
            patchSize: 16,
            poolingKernelSize: 3,
            defaultOutputLength: 280,
            positionEmbeddingSize: 10240,
            rmsNormEps: 1e-6,
            standardize: false,
            useClippedLinears: true,
            ropeParameters: RoPELayerConfig(
                ropeTheta: 100.0,
                ropeType: "default",
                partialRotaryFactor: nil
            )
        )
        self._visionTower.wrappedValue = Gemma4VisionModel(config: visionConfig)
        self._embedVision.wrappedValue = Gemma4MultimodalProjector(
            inputDim: visionConfig.hiddenSize,
            outputDim: config.textConfig.hiddenSize,
            eps: visionConfig.rmsNormEps
        )
    }

    private func getInputEmbeddings(
        inputIds: MLXArray,
        pixelValues: MLXArray?
    ) -> (inputsEmbeds: MLXArray, perLayerInputs: MLXArray?) {
        let batchedIds = inputIds.ndim == 1 ? inputIds.expandedDimensions(axis: 0) : inputIds
        var inputsEmbeds = languageModel.model.embedTokens(batchedIds)
        inputsEmbeds = inputsEmbeds * MLXArray(languageModel.model.embedScale)

        var perLayerInputs: MLXArray? = nil
        if config.textConfig.hiddenSizePerLayerInput > 0 {
            let imageTokenId = config.imageTokenId ?? 258880
            let audioTokenId = config.audioTokenId ?? 258881
            let imageMask = batchedIds .== MLXArray(imageTokenId)
            let audioMask = batchedIds .== MLXArray(audioTokenId)
            let textMask = imageMask .|| audioMask
            let perLayerTokenIds = MLX.where(textMask, MLXArray.zeros(like: batchedIds), batchedIds)
            perLayerInputs = languageModel.model.getPerLayerInputs(perLayerTokenIds)
        }

        if let pixelValues {
            var imageFeatures = visionTower(pixelValues)
            imageFeatures = embedVision(imageFeatures).asType(inputsEmbeds.dtype)

            let imageMask = batchedIds .== MLXArray(config.imageTokenId ?? 258880)
            let embedDim = inputsEmbeds.dim(-1)
            var imageMaskExpanded = expandedDimensions(imageMask, axis: -1)
            imageMaskExpanded = repeated(imageMaskExpanded, count: embedDim, axis: -1)

            inputsEmbeds = gemma4MaskedScatter(
                finalEmbedding: inputsEmbeds,
                maskExpanded: imageMaskExpanded,
                source: imageFeatures
            )
        }

        return (inputsEmbeds, perLayerInputs)
    }

    // MARK: - LanguageModel Protocol

    public func prepare(
        _ input: LMInput, cache: [any KVCache], windowSize: Int?
    ) throws -> PrepareResult {
        let convertedCache = cache.compactMap { $0 as KVCache }

        guard let imagePixels = input.image?.pixels else {
            let result = languageModel(
                input.text.tokens,
                cache: convertedCache,
                inputsEmbeds: nil,
                perLayerInputs: nil
            )
            return .logits(result)
        }

        let inputEmbeddings = getInputEmbeddings(
            inputIds: input.text.tokens,
            pixelValues: imagePixels
        )

        let result = languageModel(
            nil,
            cache: convertedCache,
            inputsEmbeds: inputEmbeddings.inputsEmbeds,
            perLayerInputs: inputEmbeddings.perLayerInputs
        )
        return .logits(result)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        let cache = cache?.compactMap { $0 as? KVCache }
        let out = languageModel(inputs, cache: cache, inputsEmbeds: nil, perLayerInputs: nil)
        return out.logits
    }

    public func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        languageModel.newCache(parameters: parameters)
    }

    public func sanitize(weights: [String: MLXArray], metadata: [String: String]) -> [String: MLXArray] {
        return sanitize(weights: weights)
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (key, value) in weights {
            if key.hasPrefix("audio_tower.") || key.hasPrefix("embed_audio.") {
                continue
            }
            if key.contains("rotary_emb") {
                continue
            }
            if key.contains("input_max")
                || key.contains("input_min")
                || key.contains("output_max")
                || key.contains("output_min")
            {
                sanitized[key] = value
                continue
            }
            sanitized[key] = value
        }

        return sanitized
    }
}

extension Gemma4Model: LoRAModel {
    public var loraLayers: [Module] {
        languageModel.model.layers
    }
}
