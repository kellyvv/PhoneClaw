import Foundation
import MLX
import MLXFast
import MLXNN
import MLXLMCommon

// MARK: - Multimodal Helpers

func gemma4MaskedScatter(
    finalEmbedding: MLXArray,
    maskExpanded: MLXArray,
    source: MLXArray
) -> MLXArray {
    let finalShape = finalEmbedding.shape
    let sourceFlattened = source.flattened()
    let finalFlattened = finalEmbedding.flattened()
    let maskFlattened = maskExpanded.flattened()

    let maskValues = maskFlattened.asArray(Bool.self)
    let indices = maskValues.enumerated().compactMap { idx, value in
        value ? Int32(idx) : nil
    }

    guard !indices.isEmpty else {
        return finalEmbedding
    }

    let scatterIndices = MLXArray(indices)
    let sourceSize = Int(sourceFlattened.shape[0])
    guard sourceSize > 0 else {
        return finalEmbedding
    }

    if sourceSize != scatterIndices.shape[0] {
        print(
            "[Gemma4] maskedScatter 自动对齐：source=\(sourceSize), positions=\(scatterIndices.shape[0])"
        )
    }

    let wrappedSourceIndices = MLXArray(
        (0..<Int(scatterIndices.shape[0])).map { Int32($0 % sourceSize) }
    )
    let alignedSource = sourceFlattened[wrappedSourceIndices]
    finalFlattened[scatterIndices] = alignedSource
    return finalFlattened.reshaped(finalShape)
}

private func gemma4RotateHalf(_ x: MLXArray) -> MLXArray {
    let half = x.dim(-1) / 2
    let x1 = x[0..., 0..., 0..., ..<half]
    let x2 = x[0..., 0..., 0..., half...]
    return concatenated([-x2, x1], axis: -1)
}

private func gemma4ApplyMultidimensionalRoPE(
    _ inputs: MLXArray,
    positions: MLXArray,
    baseFrequency: Float
) -> MLXArray {
    let headDim = inputs.dim(-1)
    let ndim = positions.dim(-1)
    let channelsPerDim = 2 * (headDim / (2 * ndim))
    let halfPerDim = channelsPerDim / 2

    var parts: [MLXArray] = []
    parts.reserveCapacity(ndim)

    for d in 0..<ndim {
        let start = d * channelsPerDim
        let end = start + channelsPerDim
        let xPart = inputs[0..., 0..., 0..., start..<end]

        let freqExponents =
            (MLXArray(0 ..< halfPerDim).asType(.float32) * MLXArray(2.0 / Float(channelsPerDim)))
        let timescale = pow(MLXArray(baseFrequency), freqExponents)
        let posSlice = positions[0..., 0..., d ..< (d + 1)].asType(.float32)
        let sinusoid = posSlice / timescale

        var cosPart = cos(sinusoid)
        var sinPart = sin(sinusoid)
        cosPart = concatenated([cosPart, cosPart], axis: -1).asType(inputs.dtype)
        sinPart = concatenated([sinPart, sinPart], axis: -1).asType(inputs.dtype)
        cosPart = expandedDimensions(cosPart, axis: 2)
        sinPart = expandedDimensions(sinPart, axis: 2)

        let rotated = xPart * cosPart + gemma4RotateHalf(xPart) * sinPart
        parts.append(rotated)
    }

    return concatenated(parts, axis: -1)
}

// MARK: - Vision Modules

final class Gemma4ClippableLinear: Module {
    @ModuleInfo(key: "linear") var linear: Linear
    @ParameterInfo(key: "input_min") var inputMin: MLXArray
    @ParameterInfo(key: "input_max") var inputMax: MLXArray
    @ParameterInfo(key: "output_min") var outputMin: MLXArray
    @ParameterInfo(key: "output_max") var outputMax: MLXArray

    let useClipping: Bool

    init(
        inFeatures: Int,
        outFeatures: Int,
        bias: Bool = false,
        useClipping: Bool = true
    ) {
        self.useClipping = useClipping
        self._linear.wrappedValue = Linear(inFeatures, outFeatures, bias: bias)
        self._inputMin.wrappedValue = MLXArray(-Float.infinity)
        self._inputMax.wrappedValue = MLXArray(Float.infinity)
        self._outputMin.wrappedValue = MLXArray(-Float.infinity)
        self._outputMax.wrappedValue = MLXArray(Float.infinity)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var result = x
        if useClipping {
            result = clip(result, min: inputMin, max: inputMax)
        }
        result = linear(result)
        if useClipping {
            result = clip(result, min: outputMin, max: outputMax)
        }
        return result
    }
}

final class Gemma4VisionRMSNorm: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dim: Int, eps: Float = 1e-6) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dim])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xFloat = x.asType(.float32)
        let variance = mean(xFloat * xFloat, axis: -1, keepDims: true)
        let normed = xFloat * rsqrt(variance + MLXArray(eps))
        return (normed * weight.asType(.float32)).asType(x.dtype)
    }
}

final class Gemma4VisionRMSNormNoScale: Module {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xFloat = x.asType(.float32)
        let variance = mean(xFloat * xFloat, axis: -1, keepDims: true)
        return (xFloat * rsqrt(variance + MLXArray(eps))).asType(x.dtype)
    }
}

final class Gemma4VisionPatchEmbedder: Module {
    let config: Gemma4VisionConfiguration

    @ModuleInfo(key: "input_proj") var inputProj: Linear
    @ParameterInfo(key: "position_embedding_table") var positionEmbeddingTable: MLXArray

    init(config: Gemma4VisionConfiguration) {
        self.config = config
        let patchVectorSize = 3 * config.patchSize * config.patchSize
        self._inputProj.wrappedValue = Linear(patchVectorSize, config.hiddenSize, bias: false)
        self._positionEmbeddingTable.wrappedValue = MLXArray.ones([
            2, config.positionEmbeddingSize, config.hiddenSize
        ])
    }

    private func patchify(_ pixelValues: MLXArray) -> MLXArray {
        let b = pixelValues.dim(0)
        let c = pixelValues.dim(1)
        let h = pixelValues.dim(2)
        let w = pixelValues.dim(3)
        let p = config.patchSize
        let patchH = h / p
        let patchW = w / p

        var patches = pixelValues.reshaped(b, c, patchH, p, patchW, p)
        patches = patches.transposed(0, 2, 4, 3, 5, 1)
        patches = patches.reshaped(b, patchH * patchW, c * p * p)
        patches = MLXArray(2.0) * (patches - MLXArray(0.5))
        return inputProj(patches.asType(inputProj.weight.dtype))
    }

    private func positionEmbeddings(
        xIndices: MLXArray,
        yIndices: MLXArray
    ) -> MLXArray {
        let xTable = positionEmbeddingTable[0, 0...]
        let yTable = positionEmbeddingTable[1, 0...]
        let xEmb = take(xTable, xIndices.asType(.int32), axis: 0)
        let yEmb = take(yTable, yIndices.asType(.int32), axis: 0)
        return xEmb + yEmb
    }

    func callAsFunction(
        _ pixelValues: MLXArray,
        xIndices: MLXArray,
        yIndices: MLXArray
    ) -> MLXArray {
        let hiddenStates = patchify(pixelValues)
        let positionEmbeds = positionEmbeddings(xIndices: xIndices, yIndices: yIndices)
        return hiddenStates + expandedDimensions(positionEmbeds, axis: 0)
    }
}

final class Gemma4VisionAttention: Module {
    let config: Gemma4VisionConfiguration
    let ropeBaseFrequency: Float

    @ModuleInfo(key: "q_proj") var qProj: Gemma4ClippableLinear
    @ModuleInfo(key: "k_proj") var kProj: Gemma4ClippableLinear
    @ModuleInfo(key: "v_proj") var vProj: Gemma4ClippableLinear
    @ModuleInfo(key: "o_proj") var oProj: Gemma4ClippableLinear
    @ModuleInfo(key: "q_norm") var qNorm: Gemma4VisionRMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: Gemma4VisionRMSNorm

    let vNorm: Gemma4VisionRMSNormNoScale

    init(config: Gemma4VisionConfiguration) {
        self.config = config
        self.ropeBaseFrequency = config.ropeParameters?.ropeTheta ?? 100.0

        let hiddenSize = config.hiddenSize
        let headDim = config.headDim
        let useClipping = config.useClippedLinears

        self._qProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: hiddenSize,
            outFeatures: config.numAttentionHeads * headDim,
            useClipping: useClipping
        )
        self._kProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: hiddenSize,
            outFeatures: config.numKeyValueHeads * headDim,
            useClipping: useClipping
        )
        self._vProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: hiddenSize,
            outFeatures: config.numKeyValueHeads * headDim,
            useClipping: useClipping
        )
        self._oProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.numAttentionHeads * headDim,
            outFeatures: hiddenSize,
            useClipping: useClipping
        )
        self._qNorm.wrappedValue = Gemma4VisionRMSNorm(dim: headDim)
        self._kNorm.wrappedValue = Gemma4VisionRMSNorm(dim: headDim)
        self.vNorm = Gemma4VisionRMSNormNoScale(eps: config.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray,
        positions: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none
    ) -> MLXArray {
        let b = x.dim(0)
        let l = x.dim(1)
        let numHeads = config.numAttentionHeads
        let numKvHeads = config.numKeyValueHeads
        let headDim = config.headDim

        var q = qProj(x).reshaped(b, l, numHeads, headDim)
        var k = kProj(x).reshaped(b, l, numKvHeads, headDim)
        var v = vProj(x).reshaped(b, l, numKvHeads, headDim)

        q = qNorm(q)
        k = kNorm(k)
        v = vNorm(v)

        q = gemma4ApplyMultidimensionalRoPE(q, positions: positions, baseFrequency: ropeBaseFrequency)
        k = gemma4ApplyMultidimensionalRoPE(k, positions: positions, baseFrequency: ropeBaseFrequency)

        q = q.transposed(0, 2, 1, 3)
        k = k.transposed(0, 2, 1, 3)
        v = v.transposed(0, 2, 1, 3)

        let attended = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: k,
            values: v,
            scale: 1.0,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(b, l, numHeads * headDim)

        return oProj(attended)
    }
}

final class Gemma4VisionMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Gemma4ClippableLinear
    @ModuleInfo(key: "up_proj") var upProj: Gemma4ClippableLinear
    @ModuleInfo(key: "down_proj") var downProj: Gemma4ClippableLinear

    init(config: Gemma4VisionConfiguration) {
        let useClipping = config.useClippedLinears
        self._gateProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.intermediateSize,
            useClipping: useClipping
        )
        self._upProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.intermediateSize,
            useClipping: useClipping
        )
        self._downProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.intermediateSize,
            outFeatures: config.hiddenSize,
            useClipping: useClipping
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

final class Gemma4VisionTransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Gemma4VisionAttention
    @ModuleInfo var mlp: Gemma4VisionMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNormZeroShift
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNormZeroShift
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: RMSNormZeroShift
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: RMSNormZeroShift

    init(config: Gemma4VisionConfiguration) {
        self._selfAttn.wrappedValue = Gemma4VisionAttention(config: config)
        self._mlp.wrappedValue = Gemma4VisionMLP(config: config)
        self._inputLayernorm.wrappedValue = RMSNormZeroShift(
            dimensions: config.hiddenSize,
            eps: config.rmsNormEps
        )
        self._postAttentionLayernorm.wrappedValue = RMSNormZeroShift(
            dimensions: config.hiddenSize,
            eps: config.rmsNormEps
        )
        self._preFeedforwardLayernorm.wrappedValue = RMSNormZeroShift(
            dimensions: config.hiddenSize,
            eps: config.rmsNormEps
        )
        self._postFeedforwardLayernorm.wrappedValue = RMSNormZeroShift(
            dimensions: config.hiddenSize,
            eps: config.rmsNormEps
        )
    }

    func callAsFunction(
        _ x: MLXArray,
        positions: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none
    ) -> MLXArray {
        let normed = inputLayernorm(x)
        let attnOut = postAttentionLayernorm(selfAttn(normed, positions: positions, mask: mask))
        let h = x + attnOut
        let ffwOut = postFeedforwardLayernorm(mlp(preFeedforwardLayernorm(h)))
        return h + ffwOut
    }
}

final class Gemma4VisionTransformerModel: Module {
    @ModuleInfo var layers: [Gemma4VisionTransformerBlock]

    init(config: Gemma4VisionConfiguration) {
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in
            Gemma4VisionTransformerBlock(config: config)
        }
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        positions: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none
    ) -> MLXArray {
        var h = hiddenStates
        for layer in layers {
            h = layer(h, positions: positions, mask: mask)
        }
        return h
    }
}

final class Gemma4VisionPooler: Module {
    let hiddenSize: Int
    let defaultOutputLength: Int
    let poolingKernelSize: Int
    let rootHiddenSize: Float

    init(config: Gemma4VisionConfiguration) {
        self.hiddenSize = config.hiddenSize
        self.defaultOutputLength = config.defaultOutputLength
        self.poolingKernelSize = config.poolingKernelSize
        self.rootHiddenSize = sqrt(Float(config.hiddenSize))
    }

    private func avgPoolByPositions(
        _ x: MLXArray,
        patchPositions: MLXArray,
        length: Int
    ) -> (MLXArray, MLXArray) {
        let kernelSize = max(poolingKernelSize, 1)
        let kernelSquare = max(kernelSize * kernelSize, 1)

        let clampedPositions = MLX.where(
            patchPositions .< MLXArray(0),
            MLXArray.zeros(like: patchPositions),
            patchPositions
        )

        let xPositions = clampedPositions[0..., 0..., 0]
        let maxX = max(xPositions, axis: -1, keepDims: true) + MLXArray(1)
        let kernelPositions =
            floor(clampedPositions.asType(.float32) / MLXArray(Float(kernelSize))).asType(.int32)
        let kernelX = kernelPositions[0..., 0..., 0]
        let kernelY = kernelPositions[0..., 0..., 1]
        let kernelIndices = kernelX + (maxX / MLXArray(Int32(kernelSize))) * kernelY

        let classes = MLXArray(0..<length).asType(.int32)
        let weights =
            (expandedDimensions(kernelIndices, axis: -1) .== classes).asType(.float32)
            / MLXArray(Float(kernelSquare))

        let output = matmul(weights.transposed(0, 2, 1).asType(x.dtype), x)
        let mask = sum(weights, axis: 1) .> MLXArray(0.0)
        return (output, mask)
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        patchPositions: MLXArray,
        paddingPositions: MLXArray,
        outputLength: Int? = nil
    ) -> (MLXArray, MLXArray) {
        let maskedHiddenStates = MLX.where(
            expandedDimensions(paddingPositions, axis: -1),
            MLXArray.zeros(like: hiddenStates),
            hiddenStates
        )

        let length = outputLength ?? defaultOutputLength
        var pooled = maskedHiddenStates
        var validMask = MLXArray.ones([hiddenStates.dim(0), length], type: Bool.self)

        if maskedHiddenStates.dim(1) != length {
            (pooled, validMask) = avgPoolByPositions(
                maskedHiddenStates,
                patchPositions: patchPositions,
                length: length
            )
        }

        pooled = pooled * MLXArray(rootHiddenSize)
        return (pooled, validMask)
    }
}

final class Gemma4VisionModel: Module {
    let config: Gemma4VisionConfiguration

    @ModuleInfo(key: "patch_embedder") var patchEmbedder: Gemma4VisionPatchEmbedder
    @ModuleInfo(key: "encoder") var encoder: Gemma4VisionTransformerModel
    @ModuleInfo var pooler: Gemma4VisionPooler

    init(config: Gemma4VisionConfiguration) {
        self.config = config
        self._patchEmbedder.wrappedValue = Gemma4VisionPatchEmbedder(config: config)
        self._encoder.wrappedValue = Gemma4VisionTransformerModel(config: config)
        self._pooler.wrappedValue = Gemma4VisionPooler(config: config)
    }

    private func patchGrid(_ pixelValues: MLXArray) -> (Int, Int, MLXArray, MLXArray, Int) {
        precondition(pixelValues.dim(0) == 1, "Current Gemma4 vision path supports batch size 1.")
        let patchH = pixelValues.dim(2) / config.patchSize
        let patchW = pixelValues.dim(3) / config.patchSize
        let numPatches = patchH * patchW

        var positions: [Int32] = []
        var paddingMask: [Bool] = []
        positions.reserveCapacity(numPatches * 2)
        paddingMask.reserveCapacity(numPatches)
        for y in 0..<patchH {
            for x in 0..<patchW {
                positions.append(Int32(x))
                positions.append(Int32(y))
                paddingMask.append(false)
            }
        }

        return (
            patchH,
            patchW,
            MLXArray(positions).reshaped(1, numPatches, 2),
            MLXArray(paddingMask).reshaped(1, numPatches),
            numPatches
        )
    }

    func callAsFunction(_ pixelValues: MLXArray, outputLength: Int? = nil) -> MLXArray {
        let (_, _, patchPositions, paddingPositions, numRealPatches) = patchGrid(pixelValues)
        let realPositions = patchPositions[0..., ..<numRealPatches, 0...]
        let xIndices = realPositions[0..., 0..., 0].squeezed(axis: 0)
        let yIndices = realPositions[0..., 0..., 1].squeezed(axis: 0)

        var hiddenStates = patchEmbedder(pixelValues, xIndices: xIndices, yIndices: yIndices)

        let validMask = paddingPositions .== MLXArray(false)
        let attentionAllowed =
            expandedDimensions(validMask, axis: 1) .&& expandedDimensions(validMask, axis: 2)
        let attentionValues = MLX.where(
            attentionAllowed,
            MLXArray(0.0).asType(hiddenStates.dtype),
            MLXArray(-Float.infinity).asType(hiddenStates.dtype)
        )
        let attentionMask = MLXFast.ScaledDotProductAttentionMaskMode.array(
            expandedDimensions(attentionValues, axis: 1)
        )

        hiddenStates = encoder(hiddenStates, positions: patchPositions, mask: attentionMask)
        let pooledOutputLength = outputLength ?? config.defaultOutputLength
        let (pooled, poolMask) = pooler(
            hiddenStates,
            patchPositions: patchPositions,
            paddingPositions: paddingPositions,
            outputLength: pooledOutputLength
        )
        hiddenStates = pooled

        if config.standardize {
            hiddenStates =
                (hiddenStates - MLXArray.zeros([config.hiddenSize]))
                * MLXArray.ones([config.hiddenSize])
        }
        let validPooledTokens = poolMask.asType(.int32).sum().item(Int.self)
        print(
            "[VLM] vision encoded — realPatches=\(numRealPatches), "
                + "pooledTokens=\(hiddenStates.dim(1)), "
                + "validPooledTokens=\(validPooledTokens), "
                + "targetOutputLength=\(pooledOutputLength), "
                + "hidden=\(hiddenStates.dim(2))"
        )
        return hiddenStates
    }
}

final class Gemma4MultimodalProjector: Module {
    @ModuleInfo(key: "embedding_projection") var embeddingProjection: Linear
    @ModuleInfo(key: "embedding_pre_projection_norm") var embeddingPreProjectionNorm: RMSNormNoScale

    init(inputDim: Int, outputDim: Int, eps: Float) {
        self._embeddingProjection.wrappedValue = Linear(inputDim, outputDim, bias: false)
        self._embeddingPreProjectionNorm.wrappedValue = RMSNormNoScale(eps: eps)
    }

    func callAsFunction(_ inputsEmbeds: MLXArray) -> MLXArray {
        embeddingProjection(embeddingPreProjectionNorm(inputsEmbeds))
    }
}
