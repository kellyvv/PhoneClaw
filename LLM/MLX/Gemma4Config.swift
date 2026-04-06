import Foundation
import MLXLMCommon

// MARK: - Gemma 4 Text Configuration

public struct Gemma4TextConfiguration: Codable, Sendable {
    public let modelType: String
    public let hiddenSize: Int
    public let numHiddenLayers: Int
    public let intermediateSize: Int
    public let numAttentionHeads: Int
    public let headDim: Int
    public let globalHeadDim: Int
    public let numKeyValueHeads: Int
    public let numKvSharedLayers: Int
    public let hiddenSizePerLayerInput: Int
    public let vocabSize: Int
    public let vocabSizePerLayerInput: Int
    public let rmsNormEps: Float
    public let slidingWindow: Int
    public let slidingWindowPattern: Int
    public let maxPositionEmbeddings: Int
    public let finalLogitSoftcapping: Float?
    public let hiddenActivation: String
    public let useDoubleWideMlp: Bool
    public let tieWordEmbeddings: Bool
    public let attentionBias: Bool
    public let layerTypes: [String]
    public let ropeParameters: [String: RoPELayerConfig]?

    // Defaults for fields that may be absent
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? "gemma4_text"
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        numHiddenLayers = try c.decode(Int.self, forKey: .numHiddenLayers)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 8
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? 256
        globalHeadDim = try c.decodeIfPresent(Int.self, forKey: .globalHeadDim) ?? 512
        numKeyValueHeads = try c.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? 1
        numKvSharedLayers = try c.decodeIfPresent(Int.self, forKey: .numKvSharedLayers) ?? 0
        hiddenSizePerLayerInput = try c.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput) ?? 0
        vocabSize = try c.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 262144
        vocabSizePerLayerInput = try c.decodeIfPresent(Int.self, forKey: .vocabSizePerLayerInput) ?? 262144
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        slidingWindow = try c.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 512
        slidingWindowPattern = try c.decodeIfPresent(Int.self, forKey: .slidingWindowPattern) ?? 5
        maxPositionEmbeddings = try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        finalLogitSoftcapping = try c.decodeIfPresent(Float.self, forKey: .finalLogitSoftcapping)
        hiddenActivation = try c.decodeIfPresent(String.self, forKey: .hiddenActivation) ?? "gelu_pytorch_tanh"
        useDoubleWideMlp = try c.decodeIfPresent(Bool.self, forKey: .useDoubleWideMlp) ?? false
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        attentionBias = try c.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false

        // layer_types: if absent, generate from sliding_window_pattern
        if let types = try c.decodeIfPresent([String].self, forKey: .layerTypes) {
            layerTypes = types
        } else {
            let pattern = Array(repeating: "sliding_attention", count: slidingWindowPattern - 1) + ["full_attention"]
            layerTypes = Array((0..<numHiddenLayers).map { pattern[$0 % pattern.count] })
        }

        ropeParameters = try c.decodeIfPresent([String: RoPELayerConfig].self, forKey: .ropeParameters)
    }

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case headDim = "head_dim"
        case globalHeadDim = "global_head_dim"
        case numKeyValueHeads = "num_key_value_heads"
        case numKvSharedLayers = "num_kv_shared_layers"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case vocabSize = "vocab_size"
        case vocabSizePerLayerInput = "vocab_size_per_layer_input"
        case rmsNormEps = "rms_norm_eps"
        case slidingWindow = "sliding_window"
        case slidingWindowPattern = "sliding_window_pattern"
        case maxPositionEmbeddings = "max_position_embeddings"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case hiddenActivation = "hidden_activation"
        case useDoubleWideMlp = "use_double_wide_mlp"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case layerTypes = "layer_types"
        case ropeParameters = "rope_parameters"
    }

    /// Index of first KV-shared layer
    public var firstKvSharedLayerIdx: Int {
        numHiddenLayers - numKvSharedLayers
    }
}

// MARK: - RoPE Layer Configuration

public struct RoPELayerConfig: Codable, Sendable {
    public let ropeTheta: Float?
    public let ropeType: String?
    public let partialRotaryFactor: Float?

    enum CodingKeys: String, CodingKey {
        case ropeTheta = "rope_theta"
        case ropeType = "rope_type"
        case partialRotaryFactor = "partial_rotary_factor"
    }
}

// MARK: - Gemma 4 Model Configuration (top-level)

public struct Gemma4ModelConfiguration: Codable, Sendable {
    public let textConfig: Gemma4TextConfiguration
    public let visionConfig: Gemma4VisionConfiguration?
    public let audioConfig: Gemma4AudioConfiguration?
    public let modelType: String
    public let quantization: BaseConfiguration.Quantization?
    public let tieWordEmbeddings: Bool
    public let visionSoftTokensPerImage: Int?

    // Token IDs (for future multimodal use)
    public let imageTokenId: Int?
    public let audioTokenId: Int?

    enum CodingKeys: String, CodingKey {
        case textConfig = "text_config"
        case visionConfig = "vision_config"
        case audioConfig = "audio_config"
        case modelType = "model_type"
        case quantization
        case tieWordEmbeddings = "tie_word_embeddings"
        case visionSoftTokensPerImage = "vision_soft_tokens_per_image"
        case imageTokenId = "image_token_id"
        case audioTokenId = "audio_token_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textConfig = try c.decode(Gemma4TextConfiguration.self, forKey: .textConfig)
        visionConfig = try c.decodeIfPresent(Gemma4VisionConfiguration.self, forKey: .visionConfig)
        audioConfig = try c.decodeIfPresent(Gemma4AudioConfiguration.self, forKey: .audioConfig)
        modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? "gemma4"
        quantization = try c.decodeIfPresent(BaseConfiguration.Quantization.self, forKey: .quantization)
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        visionSoftTokensPerImage = try c.decodeIfPresent(Int.self, forKey: .visionSoftTokensPerImage)
        imageTokenId = try c.decodeIfPresent(Int.self, forKey: .imageTokenId)
        audioTokenId = try c.decodeIfPresent(Int.self, forKey: .audioTokenId)
    }

    public init(
        textConfig: Gemma4TextConfiguration,
        visionConfig: Gemma4VisionConfiguration?,
        audioConfig: Gemma4AudioConfiguration?,
        modelType: String,
        quantization: BaseConfiguration.Quantization?,
        tieWordEmbeddings: Bool,
        visionSoftTokensPerImage: Int?,
        imageTokenId: Int?,
        audioTokenId: Int?
    ) {
        self.textConfig = textConfig
        self.visionConfig = visionConfig
        self.audioConfig = audioConfig
        self.modelType = modelType
        self.quantization = quantization
        self.tieWordEmbeddings = tieWordEmbeddings
        self.visionSoftTokensPerImage = visionSoftTokensPerImage
        self.imageTokenId = imageTokenId
        self.audioTokenId = audioTokenId
    }

    public func withAudioCapability(enabled: Bool) -> Gemma4ModelConfiguration {
        Gemma4ModelConfiguration(
            textConfig: textConfig,
            visionConfig: visionConfig,
            audioConfig: enabled ? audioConfig : nil,
            modelType: modelType,
            quantization: quantization,
            tieWordEmbeddings: tieWordEmbeddings,
            visionSoftTokensPerImage: visionSoftTokensPerImage,
            imageTokenId: imageTokenId,
            audioTokenId: audioTokenId
        )
    }
}

// MARK: - Gemma 4 Vision Configuration

public struct Gemma4VisionConfiguration: Codable, Sendable {
    public let modelType: String
    public let hiddenSize: Int
    public let intermediateSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let numKeyValueHeads: Int
    public let headDim: Int
    public let patchSize: Int
    public let poolingKernelSize: Int
    public let defaultOutputLength: Int
    public let positionEmbeddingSize: Int
    public let rmsNormEps: Float
    public let standardize: Bool
    public let useClippedLinears: Bool
    public let ropeParameters: RoPELayerConfig?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case patchSize = "patch_size"
        case poolingKernelSize = "pooling_kernel_size"
        case defaultOutputLength = "default_output_length"
        case positionEmbeddingSize = "position_embedding_size"
        case rmsNormEps = "rms_norm_eps"
        case standardize
        case useClippedLinears = "use_clipped_linears"
        case ropeParameters = "rope_parameters"
    }
}

// MARK: - Gemma 4 Audio Configuration

public struct Gemma4AudioConfiguration: Codable, Sendable {
    public let modelType: String
    public let hiddenSize: Int
    public let numHiddenLayers: Int
    public let numAttentionHeads: Int
    public let subsamplingConvChannels: [Int]
    public let convKernelSize: Int
    public let residualWeight: Float
    public let attentionChunkSize: Int
    public let attentionContextLeft: Int
    public let attentionContextRight: Int
    public let attentionLogitCap: Float
    public let attentionInvalidLogitsValue: Float
    public let useClippedLinears: Bool
    public let gradientClipping: Float
    public let outputProjDims: Int?
    public let rmsNormEps: Float

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case subsamplingConvChannels = "subsampling_conv_channels"
        case convKernelSize = "conv_kernel_size"
        case residualWeight = "residual_weight"
        case attentionChunkSize = "attention_chunk_size"
        case attentionContextLeft = "attention_context_left"
        case attentionContextRight = "attention_context_right"
        case attentionLogitCap = "attention_logit_cap"
        case attentionInvalidLogitsValue = "attention_invalid_logits_value"
        case useClippedLinears = "use_clipped_linears"
        case gradientClipping = "gradient_clipping"
        case outputProjDims = "output_proj_dims"
        case rmsNormEps = "rms_norm_eps"
    }

    public init(
        modelType: String,
        hiddenSize: Int,
        numHiddenLayers: Int,
        numAttentionHeads: Int,
        subsamplingConvChannels: [Int],
        convKernelSize: Int,
        residualWeight: Float,
        attentionChunkSize: Int,
        attentionContextLeft: Int,
        attentionContextRight: Int,
        attentionLogitCap: Float,
        attentionInvalidLogitsValue: Float,
        useClippedLinears: Bool,
        gradientClipping: Float,
        outputProjDims: Int?,
        rmsNormEps: Float
    ) {
        self.modelType = modelType
        self.hiddenSize = hiddenSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.subsamplingConvChannels = subsamplingConvChannels
        self.convKernelSize = convKernelSize
        self.residualWeight = residualWeight
        self.attentionChunkSize = attentionChunkSize
        self.attentionContextLeft = attentionContextLeft
        self.attentionContextRight = attentionContextRight
        self.attentionLogitCap = attentionLogitCap
        self.attentionInvalidLogitsValue = attentionInvalidLogitsValue
        self.useClippedLinears = useClippedLinears
        self.gradientClipping = gradientClipping
        self.outputProjDims = outputProjDims
        self.rmsNormEps = rmsNormEps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? "gemma4_audio"
        hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1024
        numHiddenLayers = try c.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 12
        numAttentionHeads = try c.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 8
        subsamplingConvChannels = try c.decodeIfPresent([Int].self, forKey: .subsamplingConvChannels)
            ?? [128, 32]
        convKernelSize = try c.decodeIfPresent(Int.self, forKey: .convKernelSize) ?? 5
        residualWeight = try c.decodeIfPresent(Float.self, forKey: .residualWeight) ?? 0.5
        attentionChunkSize = try c.decodeIfPresent(Int.self, forKey: .attentionChunkSize) ?? 12
        attentionContextLeft = try c.decodeIfPresent(Int.self, forKey: .attentionContextLeft) ?? 13
        attentionContextRight = try c.decodeIfPresent(Int.self, forKey: .attentionContextRight) ?? 0
        attentionLogitCap = try c.decodeIfPresent(Float.self, forKey: .attentionLogitCap) ?? 50
        attentionInvalidLogitsValue =
            try c.decodeIfPresent(Float.self, forKey: .attentionInvalidLogitsValue) ?? -1_000_000_000
        useClippedLinears = try c.decodeIfPresent(Bool.self, forKey: .useClippedLinears) ?? true
        gradientClipping =
            try c.decodeIfPresent(Float.self, forKey: .gradientClipping) ?? 10_000_000_000
        outputProjDims = try c.decodeIfPresent(Int.self, forKey: .outputProjDims)
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
    }
}

// MARK: - Gemma 4 Processor Configuration

public struct Gemma4ProcessorConfiguration: Codable, Sendable {
    public let processorClass: String
    public let imageSeqLength: Int
    public let audioSeqLength: Int
    public let audioMsPerToken: Int?
    public let imageProcessor: ImageProcessor
    public let featureExtractor: AudioFeatureExtractor?

    public struct AudioFeatureExtractor: Codable, Sendable {
        public let featureExtractorType: String
        public let samplingRate: Int
        public let numMelFilters: Int
        public let fftLength: Int
        public let hopLength: Int
        public let chunkDuration: Double
        public let overlapDuration: Double

        enum CodingKeys: String, CodingKey {
            case featureExtractorType = "feature_extractor_type"
            case samplingRate = "sampling_rate"
            case numMelFilters = "num_mel_filters"
            case fftLength = "fft_length"
            case hopLength = "hop_length"
            case chunkDuration = "chunk_duration"
            case overlapDuration = "overlap_duration"
        }
    }

    public struct ImageProcessor: Codable, Sendable {
        public let imageProcessorType: String
        public let doConvertRgb: Bool
        public let doNormalize: Bool
        public let doRescale: Bool
        public let doResize: Bool
        public let imageMean: [CGFloat]
        public let imageStd: [CGFloat]
        public let imageSeqLength: Int
        public let maxSoftTokens: Int
        public let patchSize: Int
        public let poolingKernelSize: Int
        public let resample: Int
        public let rescaleFactor: Float
        public let size: ImageSize

        public struct ImageSize: Codable, Sendable {
            public let height: Int
            public let width: Int
        }

        public var targetSize: CGSize {
            CGSize(width: size.width, height: size.height)
        }

        public var imageMeanTuple: (CGFloat, CGFloat, CGFloat) {
            (imageMean[0], imageMean[1], imageMean[2])
        }

        public var imageStdTuple: (CGFloat, CGFloat, CGFloat) {
            (imageStd[0], imageStd[1], imageStd[2])
        }

        enum CodingKeys: String, CodingKey {
            case imageProcessorType = "image_processor_type"
            case doConvertRgb = "do_convert_rgb"
            case doNormalize = "do_normalize"
            case doRescale = "do_rescale"
            case doResize = "do_resize"
            case imageMean = "image_mean"
            case imageStd = "image_std"
            case imageSeqLength = "image_seq_length"
            case maxSoftTokens = "max_soft_tokens"
            case patchSize = "patch_size"
            case poolingKernelSize = "pooling_kernel_size"
            case resample
            case rescaleFactor = "rescale_factor"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case processorClass = "processor_class"
        case imageSeqLength = "image_seq_length"
        case audioSeqLength = "audio_seq_length"
        case audioMsPerToken = "audio_ms_per_token"
        case imageProcessor = "image_processor"
        case featureExtractor = "feature_extractor"
    }
}
