import Foundation
import MLX
import MLXFast
import MLXNN

private func gemma4AudioSigmoid(_ x: MLXArray) -> MLXArray {
    MLXArray(1) / (MLXArray(1) + exp(-x))
}

private func gemma4AudioSilu(_ x: MLXArray) -> MLXArray {
    x * gemma4AudioSigmoid(x)
}

private func gemma4AudioSoftplus(_ x: MLXArray) -> MLXArray {
    log(MLXArray(1) + exp(x))
}

private func gemma4AudioRelu(_ x: MLXArray) -> MLXArray {
    maximum(x, MLXArray(0))
}

private func gemma4AudioPaddingWidths(
    ndim: Int,
    updates: [(Int, Int, Int)]
) -> [IntOrPair] {
    var widths = Array(repeating: IntOrPair(0), count: ndim)
    for (axis, before, after) in updates {
        widths[axis] = IntOrPair((before, after))
    }
    return widths
}

final class Gemma4AudioRMSNorm: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    let eps: Float

    init(dim: Int, eps: Float = 1e-6) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dim])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

final class Gemma4AudioConvBlock: Module {
    @ModuleInfo(key: "conv") var conv: Conv2d
    @ModuleInfo(key: "norm") var norm: LayerNorm

    let timeStride = 2

    init(config: Gemma4AudioConfiguration, index: Int) {
        let inputChannels = index == 0 ? 1 : config.subsamplingConvChannels[index - 1]
        let outputChannels = config.subsamplingConvChannels[index]
        self._conv.wrappedValue = Conv2d(
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            kernelSize: [3, 3],
            stride: [2, 2],
            padding: 0,
            bias: false
        )
        self._norm.wrappedValue = LayerNorm(
            dimensions: outputChannels,
            eps: config.rmsNormEps,
            affine: true,
            bias: false
        )
    }

    func callAsFunction(_ x: MLXArray, invalidMask: MLXArray) -> (MLXArray, MLXArray) {
        let expandedMask = invalidMask.expandedDimensions(axis: -1).expandedDimensions(axis: -1)
        var hiddenStates = MLX.where(expandedMask, MLXArray(0, dtype: x.dtype), x)
        hiddenStates = padded(
            hiddenStates,
            widths: gemma4AudioPaddingWidths(
                ndim: hiddenStates.ndim,
                updates: [(1, 1, 1), (2, 1, 1)]
            ),
            value: MLXArray(0, dtype: hiddenStates.dtype)
        )
        hiddenStates = gemma4AudioRelu(norm(conv(hiddenStates)))

        let strideIndices = MLXArray(
            Array(stride(from: 0, to: invalidMask.dim(1), by: timeStride)).map(Int32.init)
        )
        let downsampledMask = take(invalidMask, strideIndices, axis: 1)
        let trimmedMask = downsampledMask[0..., ..<hiddenStates.dim(1)]
        return (hiddenStates, trimmedMask)
    }
}

final class Gemma4AudioSubsampleProjection: Module {
    private static let inputFeatureSize = 128

    @ModuleInfo(key: "layer0") var layer0: Gemma4AudioConvBlock
    @ModuleInfo(key: "layer1") var layer1: Gemma4AudioConvBlock
    @ModuleInfo(key: "input_proj_linear") var inputProjLinear: Linear

    init(config: Gemma4AudioConfiguration) {
        self._layer0.wrappedValue = Gemma4AudioConvBlock(config: config, index: 0)
        self._layer1.wrappedValue = Gemma4AudioConvBlock(config: config, index: 1)

        var frequency = Self.inputFeatureSize
        for _ in 0..<2 {
            frequency = ((frequency + 2 - 3) / 2) + 1
        }
        let projectionInputDim = frequency * config.subsamplingConvChannels.last!
        self._inputProjLinear.wrappedValue = Linear(
            projectionInputDim,
            config.hiddenSize,
            bias: false
        )
    }

    func callAsFunction(_ audioMel: MLXArray, invalidMask: MLXArray) -> (MLXArray, MLXArray) {
        var hiddenStates = audioMel.expandedDimensions(axis: -1)
        var currentMask = invalidMask

        (hiddenStates, currentMask) = layer0(hiddenStates, invalidMask: currentMask)
        (hiddenStates, currentMask) = layer1(hiddenStates, invalidMask: currentMask)

        let flattened = hiddenStates.reshaped(
            hiddenStates.dim(0),
            hiddenStates.dim(1),
            hiddenStates.dim(2) * hiddenStates.dim(3)
        )
        return (inputProjLinear(flattened), currentMask)
    }
}

final class Gemma4AudioRelativePositionEmbedding {
    let numHeads: Int
    let channels: Int
    let headDim: Int
    let maxBackward: Int
    let maxForward: Int
    let invTimescales: MLXArray
    let relativeKProj: Linear

    init(config: Gemma4AudioConfiguration, relativeKProj: Linear) {
        self.numHeads = config.numAttentionHeads
        self.channels = config.hiddenSize
        self.headDim = config.hiddenSize / config.numAttentionHeads
        self.maxBackward = max(0, config.attentionContextLeft - 1)
        self.maxForward = config.attentionContextRight
        self.relativeKProj = relativeKProj

        let numTimescales = max(channels / 2, 1)
        let minTimescale: Float = 1
        let maxTimescale: Float = 10_000
        let logTimescaleIncrement = Float(
            Foundation.log(Double(maxTimescale / minTimescale))
        ) / Float(max(numTimescales - 1, 1))
        let scales: [Float] = (0..<numTimescales).map { index in
            minTimescale * Float(Foundation.exp(Double(Float(index) * -logTimescaleIncrement)))
        }
        self.invTimescales = MLXArray(scales).reshaped(1, 1, numTimescales)
    }

    func callAsFunction(_ queries: MLXArray, _ keys: MLXArray) -> MLXArray {
        let batchSize = queries.dim(0)
        let numBlocks = queries.dim(1)
        let blockSize = queries.dim(2)
        let contextSize = keys.dim(2)
        let maxSpanPlusOne = maxBackward + maxForward + 1

        let positionValues = Array(stride(from: maxBackward, through: -maxForward, by: -1)).map(Float.init)
        let positionIndices = MLXArray(positionValues).reshaped(1, maxSpanPlusOne)
        let sinusoid = positionIndices.expandedDimensions(axis: -1).asType(.float32) * invTimescales
        let timingSignal = concatenated([sin(sinusoid), cos(sinusoid)], axis: -1)
        let projected = relativeKProj(timingSignal.asType(relativeKProj.weight.dtype))
            .reshaped(maxSpanPlusOne, numHeads, headDim)
            .asType(queries.dtype)

        let queriesP = queries.transposed(0, 3, 1, 2, 4)
        let keysP = keys.transposed(0, 3, 1, 4, 2)
        let termAC = matmul(queriesP, keysP)

        let sinEmbT = projected.transposed(1, 2, 0)
        let reshapedQueries = queriesP.reshaped(batchSize, numHeads, numBlocks * blockSize, headDim)
        var termBD = matmul(reshapedQueries, sinEmbT)
            .reshaped(batchSize, numHeads, numBlocks, blockSize, maxSpanPlusOne)

        let padAmount = max((contextSize + 1) - maxSpanPlusOne, 0)
        if padAmount > 0 {
            termBD = padded(
                termBD,
                widths: gemma4AudioPaddingWidths(
                    ndim: termBD.ndim,
                    updates: [(4, 0, padAmount)]
                )
            )
        }
        termBD = termBD.reshaped(batchSize, numHeads, numBlocks, blockSize * (contextSize + 1))
        termBD = termBD[0..., 0..., 0..., ..<(blockSize * contextSize)]
        termBD = termBD.reshaped(batchSize, numHeads, numBlocks, blockSize, contextSize)

        return termAC + termBD
    }
}

final class Gemma4AudioAttention: Module {
    @ModuleInfo(key: "relative_k_proj") var relativeKProj: Linear
    @ParameterInfo(key: "per_dim_scale") var perDimScale: MLXArray
    @ModuleInfo(key: "q_proj") var qProj: Gemma4ClippableLinear
    @ModuleInfo(key: "k_proj") var kProj: Gemma4ClippableLinear
    @ModuleInfo(key: "v_proj") var vProj: Gemma4ClippableLinear
    @ModuleInfo(key: "post") var post: Gemma4ClippableLinear

    let numHeads: Int
    let hiddenSize: Int
    let headDim: Int
    let chunkSize: Int
    let maxFutureHorizon: Int
    let maxPastHorizon: Int
    let contextSize: Int
    let invalidLogitsValue: Float
    let softcap: Float
    let qScale: Float
    let kScale: Float
    let relativePositionEmbedding: Gemma4AudioRelativePositionEmbedding

    init(config: Gemma4AudioConfiguration) {
        self.numHeads = config.numAttentionHeads
        self.hiddenSize = config.hiddenSize
        self.headDim = config.hiddenSize / config.numAttentionHeads
        self.chunkSize = config.attentionChunkSize
        self.maxFutureHorizon = config.attentionContextRight
        self.maxPastHorizon = max(0, config.attentionContextLeft - 1)
        self.contextSize = chunkSize + maxPastHorizon + maxFutureHorizon
        self.invalidLogitsValue = config.attentionInvalidLogitsValue
        self.softcap = config.attentionLogitCap
        self.qScale = Float(Foundation.pow(Double(headDim), -0.5) / Foundation.log(2.0))
        self.kScale = Float(Foundation.log(1.0 + Foundation.exp(1.0)) / Foundation.log(2.0))

        self._relativeKProj.wrappedValue = Linear(
            config.hiddenSize,
            config.numAttentionHeads * (config.hiddenSize / config.numAttentionHeads),
            bias: false
        )
        self._perDimScale.wrappedValue = MLXArray.zeros([headDim])
        self._qProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.numAttentionHeads * headDim,
            useClipping: config.useClippedLinears
        )
        self._kProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.numAttentionHeads * headDim,
            useClipping: config.useClippedLinears
        )
        self._vProj.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.numAttentionHeads * headDim,
            useClipping: config.useClippedLinears
        )
        self._post.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.hiddenSize,
            useClipping: config.useClippedLinears
        )
        self.relativePositionEmbedding = Gemma4AudioRelativePositionEmbedding(
            config: config,
            relativeKProj: _relativeKProj.wrappedValue
        )
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        invalidMask: MLXArray,
        causalValidMask: MLXArray
    ) -> MLXArray {
        let batch = hiddenStates.dim(0)
        let length = hiddenStates.dim(1)
        let qkvShape = [batch, length, numHeads, headDim]

        var queries = qProj(hiddenStates).asType(.float32).reshaped(qkvShape)
        var keys = kProj(hiddenStates).asType(.float32).reshaped(qkvShape)
        let values = vProj(hiddenStates).asType(.float32).reshaped(qkvShape)

        let scaledPerDim = gemma4AudioSoftplus(perDimScale)
        queries = queries * MLXArray(qScale) * scaledPerDim
        keys = keys * MLXArray(kScale)

        let queryBlocks = convertToBlock(queries)
        let keyBlocks = extractBlockContext(keys)
        let valueBlocks = extractBlockContext(values)

        let validMask = logicalNot(invalidMask)
        let extractedValid = extractBlockContext(validMask)
        let condition =
            extractedValid.expandedDimensions(axis: 1).expandedDimensions(axis: 3)
            .&& causalValidMask.expandedDimensions(axis: 0).expandedDimensions(axis: 0).expandedDimensions(axis: 0)

        var logits = relativePositionEmbedding(queryBlocks, keyBlocks)
        logits = tanh(logits / MLXArray(softcap)) * MLXArray(softcap)
        logits = MLX.where(condition, logits, MLXArray(invalidLogitsValue).asType(logits.dtype))

        let probabilities = softmax(logits, axis: -1)
        let valueBlocksPrepared = valueBlocks.transposed(0, 3, 1, 2, 4)
        var context = matmul(probabilities, valueBlocksPrepared)
        context = context.transposed(0, 2, 3, 1, 4)
        context = context.reshaped(batch, queryBlocks.dim(1) * chunkSize, numHeads, headDim)
        context = context[0..., ..<length, 0..., 0...]
        let output = context.reshaped(batch, length, numHeads * headDim)
        return post(output)
    }

    private func convertToBlock(_ x: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let length = x.dim(1)
        let remaining = Array(x.shape.dropFirst(2))
        let numBlocks = (length + chunkSize - 1) / chunkSize
        let padLength = (numBlocks * chunkSize) - length
        let paddedInput: MLXArray
        if padLength > 0 {
            paddedInput = padded(
                x,
                widths: gemma4AudioPaddingWidths(
                    ndim: x.ndim,
                    updates: [(1, 0, padLength)]
                )
            )
        } else {
            paddedInput = x
        }
        return paddedInput.reshaped([batch, numBlocks, chunkSize] + remaining)
    }

    private func extractBlockContext(_ x: MLXArray) -> MLXArray {
        let paddedInput = padded(
            x,
            widths: gemma4AudioPaddingWidths(
                ndim: x.ndim,
                updates: [(1, maxPastHorizon, maxFutureHorizon + chunkSize - 1)]
            )
        )
        let totalLength = paddedInput.dim(1)
        let numBlocks = ((totalLength - contextSize) / chunkSize) + 1
        let slices: [MLXArray] = (0..<numBlocks).map { blockIndex in
            let start = blockIndex * chunkSize
            let indices = MLXArray(Array(start..<(start + contextSize)).map(Int32.init))
            return take(paddedInput, indices, axis: 1)
        }
        return stacked(slices, axis: 1)
    }
}

final class Gemma4AudioFeedForward: Module {
    @ModuleInfo(key: "pre_layer_norm") var preLayerNorm: Gemma4AudioRMSNorm
    @ModuleInfo(key: "ffw_layer_1") var ffwLayer1: Gemma4ClippableLinear
    @ModuleInfo(key: "ffw_layer_2") var ffwLayer2: Gemma4ClippableLinear
    @ModuleInfo(key: "post_layer_norm") var postLayerNorm: Gemma4AudioRMSNorm

    let gradientClipping: Float
    let residualWeight: Float

    init(config: Gemma4AudioConfiguration) {
        self.gradientClipping = config.gradientClipping
        self.residualWeight = config.residualWeight
        self._preLayerNorm.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
        self._ffwLayer1.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.hiddenSize * 4,
            useClipping: config.useClippedLinears
        )
        self._ffwLayer2.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize * 4,
            outFeatures: config.hiddenSize,
            useClipping: config.useClippedLinears
        )
        self._postLayerNorm.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var hiddenStates = clip(x, min: MLXArray(-gradientClipping), max: MLXArray(gradientClipping))
        hiddenStates = preLayerNorm(hiddenStates)
        hiddenStates = ffwLayer1(hiddenStates)
        hiddenStates = gemma4AudioSilu(hiddenStates)
        hiddenStates = ffwLayer2(hiddenStates)
        hiddenStates = clip(hiddenStates, min: MLXArray(-gradientClipping), max: MLXArray(gradientClipping))
        hiddenStates = postLayerNorm(hiddenStates)
        return residual + hiddenStates * MLXArray(residualWeight)
    }
}

final class Gemma4AudioLightConv1d: Module {
    @ModuleInfo(key: "pre_layer_norm") var preLayerNorm: Gemma4AudioRMSNorm
    @ModuleInfo(key: "linear_start") var linearStart: Gemma4ClippableLinear
    @ModuleInfo(key: "depthwise_conv1d") var depthwiseConv1d: Conv1d
    @ModuleInfo(key: "conv_norm") var convNorm: Gemma4AudioRMSNorm
    @ModuleInfo(key: "linear_end") var linearEnd: Gemma4ClippableLinear

    let gradientClipping: Float
    let causalPadding: Int

    init(config: Gemma4AudioConfiguration) {
        self.gradientClipping = config.gradientClipping
        self.causalPadding = config.convKernelSize - 1
        self._preLayerNorm.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
        self._linearStart.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.hiddenSize * 2,
            useClipping: config.useClippedLinears
        )
        self._depthwiseConv1d.wrappedValue = Conv1d(
            inputChannels: config.hiddenSize,
            outputChannels: config.hiddenSize,
            kernelSize: config.convKernelSize,
            stride: 1,
            padding: 0,
            groups: config.hiddenSize,
            bias: false
        )
        self._convNorm.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
        self._linearEnd.wrappedValue = Gemma4ClippableLinear(
            inFeatures: config.hiddenSize,
            outFeatures: config.hiddenSize,
            useClipping: config.useClippedLinears
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var hiddenStates = preLayerNorm(x)
        hiddenStates = linearStart(hiddenStates)

        let half = hiddenStates.dim(-1) / 2
        let x1 = hiddenStates[0..., 0..., ..<half]
        let x2 = hiddenStates[0..., 0..., half...]
        hiddenStates = x1 * gemma4AudioSigmoid(x2)

        hiddenStates = padded(
            hiddenStates,
            widths: gemma4AudioPaddingWidths(
                ndim: hiddenStates.ndim,
                updates: [(1, causalPadding, 0)]
            )
        )
        hiddenStates = depthwiseConv1d(hiddenStates)
        hiddenStates = clip(
            hiddenStates,
            min: MLXArray(-gradientClipping),
            max: MLXArray(gradientClipping)
        )
        hiddenStates = convNorm(hiddenStates)
        hiddenStates = gemma4AudioSilu(hiddenStates)
        hiddenStates = linearEnd(hiddenStates)
        return hiddenStates + residual
    }
}

final class Gemma4AudioConformerBlock: Module {
    @ModuleInfo(key: "feed_forward1") var feedForward1: Gemma4AudioFeedForward
    @ModuleInfo(key: "self_attn") var selfAttn: Gemma4AudioAttention
    @ModuleInfo(key: "lconv1d") var lconv1d: Gemma4AudioLightConv1d
    @ModuleInfo(key: "feed_forward2") var feedForward2: Gemma4AudioFeedForward
    @ModuleInfo(key: "norm_pre_attn") var normPreAttn: Gemma4AudioRMSNorm
    @ModuleInfo(key: "norm_post_attn") var normPostAttn: Gemma4AudioRMSNorm
    @ModuleInfo(key: "norm_out") var normOut: Gemma4AudioRMSNorm

    let gradientClipping: Float

    init(config: Gemma4AudioConfiguration) {
        self.gradientClipping = config.gradientClipping
        self._feedForward1.wrappedValue = Gemma4AudioFeedForward(config: config)
        self._selfAttn.wrappedValue = Gemma4AudioAttention(config: config)
        self._lconv1d.wrappedValue = Gemma4AudioLightConv1d(config: config)
        self._feedForward2.wrappedValue = Gemma4AudioFeedForward(config: config)
        self._normPreAttn.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
        self._normPostAttn.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
        self._normOut.wrappedValue = Gemma4AudioRMSNorm(dim: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray,
        invalidMask: MLXArray,
        causalValidMask: MLXArray
    ) -> MLXArray {
        var hiddenStates = feedForward1(x)

        let residual = hiddenStates
        hiddenStates = clip(hiddenStates, min: MLXArray(-gradientClipping), max: MLXArray(gradientClipping))
        hiddenStates = normPreAttn(hiddenStates)
        hiddenStates = selfAttn(hiddenStates, invalidMask: invalidMask, causalValidMask: causalValidMask)
        hiddenStates = clip(hiddenStates, min: MLXArray(-gradientClipping), max: MLXArray(gradientClipping))
        hiddenStates = residual + normPostAttn(hiddenStates)

        let validityMask = logicalNot(invalidMask).expandedDimensions(axis: -1).asType(hiddenStates.dtype)
        hiddenStates = hiddenStates * validityMask
        hiddenStates = lconv1d(hiddenStates)
        hiddenStates = feedForward2(hiddenStates)
        hiddenStates = clip(hiddenStates, min: MLXArray(-gradientClipping), max: MLXArray(gradientClipping))
        return normOut(hiddenStates)
    }
}

final class Gemma4AudioEncoder: Module {
    @ModuleInfo(key: "subsample_conv_projection") var subsampleConvProjection: Gemma4AudioSubsampleProjection
    @ModuleInfo var layers: [Gemma4AudioConformerBlock]
    @ModuleInfo(key: "output_proj") var outputProj: Linear

    let config: Gemma4AudioConfiguration
    let hasOutputProjection: Bool

    init(config: Gemma4AudioConfiguration) {
        self.config = config
        self.hasOutputProjection = config.outputProjDims != nil
        self._subsampleConvProjection.wrappedValue = Gemma4AudioSubsampleProjection(config: config)
        self._layers.wrappedValue = (0..<config.numHiddenLayers).map { _ in
            Gemma4AudioConformerBlock(config: config)
        }
        self._outputProj.wrappedValue = Linear(
            config.hiddenSize,
            config.outputProjDims ?? config.hiddenSize,
            bias: true
        )
    }

    private func buildCausalValidMask() -> MLXArray {
        let chunkSize = config.attentionChunkSize
        let maxPastHorizon = max(0, config.attentionContextLeft - 1)
        let maxFutureHorizon = config.attentionContextRight
        let upperDiagonal = maxPastHorizon + maxFutureHorizon
        let contextSize = chunkSize + maxPastHorizon + maxFutureHorizon
        let lowerCausal = tril(MLXArray.ones([contextSize, chunkSize])).transposed()
        let upperCausal = tril(MLXArray.ones([chunkSize, contextSize]), k: upperDiagonal)
        return (lowerCausal * upperCausal).asType(.bool)
    }

    func callAsFunction(_ audioMel: MLXArray, invalidMask: MLXArray) -> (MLXArray, MLXArray) {
        var (audioEncodings, currentMask) = subsampleConvProjection(audioMel, invalidMask: invalidMask)
        let causalValidMask = buildCausalValidMask()
        for layer in layers {
            audioEncodings = layer(audioEncodings, invalidMask: currentMask, causalValidMask: causalValidMask)
        }

        if hasOutputProjection {
            audioEncodings = outputProj(audioEncodings)
        }

        if currentMask.dim(1) != audioEncodings.dim(1) {
            currentMask = currentMask[0..., ..<audioEncodings.dim(1)]
        }
        audioEncodings = MLX.where(
            currentMask.expandedDimensions(axis: -1),
            MLXArray(0, dtype: audioEncodings.dtype),
            audioEncodings
        )
        return (audioEncodings, currentMask)
    }
}
