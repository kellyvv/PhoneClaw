import MLX
import MLXFast
import MLXNN
import MLXLMCommon

// MARK: - Custom RMSNorm Variants

/// RMSNorm without learnable scale (with_scale=False)
class RMSNormNoScale: Module {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

/// RMSNorm with scale_shift=0 (weight used directly, no +1 offset)
class RMSNormZeroShift: Module {
    let eps: Float
    var weight: MLXArray

    init(dimensions: Int, eps: Float = 1e-6) {
        self.eps = eps
        self.weight = MLXArray.ones([dimensions])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

/// ScaledLinear: linear layer with output scaling (for PLE)
class ScaledLinear: Module {
    var weight: MLXArray
    let scalar: Float

    init(inFeatures: Int, outFeatures: Int, scalar: Float) {
        self.weight = MLXArray.zeros([outFeatures, inFeatures])
        self.scalar = scalar
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x, weight.transposed()) * scalar
    }
}

// MARK: - MLP

class Gemma4MLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear

    init(config: Gemma4TextConfiguration, layerIdx: Int) {
        let firstKvShared = config.firstKvSharedLayerIdx
        let isKvShared = layerIdx >= firstKvShared && firstKvShared > 0
        let useDoubleWide = config.useDoubleWideMlp && isKvShared
        let intermediateSize = config.intermediateSize * (useDoubleWide ? 2 : 1)

        self._gateProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(intermediateSize, config.hiddenSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

// MARK: - Attention

class Gemma4Attention: Module {
    let config: Gemma4TextConfiguration
    let layerIdx: Int
    let layerType: String
    let isSliding: Bool
    let headDim: Int
    let nHeads: Int
    let nKvHeads: Int
    let scale: Float
    let isKvSharedLayer: Bool

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let vNorm: RMSNormNoScale
    let rope: Module

    init(config: Gemma4TextConfiguration, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx
        self.layerType = config.layerTypes[layerIdx]
        self.isSliding = layerType == "sliding_attention"

        // Full attention uses global_head_dim, sliding uses head_dim
        self.headDim = (layerType == "full_attention" && config.globalHeadDim > 0)
            ? config.globalHeadDim : config.headDim

        self.nHeads = config.numAttentionHeads
        self.nKvHeads = config.numKeyValueHeads
        self.scale = 1.0  // Gemma 4 uses scale=1.0

        let dim = config.hiddenSize
        self._qProj.wrappedValue = Linear(dim, nHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(dim, nKvHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(dim, nKvHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(nHeads * headDim, dim, bias: false)

        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self.vNorm = RMSNormNoScale(eps: config.rmsNormEps)

        // RoPE: different config per attention type
        let ropeKey = isSliding ? "sliding_attention" : "full_attention"
        let ropeConfig = config.ropeParameters?[ropeKey]
        self.rope = initializeGemma4Rope(
            dims: headDim,
            traditional: false,
            base: ropeConfig?.ropeTheta ?? 10000.0,
            ropeConfig: ropeConfig
        )

        // KV sharing
        let firstKvShared = config.firstKvSharedLayerIdx
        self.isKvSharedLayer = layerIdx >= firstKvShared && firstKvShared > 0
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil
    ) -> MLXArray {
        let (B, L, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(B, L, nHeads, headDim)
        queries = qNorm(queries)

        var offset = 0
        var keys: MLXArray
        var values: MLXArray

        if isKvSharedLayer, let cache = cache {
            // KV-shared layers reuse cached keys/values
            let state = cache.state
            if state.count >= 2 {
                keys = state[0]
                values = state[1]
                offset = cache.offset
            } else {
                offset = cache.offset

                keys = kProj(x).reshaped(B, L, nKvHeads, headDim)
                values = vProj(x).reshaped(B, L, nKvHeads, headDim)

                keys = kNorm(keys)
                values = vNorm(values)
                values = values.transposed(0, 2, 1, 3)

                keys = keys.transposed(0, 2, 1, 3)
                keys = applyRope(keys, offset: offset)

                (keys, values) = cache.update(keys: keys, values: values)
            }
        } else {
            if let cache = cache {
                offset = cache.offset
            }

            keys = kProj(x).reshaped(B, L, nKvHeads, headDim)
            values = vProj(x).reshaped(B, L, nKvHeads, headDim)

            keys = kNorm(keys)
            values = vNorm(values)
            values = values.transposed(0, 2, 1, 3)

            keys = keys.transposed(0, 2, 1, 3)
            keys = applyRope(keys, offset: offset)

            if let cache = cache {
                (keys, values) = cache.update(keys: keys, values: values)
            }
        }

        queries = queries.transposed(0, 2, 1, 3)
        queries = applyRope(queries, offset: offset)

        // Handle mask dimension mismatch
        var effectiveMask = mask ?? .none
        if case .array(let maskArray) = effectiveMask {
            if maskArray.dim(-1) != keys.dim(-2) {
                let slicedMask = maskArray[.ellipsis, (maskArray.dim(-1) - keys.dim(-2))...]
                effectiveMask = .array(slicedMask.asType(queries.dtype))
            } else {
                effectiveMask = .array(maskArray.asType(queries.dtype))
            }
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: effectiveMask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return oProj(output)
    }

    private func applyRope(_ x: MLXArray, offset: Int) -> MLXArray {
        if let proportionalRope = rope as? ProportionalRoPE {
            return proportionalRope(x, offset: offset)
        } else if let standardRope = rope as? RoPE {
            return standardRope(x, offset: offset)
        }
        return x
    }
}
