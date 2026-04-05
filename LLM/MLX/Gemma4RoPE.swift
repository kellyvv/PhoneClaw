import MLX
import MLXNN
import MLXLMCommon

// MARK: - ProportionalRoPE

/// Proportional RoPE for Gemma 4 full-attention layers.
///
/// Frequencies are computed relative to the full head dimension (not just the
/// rotated portion), and rotation is applied to the first rotated_dims//2
/// elements of each half of the head — matching HF's rotate_half convention.
public class ProportionalRoPE: Module {
    let dims: Int
    let traditional: Bool
    let rotatedDims: Int
    let _freqs: MLXArray?

    public init(
        dims: Int,
        traditional: Bool = false,
        base: Float = 10000.0,
        partialRotaryFactor: Float = 1.0,
        factor: Float = 1.0
    ) {
        self.dims = dims
        self.traditional = traditional

        let ropeAngles = Int(partialRotaryFactor * Float(dims) / 2.0)
        self.rotatedDims = 2 * ropeAngles

        if rotatedDims > 0 {
            let exponents = MLXArray(stride(from: 0, to: rotatedDims, by: 2))
                .asType(.float32) / Float(dims)
            self._freqs = factor * pow(MLXArray(base), exponents)
        } else {
            self._freqs = nil
        }
    }

    public func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        if rotatedDims <= 0 { return x }

        let ellipsis = MLXEllipsisIndex.ellipsis

        let head = x[.ellipsis, ..<dims]
        let tail = x[.ellipsis, dims...]

        let half = dims / 2
        let left = head[.ellipsis, ..<half]
        let right = head[.ellipsis, half...]

        // Concatenate the parts to rotate from each half
        let toRotate = concatenated(
            [left[.ellipsis, ..<(rotatedDims / 2)], right[.ellipsis, ..<(rotatedDims / 2)]],
            axis: -1
        )

        // Apply fast rope with custom frequencies
        let rotated = MLXFast.RoPE(
            toRotate,
            dimensions: rotatedDims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )

        // Reassemble: rotated parts + unrotated remainders
        let rotatedLeft = rotated[ellipsis, ..<(rotatedDims / 2)]
        let rotatedRight = rotated[ellipsis, (rotatedDims / 2)...]
        let leftRemainder = left[ellipsis, (rotatedDims / 2)...]
        let rightRemainder = right[ellipsis, (rotatedDims / 2)...]

        let newLeft = concatenated(
            [rotatedLeft, leftRemainder],
            axis: -1
        )
        let newRight = concatenated(
            [rotatedRight, rightRemainder],
            axis: -1
        )
        let newHead = concatenated([newLeft, newRight], axis: -1)

        if tail.dim(-1) == 0 {
            return newHead
        }
        return concatenated([newHead, tail], axis: -1)
    }
}

// MARK: - RoPE Factory

/// Initialize the appropriate RoPE variant based on configuration.
public func initializeGemma4Rope(
    dims: Int,
    traditional: Bool = false,
    base: Float = 10000.0,
    ropeConfig: RoPELayerConfig?
) -> Module {
    guard let config = ropeConfig else {
        return RoPE(dimensions: dims, traditional: traditional, base: base)
    }

    let ropeType = config.ropeType ?? "default"
    let theta = config.ropeTheta ?? base

    if ropeType == "proportional" {
        let partialFactor = config.partialRotaryFactor ?? 1.0
        return ProportionalRoPE(
            dims: dims,
            traditional: traditional,
            base: theta,
            partialRotaryFactor: partialFactor
        )
    }

    // Default: standard RoPE
    return RoPE(dimensions: dims, traditional: traditional, base: theta)
}
