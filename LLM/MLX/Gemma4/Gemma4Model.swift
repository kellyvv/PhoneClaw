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
                PCLog.debug("[VLM] warning — prompt 中没有图片 soft token，当前图片 embedding 不会被注入。")
            } else if imageTokenPositions != imageFeatures.dim(0) * imageFeatures.dim(1) {
                PCLog.debug(
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
            PCLog.debug(
                "[AUDIO] encoder output — "
                    + "features=\(audioFeatures.shape), "
                    + "invalidMask=\(invalidMask.shape), "
                    + "encodings=\(audioEncodings.shape), "
                    + "tokenPositions=\(audioTokenPositions)"
            )
            if audioTokenPositions == 0 {
                PCLog.debug("[AUDIO] warning — prompt 中没有音频 soft token，当前音频 embedding 不会被注入。")
            } else if audioTokenPositions != audioEncodings.dim(0) * audioEncodings.dim(1) {
                PCLog.debug(
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

        // 文本路径: chunked prefill 限制单次 forward 的瞬时激活内存。
        // 详见 prepareTextChunked 注释。
        guard input.image?.pixels != nil || input.audio?.features != nil else {
            return prepareTextChunked(
                tokens: input.text.tokens,
                cache: convertedCache,
                windowSize: windowSize
            )
        }

        // 多模态路径: 图像/音频 embedding 必须整体进入,
        // 它们是固定大小的视觉/音频前缀, 无法天然 chunk。
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

    /// Chunked prefill: 把 prompt 切成 windowSize 大小的 chunk 逐次 forward,
    /// 每个 chunk 之后 eval(cache) 强制 materialize KV 并释放 compute graph。
    ///
    /// **数学等价性**: 因果注意力 + KV cache 下, chunk 处理与单次 full prefill
    /// 在最终 KV cache 状态和最后一个 token 的 logits 上完全一致。每个 chunk
    /// 的 query 通过 cache 看到所有之前 token 的 K/V, 与一次性处理无差别。
    ///
    /// **内存收益**: 单 chunk transient = O(windowSize² × layers × hiddenDim)
    /// 而不是 O(promptLen² × ...)。Gemma 4 E4B (42 层, 8 head, 2560 hidden)
    /// 在 800 token 单 forward 下瞬时 ~1.7 GB, 加 4.6 GB 已驻留 weights+KV
    /// 会撞 iPhone jetsam 6.1 GB 上限。256 chunk 下瞬时 ~400 MB, 安全。
    ///
    /// **框架层修复**: 不感知 prompt 内容、skill 数量、SKILL.md 格式或任何业务,
    /// 只关心张量形状与内存预算。任何 prompt 长度都自动适用。
    private func prepareTextChunked(
        tokens: MLXArray,
        cache: [KVCache],
        windowSize: Int?
    ) -> PrepareResult {
        let prefillStepSize = max(windowSize ?? 512, 1)
        let totalSeqLen = tokens.dim(1)

        // 短 prompt: 单次 forward, 与重构前完全等价。
        if totalSeqLen <= prefillStepSize {
            let result = languageModel(
                tokens,
                cache: cache,
                inputsEmbeds: nil,
                perLayerInputs: nil
            )
            return .logits(result)
        }

        // 长 prompt: 切 chunk 处理。每 chunk 跑 forward → eval(cache) →
        // discard transient compute graph → 下一 chunk。
        var processed = 0
        while processed + prefillStepSize < totalSeqLen {
            let chunk = tokens[0..., processed ..< (processed + prefillStepSize)]
            _ = languageModel(
                chunk,
                cache: cache,
                inputsEmbeds: nil,
                perLayerInputs: nil
            )
            eval(cache)
            processed += prefillStepSize
        }

        // 最后一段 (<= prefillStepSize tokens): forward 并把 logits 返回给
        // TokenIterator, 用于采样首个 generated token。
        let lastChunk = tokens[0..., processed ..< totalSeqLen]
        let result = languageModel(
            lastChunk,
            cache: cache,
            inputsEmbeds: nil,
            perLayerInputs: nil
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
