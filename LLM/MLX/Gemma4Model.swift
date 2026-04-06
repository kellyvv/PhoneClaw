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
    @ModuleInfo(key: "audio_tower") var audioTower: Gemma4AudioEncoder?
    @ModuleInfo(key: "embed_audio") var embedAudio: Gemma4MultimodalProjector?

    public let config: Gemma4ModelConfiguration
    private let supportsAudio: Bool

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

        self.supportsAudio = config.audioConfig != nil
        if let audioConfig = config.audioConfig {
            self._audioTower.wrappedValue = Gemma4AudioEncoder(config: audioConfig)
            self._embedAudio.wrappedValue = Gemma4MultimodalProjector(
                inputDim: audioConfig.outputProjDims ?? audioConfig.hiddenSize,
                outputDim: config.textConfig.hiddenSize,
                eps: audioConfig.rmsNormEps
            )
        } else {
            self._audioTower.wrappedValue = nil
            self._embedAudio.wrappedValue = nil
        }
    }

    private func getInputEmbeddings(
        inputIds: MLXArray,
        pixelValues: MLXArray?,
        imageSoftTokenCount: Int?,
        audioFeatures: MLXArray?,
        audioInvalidMask: MLXArray?
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
            var imageFeatures = visionTower(pixelValues, outputLength: imageSoftTokenCount)
            imageFeatures = embedVision(imageFeatures).asType(inputsEmbeds.dtype)

            let imageMask = batchedIds .== MLXArray(config.imageTokenId ?? 258880)
            let imageTokenPositions = imageMask.asArray(Bool.self).filter { $0 }.count
            if imageTokenPositions == 0 {
                print("[VLM] warning — prompt 中没有图片 soft token，当前图片 embedding 不会被注入。")
            } else if imageTokenPositions != imageFeatures.dim(0) * imageFeatures.dim(1) {
                print(
                    "[VLM] warning — 图片 token 数与编码输出长度不一致。"
                        + " positions=\(imageTokenPositions), "
                        + "encodings=\(imageFeatures.dim(0) * imageFeatures.dim(1))"
                )
            }
            let embedDim = inputsEmbeds.dim(-1)
            var imageMaskExpanded = expandedDimensions(imageMask, axis: -1)
            imageMaskExpanded = repeated(imageMaskExpanded, count: embedDim, axis: -1)

            inputsEmbeds = gemma4MaskedScatter(
                finalEmbedding: inputsEmbeds,
                maskExpanded: imageMaskExpanded,
                source: imageFeatures
            )
        }

        if supportsAudio, let audioFeatures, let audioTower, let embedAudio {
            let invalidMask = audioInvalidMask ?? MLXArray(Array(repeating: false, count: audioFeatures.dim(1)))
                .expandedDimensions(axis: 0)
            var audioEncodings = audioTower(audioFeatures, invalidMask: invalidMask).0
            audioEncodings = embedAudio(audioEncodings).asType(inputsEmbeds.dtype)

            let audioMask = batchedIds .== MLXArray(config.audioTokenId ?? 258881)
            let audioTokenPositions = audioMask.asArray(Bool.self).filter { $0 }.count
            print(
                "[AUDIO] encoder output — "
                    + "features=\(audioFeatures.shape), "
                    + "invalidMask=\(invalidMask.shape), "
                    + "encodings=\(audioEncodings.shape), "
                    + "tokenPositions=\(audioTokenPositions)"
            )
            if audioTokenPositions == 0 {
                print("[AUDIO] warning — prompt 中没有音频 soft token，当前音频 embedding 不会被注入。")
            } else if audioTokenPositions != audioEncodings.dim(0) * audioEncodings.dim(1) {
                print(
                    "[AUDIO] warning — 音频 token 数与编码输出长度不一致。"
                        + " positions=\(audioTokenPositions), "
                        + "encodings=\(audioEncodings.dim(0) * audioEncodings.dim(1))"
                )
            }
            let embedDim = inputsEmbeds.dim(-1)
            var audioMaskExpanded = expandedDimensions(audioMask, axis: -1)
            audioMaskExpanded = repeated(audioMaskExpanded, count: embedDim, axis: -1)

            inputsEmbeds = gemma4MaskedScatter(
                finalEmbedding: inputsEmbeds,
                maskExpanded: audioMaskExpanded,
                source: audioEncodings
            )
        }

        return (inputsEmbeds, perLayerInputs)
    }

    // MARK: - LanguageModel Protocol

    public func prepare(
        _ input: LMInput, cache: [any KVCache], windowSize: Int?
    ) throws -> PrepareResult {
        let convertedCache = cache.compactMap { $0 as KVCache }

        guard input.image?.pixels != nil || input.audio?.features != nil else {
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
            pixelValues: input.image?.pixels,
            imageSoftTokenCount: input.image?.softTokenCount,
            audioFeatures: input.audio?.features,
            audioInvalidMask: input.audio?.invalidMask
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
            if !supportsAudio,
               (key.hasPrefix("audio_tower.") || key.hasPrefix("embed_audio."))
            {
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
