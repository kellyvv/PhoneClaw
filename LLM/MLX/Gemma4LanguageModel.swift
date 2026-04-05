import Foundation
import MLX
import MLXFast
import MLXNN
import MLXLMCommon

// MARK: - DecoderLayer

class Gemma4DecoderLayer: Module {
    let config: Gemma4TextConfiguration
    let layerIdx: Int
    let layerType: String

    @ModuleInfo(key: "self_attn") var selfAttn: Gemma4Attention
    @ModuleInfo var mlp: Gemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayerNorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayerNorm: RMSNorm

    // PLE (Per-Layer Embeddings) — only for 2B/4B models
    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: RMSNorm

    // Layer scalar
    @ParameterInfo(key: "layer_scalar") var layerScalar: MLXArray

    init(config: Gemma4TextConfiguration, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx
        self.layerType = config.layerTypes[layerIdx]

        self._selfAttn.wrappedValue = Gemma4Attention(config: config, layerIdx: layerIdx)
        self._mlp.wrappedValue = Gemma4MLP(config: config, layerIdx: layerIdx)

        let eps = config.rmsNormEps
        let dim = config.hiddenSize
        self._inputLayerNorm.wrappedValue = RMSNorm(dimensions: dim, eps: eps)
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: dim, eps: eps)
        self._preFeedforwardLayerNorm.wrappedValue = RMSNorm(dimensions: dim, eps: eps)
        self._postFeedforwardLayerNorm.wrappedValue = RMSNorm(dimensions: dim, eps: eps)

        // PLE gating
        let pleDim = config.hiddenSizePerLayerInput
        precondition(pleDim > 0, "Gemma 4 text path currently expects a PLE-enabled config.")
        self._perLayerInputGate.wrappedValue = Linear(dim, pleDim, bias: false)
        self._perLayerProjection.wrappedValue = Linear(pleDim, dim, bias: false)
        self._postPerLayerInputNorm.wrappedValue = RMSNorm(dimensions: dim, eps: eps)

        self._layerScalar.wrappedValue = MLXArray.ones([1])
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil
    ) -> MLXArray {
        var residual = x

        // Self-attention block
        var h = inputLayerNorm(x)
        h = selfAttn(h, mask: mask, cache: cache)
        h = postAttentionLayerNorm(h)
        h = residual + h

        // MLP block
        residual = h
        h = preFeedforwardLayerNorm(h)
        h = mlp(h)
        h = postFeedforwardLayerNorm(h)
        h = residual + h

        // PLE gating
        if let pli = perLayerInput {
            residual = h
            var g = perLayerInputGate(h)
            g = geluApproximate(g)
            g = g * pli
            g = perLayerProjection(g)
            g = postPerLayerInputNorm(g)
            h = residual + g
        }

        // Layer scalar
        h = h * layerScalar

        return h
    }
}

// MARK: - Gemma4TextModel

class Gemma4TextModel: Module {
    let config: Gemma4TextConfiguration

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [Gemma4DecoderLayer]
    @ModuleInfo var norm: RMSNorm

    let embedScale: Float
    let firstKvSharedLayerIdx: Int
    let layerIdxToCacheIdx: [Int]

    // PLE embeddings
    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding
    @ModuleInfo(key: "per_layer_model_projection") var perLayerModelProjection: ScaledLinear
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: RMSNormZeroShift
    let embedTokensPerLayerScale: Float
    let perLayerInputScale: Float

    init(_ config: Gemma4TextConfiguration) {
        self.config = config
        self.embedScale = pow(Float(config.hiddenSize), 0.5)
        self.firstKvSharedLayerIdx = config.firstKvSharedLayerIdx

        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map {
            Gemma4DecoderLayer(config: config, layerIdx: $0)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        // Build KV cache index mapping for KV sharing
        var mapping = Array(0..<firstKvSharedLayerIdx)
        if firstKvSharedLayerIdx < config.numHiddenLayers {
            let concreteLayers = Array(config.layerTypes[..<firstKvSharedLayerIdx])
            let sharedFullIdx = concreteLayers.lastIndex(of: "full_attention") ?? 0
            let sharedSlidingIdx = concreteLayers.lastIndex(of: "sliding_attention") ?? 0
            for i in firstKvSharedLayerIdx..<config.numHiddenLayers {
                if config.layerTypes[i] == "full_attention" {
                    mapping.append(sharedFullIdx)
                } else {
                    mapping.append(sharedSlidingIdx)
                }
            }
        }
        self.layerIdxToCacheIdx = mapping

        // PLE
        let pleDim = config.hiddenSizePerLayerInput
        precondition(pleDim > 0, "Gemma 4 text path currently expects a PLE-enabled config.")
        self._embedTokensPerLayer.wrappedValue = Embedding(
            embeddingCount: config.vocabSizePerLayerInput,
            dimensions: config.numHiddenLayers * pleDim
        )
        self.embedTokensPerLayerScale = pow(Float(pleDim), 0.5)
        self.perLayerInputScale = pow(Float(2.0), -0.5)
        self._perLayerModelProjection.wrappedValue = ScaledLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.numHiddenLayers * pleDim,
            scalar: pow(Float(config.hiddenSize), -0.5)
        )
        self._perLayerProjectionNorm.wrappedValue = RMSNormZeroShift(
            dimensions: pleDim, eps: config.rmsNormEps)
    }

    private func batchedTokenIds(_ inputIds: MLXArray) -> MLXArray {
        if inputIds.ndim == 1 {
            return inputIds.expandedDimensions(axis: 0)
        }
        return inputIds
    }

    private func batchedEmbeddings(_ embeddings: MLXArray) -> MLXArray {
        if embeddings.ndim == 2 {
            return embeddings.expandedDimensions(axis: 0)
        }
        return embeddings
    }

    func getPerLayerInputs(_ inputIds: MLXArray) -> MLXArray {
        let batchedIds = batchedTokenIds(inputIds)
        var result = embedTokensPerLayer(batchedIds)
        result = result * embedTokensPerLayerScale
        let shape = batchedIds.shape
        return result.reshaped(shape[0], shape[1], config.numHiddenLayers, config.hiddenSizePerLayerInput)
    }

    func projectPerLayerInputs(
        _ inputsEmbeds: MLXArray, perLayerInputs: MLXArray?
    ) -> MLXArray {
        let batchedEmbeds = batchedEmbeddings(inputsEmbeds)
        var projection = perLayerModelProjection(batchedEmbeds)
        let shape = batchedEmbeds.shape
        projection = projection.reshaped(
            shape[0], shape[1], config.numHiddenLayers, config.hiddenSizePerLayerInput)
        projection = perLayerProjectionNorm(projection)

        if let pli = perLayerInputs {
            return (projection + pli) * perLayerInputScale
        }
        return projection
    }

    func callAsFunction(
        _ inputs: MLXArray? = nil,
        inputsEmbeds: MLXArray? = nil,
        perLayerInputs externalPerLayerInputs: MLXArray? = nil,
        cache: [KVCache?]? = nil
    ) -> MLXArray {
        var h: MLXArray
        if let embed = inputsEmbeds {
            h = batchedEmbeddings(embed)
        } else if let ids = inputs {
            let batchedIds = batchedTokenIds(ids)
            h = embedTokens(batchedIds) * embedScale
        } else {
            fatalError("Either inputs or inputsEmbeds must be provided")
        }

        // PLE computation
        var perLayerInputs = externalPerLayerInputs
        if perLayerInputs == nil, let ids = inputs {
            perLayerInputs = getPerLayerInputs(ids)
        }
        perLayerInputs = projectPerLayerInputs(h, perLayerInputs: perLayerInputs)

        // Create attention masks
        let firstFullIdx = config.layerTypes.firstIndex(of: "full_attention") ?? 0
        let firstSlidingIdx = config.layerTypes.firstIndex(of: "sliding_attention") ?? 0

        let fullCache = (firstFullIdx < (cache?.count ?? 0)) ? cache?[firstFullIdx] : nil
        let slidingCache = (firstSlidingIdx < (cache?.count ?? 0)) ? cache?[firstSlidingIdx] : nil

        let globalMask = createAttentionMask(h: h, cache: fullCache)
        let slidingMask = createAttentionMask(
            h: h, cache: slidingCache, windowSize: config.slidingWindow)

        // Run through decoder layers
        for (i, layer) in layers.enumerated() {
            let cacheIdx = layerIdxToCacheIdx[i]
            let c = (cacheIdx < (cache?.count ?? 0)) ? cache?[cacheIdx] : nil
            let isGlobal = layer.layerType == "full_attention"
            let mask = isGlobal ? globalMask : slidingMask

            var pli: MLXArray? = nil
            if let p = perLayerInputs {
                pli = p[0..., 0..., i, 0...]
            }

            h = layer(h, mask: mask, cache: c, perLayerInput: pli)
        }

        return norm(h)
    }
}

// MARK: - LanguageModel

public class Gemma4LanguageModel: Module, KVCacheDimensionProvider {
    @ModuleInfo var model: Gemma4TextModel
    let config: Gemma4TextConfiguration
    let finalLogitSoftcapping: Float?

    public var kvHeads: [Int]

    public init(_ config: Gemma4TextConfiguration) {
        self.config = config
        self.model = Gemma4TextModel(config)
        self.finalLogitSoftcapping = config.finalLogitSoftcapping
        self.kvHeads = Array(repeating: config.numKeyValueHeads, count: config.numHiddenLayers)
    }

    public func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        var caches: [any KVCache] = []
        let concreteLayers = Array(config.layerTypes[..<model.firstKvSharedLayerIdx])
        for layerType in concreteLayers {
            if layerType == "full_attention" {
                caches.append(StandardKVCache())
            } else {
                caches.append(RotatingKVCache(maxSize: config.slidingWindow, keep: 0))
            }
        }
        return caches
    }

    public func callAsFunction(
        _ inputs: MLXArray? = nil,
        cache: [KVCache]? = nil,
        inputsEmbeds: MLXArray? = nil,
        perLayerInputs: MLXArray? = nil
    ) -> LMOutput {
        let optionalCache = cache?.map { $0 as KVCache? }
        let out = model(
            inputs,
            inputsEmbeds: inputsEmbeds,
            perLayerInputs: perLayerInputs,
            cache: optionalCache
        )

        // Tied weights: use embedding as output projection
        var logits = model.embedTokens.asLinear(out)

        // Final logit softcapping
        if let softcap = finalLogitSoftcapping, softcap > 0 {
            let s = MLXArray(softcap)
            logits = tanh(logits / s) * s
        }

        return LMOutput(logits: logits)
    }

    public func sanitize(
        weights: [String: MLXArray],
        quantizationConfig: BaseConfiguration.Quantization? = nil
    ) -> [String: MLXArray] {
        var processed = [String: MLXArray]()

        for (key, value) in weights {
            guard key.hasPrefix("language_model.") else { continue }
            if key.contains("rotary_emb") { continue }
            if key.contains("input_max") || key.contains("input_min")
                || key.contains("output_max") || key.contains("output_min")
            {
                continue
            }
            processed[key] = value
        }

        return processed
    }
}
