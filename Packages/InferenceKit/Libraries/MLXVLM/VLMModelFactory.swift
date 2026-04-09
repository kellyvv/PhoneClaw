// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXLMCommon

public enum VLMError: LocalizedError, Equatable {
    case imageRequired
    case maskRequired
    case singleImageAllowed
    case singleVideoAllowed
    case singleMediaTypeAllowed
    case imageProcessingFailure(String)
    case processing(String)
    case noVideoTrackFound
    case videoNotDecodable

    public var errorDescription: String? {
        switch self {
        case .imageRequired:
            return String(localized: "An image is required for this operation.")
        case .maskRequired:
            return String(localized: "An image mask is required for this operation.")
        case .singleImageAllowed:
            return String(localized: "Only a single image is allowed for this operation.")
        case .singleVideoAllowed:
            return String(localized: "Only a single video is allowed for this operation.")
        case .singleMediaTypeAllowed:
            return String(
                localized:
                    "Only a single media type (image or video) is allowed for this operation.")
        case .imageProcessingFailure(let details):
            return String(localized: "Failed to process the image: \(details)")
        case .processing(let details):
            return String(localized: "Processing error: \(details)")
        case .noVideoTrackFound:
            return String(localized: "Video file has no video tracks.")
        case .videoNotDecodable:
            return String(localized: "Video file not decodable.")
        }
    }
}

public struct BaseProcessorConfiguration: Codable, Sendable {
    public let processorClass: String

    enum CodingKeys: String, CodingKey {
        case processorClass = "processor_class"
    }
}

/// Creates a function that loads a configuration file and instantiates a model with the proper configuration
private func create<C: Codable, M>(
    _ configurationType: C.Type, _ modelInit: @escaping (C) -> M
) -> (Data) throws -> M {
    { data in
        let configuration = try JSONDecoder.json5().decode(C.self, from: data)
        return modelInit(configuration)
    }
}

private func create<C: Codable, P>(
    _ configurationType: C.Type,
    _ processorInit:
        @escaping (
            C,
            any Tokenizer
        ) -> P
) -> (Data, any Tokenizer) throws -> P {
    { data, tokenizer in
        let configuration = try JSONDecoder.json5().decode(C.self, from: data)
        return processorInit(configuration, tokenizer)
    }
}

/// Registry of VLM model type, e.g 'paligemma', to functions that can instantiate the model
/// from configuration.
///
/// NOTE: Slimmed to Gemma multimodal family (paligemma + gemma3) only for PhoneClaw.
/// Upstream mlx-swift-lm registers many VLM types (Qwen2-VL, Qwen3-VL, Idefics3, SmolVLM,
/// FastVLM, Pixtral, Mistral3, LFM2-VL, GlmOcr, ...). PhoneClaw uses Gemma 4 multimodal
/// exclusively via a custom implementation in `LLM/MLX/Gemma4/Gemma4Model.swift` which
/// registers itself into this shared registry at runtime via
/// `VLMTypeRegistry.shared.registerModelType("gemma4", ...)`.
public enum VLMTypeRegistry {

    /// Shared instance with default model types.
    public static let shared: ModelTypeRegistry = .init(creators: [
        "paligemma": create(PaliGemmaConfiguration.self, PaliGemma.init),
        "gemma3": create(Gemma3Configuration.self, Gemma3.init),
    ])
}

public enum VLMProcessorTypeRegistry {

    /// Shared instance with default processor types.
    /// Slimmed to match `VLMTypeRegistry` — PhoneClaw registers `Gemma4Processor` at runtime.
    public static let shared: ProcessorTypeRegistry = .init(creators: [
        "PaliGemmaProcessor": create(
            PaliGemmaProcessorConfiguration.self, PaliGemmaProcessor.init),
        "Gemma3Processor": create(
            Gemma3ProcessorConfiguration.self, Gemma3Processor.init),
    ])
}

/// Registry of models and any overrides that go with them, e.g. prompt augmentation.
/// If asked for an unknown configuration this will use the model/tokenizer as-is.
///
/// NOTE: Slimmed to Gemma multimodal family only for PhoneClaw. See `VLMTypeRegistry` above.
public class VLMRegistry: AbstractModelRegistry, @unchecked Sendable {

    /// Shared instance with default model configurations.
    public static let shared: VLMRegistry = .init(modelConfigurations: all())

    static public let paligemma3bMix448_8bit = ModelConfiguration(
        id: "mlx-community/paligemma-3b-mix-448-8bit",
        defaultPrompt: "Describe the image in English"
    )

    static public let gemma3_4B_qat_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3-4b-it-qat-4bit",
        defaultPrompt: "Describe the image in English",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3_12B_qat_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3-12b-it-qat-4bit",
        defaultPrompt: "Describe the image in English",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3_27B_qat_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3-27b-it-qat-4bit",
        defaultPrompt: "Describe the image in English",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public func all() -> [ModelConfiguration] {
        [
            paligemma3bMix448_8bit,
            gemma3_4B_qat_4bit,
            gemma3_12B_qat_4bit,
            gemma3_27B_qat_4bit,
        ]
    }

}

@available(*, deprecated, renamed: "VLMRegistry", message: "Please use VLMRegistry directly.")
public typealias ModelRegistry = VLMRegistry

/// Factory for creating new LLMs.
///
/// Callers can use the `shared` instance or create a new instance if custom configuration
/// is required.
///
/// ```swift
/// let modelContainer = try await VLMModelFactory.shared.loadContainer(
///     configuration: VLMRegistry.paligemma3bMix4488bit)
/// ```
public final class VLMModelFactory: ModelFactory {

    public init(
        typeRegistry: ModelTypeRegistry, processorRegistry: ProcessorTypeRegistry,
        modelRegistry: AbstractModelRegistry
    ) {
        self.typeRegistry = typeRegistry
        self.processorRegistry = processorRegistry
        self.modelRegistry = modelRegistry
    }

    /// Shared instance with default behavior.
    public static let shared = VLMModelFactory(
        typeRegistry: VLMTypeRegistry.shared, processorRegistry: VLMProcessorTypeRegistry.shared,
        modelRegistry: VLMRegistry.shared)

    /// registry of model type, e.g. configuration value `paligemma` -> configuration and init methods
    public let typeRegistry: ModelTypeRegistry

    /// registry of input processor type, e.g. configuration value `PaliGemmaProcessor` -> configuration and init methods
    public let processorRegistry: ProcessorTypeRegistry

    /// registry of model id to configuration, e.g. `mlx-community/paligemma-3b-mix-448-8bit`
    public let modelRegistry: AbstractModelRegistry

    public func _load(
        configuration: ResolvedModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> sending ModelContext {
        let modelDirectory = configuration.modelDirectory

        // Load config.json once and decode for both base config and model-specific config
        let configurationURL = modelDirectory.appending(component: "config.json")
        let configData: Data
        do {
            configData = try Data(contentsOf: configurationURL)
        } catch {
            throw ModelFactoryError.configurationFileError(
                configurationURL.lastPathComponent, configuration.name, error)
        }
        let baseConfig: BaseConfiguration
        do {
            baseConfig = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        } catch let error as DecodingError {
            throw ModelFactoryError.configurationDecodingError(
                configurationURL.lastPathComponent, configuration.name, error)
        }

        let model: LanguageModel
        do {
            model = try await typeRegistry.createModel(
                configuration: configData, modelType: baseConfig.modelType)
        } catch let error as DecodingError {
            throw ModelFactoryError.configurationDecodingError(
                configurationURL.lastPathComponent, configuration.name, error)
        }

        // Load EOS token IDs from config.json, with optional override from generation_config.json
        var eosTokenIds = Set(baseConfig.eosTokenIds?.values ?? [])
        let generationConfigURL = modelDirectory.appending(component: "generation_config.json")
        if let generationData = try? Data(contentsOf: generationConfigURL),
            let generationConfig = try? JSONDecoder.json5().decode(
                GenerationConfigFile.self, from: generationData),
            let genEosIds = generationConfig.eosTokenIds?.values
        {
            eosTokenIds = Set(genEosIds)  // Override per Python mlx-lm behavior
        }

        var mutableConfiguration = configuration
        mutableConfiguration.eosTokenIds = eosTokenIds

        // Auto-detect tool call format from model type if not explicitly set
        if mutableConfiguration.toolCallFormat == nil {
            mutableConfiguration.toolCallFormat = ToolCallFormat.infer(from: baseConfig.modelType)
        }

        // Load tokenizer from model directory (or alternate tokenizer repo),
        // processor config, and weights in parallel using async let.
        // Note: loadProcessorConfig does synchronous I/O but is marked async to enable
        // parallel scheduling. This may briefly block a cooperative thread pool thread,
        // but the config file is small and model loading is not a high-concurrency path.
        async let tokenizerTask = tokenizerLoader.load(
            from: configuration.tokenizerDirectory)
        async let processorConfigTask = loadProcessorConfig(from: modelDirectory)

        try loadWeights(
            modelDirectory: modelDirectory, model: model,
            perLayerQuantization: baseConfig.perLayerQuantization)

        let tokenizer = try await tokenizerTask
        let processorConfigData: Data
        let baseProcessorConfig: BaseProcessorConfiguration
        do {
            (processorConfigData, baseProcessorConfig) = try await processorConfigTask
        } catch let error as ProcessorConfigError {
            if let decodingError = error.underlying as? DecodingError {
                throw ModelFactoryError.configurationDecodingError(
                    error.filename, configuration.name, decodingError)
            }
            throw ModelFactoryError.configurationFileError(
                error.filename, configuration.name, error.underlying)
        }

        // Override processor type based on model type for models that need special handling
        // Mistral3 models ship with "PixtralProcessor" in their config but need Mistral3Processor
        // to handle spatial merging correctly
        let processorTypeOverrides: [String: String] = [
            "mistral3": "Mistral3Processor"
        ]
        let processorType =
            processorTypeOverrides[baseConfig.modelType] ?? baseProcessorConfig.processorClass

        let processor = try await processorRegistry.createModel(
            configuration: processorConfigData,
            processorType: processorType, tokenizer: tokenizer)

        // Build a ModelConfiguration for the ModelContext
        let tokenizerSource: TokenizerSource? =
            configuration.tokenizerDirectory == modelDirectory
            ? nil
            : .directory(configuration.tokenizerDirectory)
        let modelConfig = ModelConfiguration(
            directory: modelDirectory,
            tokenizerSource: tokenizerSource,
            defaultPrompt: configuration.defaultPrompt,
            extraEOSTokens: mutableConfiguration.extraEOSTokens,
            eosTokenIds: mutableConfiguration.eosTokenIds,
            toolCallFormat: mutableConfiguration.toolCallFormat)

        return .init(
            configuration: modelConfig, model: model, processor: processor,
            tokenizer: tokenizer)
    }

}

/// Error wrapper that includes the filename for better error messages.
private struct ProcessorConfigError: Error {
    let filename: String
    let underlying: Error
}

/// Loads processor configuration, preferring preprocessor_config.json over processor_config.json.
/// Marked async to enable parallel scheduling via async let, though the underlying I/O is synchronous.
/// Throws ProcessorConfigError wrapping any underlying error with the filename.
private func loadProcessorConfig(from modelDirectory: URL) async throws -> (
    Data, BaseProcessorConfiguration
) {
    let processorConfigURL = modelDirectory.appending(component: "processor_config.json")
    let preprocessorConfigURL = modelDirectory.appending(component: "preprocessor_config.json")
    let url =
        FileManager.default.fileExists(atPath: preprocessorConfigURL.path)
        ? preprocessorConfigURL
        : processorConfigURL
    do {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder.json5().decode(BaseProcessorConfiguration.self, from: data)
        return (data, config)
    } catch {
        throw ProcessorConfigError(filename: url.lastPathComponent, underlying: error)
    }
}

public class TrampolineModelFactory: NSObject, ModelFactoryTrampoline {
    public static func modelFactory() -> (any MLXLMCommon.ModelFactory)? {
        VLMModelFactory.shared
    }
}
