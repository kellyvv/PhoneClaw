// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXLMCommon

/// Creates a function that decodes configuration data and instantiates a model with the proper configuration
private func create<C: Codable, M>(
    _ configurationType: C.Type, _ modelInit: @escaping (C) -> M
) -> (Data) throws -> M {
    { data in
        let configuration = try JSONDecoder.json5().decode(C.self, from: data)
        return modelInit(configuration)
    }
}

/// Registry of model type, e.g 'gemma', to functions that can instantiate the model from configuration.
///
/// Typically called via ``LLMModelFactory/load(from:configuration:progressHandler:)``.
///
/// NOTE: Slimmed to Gemma family only for PhoneClaw. Upstream mlx-swift-lm registers ~50
/// model types (Llama, Phi, Qwen, Mistral, DeepSeek, ...). PhoneClaw ships Gemma 4 exclusively
/// via a custom implementation in `LLM/MLX/Gemma4/`, which registers itself into this shared
/// registry at runtime via `LLMTypeRegistry.shared.registerModelType("gemma4", ...)`.
/// Keeping the stock Gemma v1/v2/v3/v3n entries below as a safety net for cousin models that
/// Gemma 4's custom implementation might delegate to.
public enum LLMTypeRegistry {

    /// Shared instance with default model types.
    public static let shared: ModelTypeRegistry = .init(creators: [
        "gemma": create(GemmaConfiguration.self, GemmaModel.init),
        "gemma2": create(Gemma2Configuration.self, Gemma2Model.init),
        "gemma3": create(Gemma3TextConfiguration.self, Gemma3TextModel.init),
        "gemma3_text": create(Gemma3TextConfiguration.self, Gemma3TextModel.init),
        "gemma3n": create(Gemma3nTextConfiguration.self, Gemma3nTextModel.init),
    ])
}

/// Registry of models and any overrides that go with them, e.g. prompt augmentation.
/// If asked for an unknown configuration this will use the model/tokenizer as-is.
///
/// NOTE: Slimmed to Gemma family only for PhoneClaw. See the comment on LLMTypeRegistry
/// above — PhoneClaw registers its own Gemma 4 model type at runtime, and no other
/// upstream model configurations are referenced.
public class LLMRegistry: AbstractModelRegistry, @unchecked Sendable {

    /// Shared instance with default model configurations.
    public static let shared = LLMRegistry(modelConfigurations: all())

    static public let gemma2bQuantized = ModelConfiguration(
        id: "mlx-community/quantized-gemma-2b-it",
        defaultPrompt: "what is the difference between lettuce and cabbage?"
    )

    static public let gemma_2_9b_it_4bit = ModelConfiguration(
        id: "mlx-community/gemma-2-9b-it-4bit",
        defaultPrompt: "What is the difference between lettuce and cabbage?"
    )

    static public let gemma_2_2b_it_4bit = ModelConfiguration(
        id: "mlx-community/gemma-2-2b-it-4bit",
        defaultPrompt: "What is the difference between lettuce and cabbage?"
    )

    static public let gemma3_1B_qat_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3-1b-it-qat-4bit",
        defaultPrompt: "What is the difference between a fruit and a vegetable?",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3n_E4B_it_lm_bf16 = ModelConfiguration(
        id: "mlx-community/gemma-3n-E4B-it-lm-bf16",
        defaultPrompt: "What is the difference between a fruit and a vegetable?",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3n_E2B_it_lm_bf16 = ModelConfiguration(
        id: "mlx-community/gemma-3n-E2B-it-lm-bf16",
        defaultPrompt: "What is the difference between a fruit and a vegetable?",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3n_E4B_it_lm_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3n-E4B-it-lm-4bit",
        defaultPrompt: "What is the difference between a fruit and a vegetable?",
        extraEOSTokens: ["<end_of_turn>"]
    )

    static public let gemma3n_E2B_it_lm_4bit = ModelConfiguration(
        id: "mlx-community/gemma-3n-E2B-it-lm-4bit",
        defaultPrompt: "What is the difference between a fruit and a vegetable?",
        extraEOSTokens: ["<end_of_turn>"]
    )

    private static func all() -> [ModelConfiguration] {
        [
            gemma2bQuantized,
            gemma_2_2b_it_4bit,
            gemma_2_9b_it_4bit,
            gemma3_1B_qat_4bit,
            gemma3n_E4B_it_lm_bf16,
            gemma3n_E2B_it_lm_bf16,
            gemma3n_E4B_it_lm_4bit,
            gemma3n_E2B_it_lm_4bit,
        ]
    }

}

@available(*, deprecated, renamed: "LLMRegistry", message: "Please use LLMRegistry directly.")
public typealias ModelRegistry = LLMRegistry

private struct LLMUserInputProcessor: UserInputProcessor {

    let tokenizer: Tokenizer
    let configuration: ModelConfiguration
    let messageGenerator: MessageGenerator

    internal init(
        tokenizer: any Tokenizer, configuration: ModelConfiguration,
        messageGenerator: MessageGenerator
    ) {
        self.tokenizer = tokenizer
        self.configuration = configuration
        self.messageGenerator = messageGenerator
    }

    func prepare(input: UserInput) throws -> LMInput {
        let messages = messageGenerator.generate(from: input)
        do {
            let promptTokens = try tokenizer.applyChatTemplate(
                messages: messages, tools: input.tools, additionalContext: input.additionalContext)

            return LMInput(tokens: MLXArray(promptTokens))
        } catch TokenizerError.missingChatTemplate {
            print(
                "No chat template was included or provided, so converting messages to simple text format. This is not optimal for model performance, so applications should provide a chat template if none is included with the model."
            )
            let prompt =
                messages
                .compactMap { $0["content"] as? String }
                .joined(separator: "\n\n")
            let promptTokens = tokenizer.encode(text: prompt)
            return LMInput(tokens: MLXArray(promptTokens))
        }
    }
}

/// Factory for creating new LLMs.
///
/// Callers can use the `shared` instance or create a new instance if custom configuration
/// is required.
///
/// ```swift
/// let modelContainer = try await LLMModelFactory.shared.loadContainer(
///     configuration: LLMRegistry.llama3_8B_4bit)
/// ```
public final class LLMModelFactory: ModelFactory {

    public init(typeRegistry: ModelTypeRegistry, modelRegistry: AbstractModelRegistry) {
        self.typeRegistry = typeRegistry
        self.modelRegistry = modelRegistry
    }

    /// Shared instance with default behavior.
    public static let shared = LLMModelFactory(
        typeRegistry: LLMTypeRegistry.shared, modelRegistry: LLMRegistry.shared)

    /// registry of model type, e.g. configuration value `llama` -> configuration and init methods
    public let typeRegistry: ModelTypeRegistry

    /// registry of model id to configuration, e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`
    public let modelRegistry: AbstractModelRegistry

    public func _load(
        configuration: ResolvedModelConfiguration,
        tokenizerLoader: any TokenizerLoader
    ) async throws -> ModelContext {
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

        // Build a ModelConfiguration with loaded EOS token IDs and tool call format
        var mutableConfiguration = configuration
        mutableConfiguration.eosTokenIds = eosTokenIds
        if mutableConfiguration.toolCallFormat == nil {
            mutableConfiguration.toolCallFormat = ToolCallFormat.infer(from: baseConfig.modelType)
        }

        // Load tokenizer and weights in parallel
        async let tokenizerTask = tokenizerLoader.load(
            from: configuration.tokenizerDirectory)

        try loadWeights(
            modelDirectory: modelDirectory, model: model,
            perLayerQuantization: baseConfig.perLayerQuantization)

        let tokenizer = try await tokenizerTask

        let messageGenerator =
            if let model = model as? LLMModel {
                model.messageGenerator(tokenizer: tokenizer)
            } else {
                DefaultMessageGenerator()
            }

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

        let processor = LLMUserInputProcessor(
            tokenizer: tokenizer, configuration: modelConfig,
            messageGenerator: messageGenerator)

        return .init(
            configuration: modelConfig, model: model, processor: processor,
            tokenizer: tokenizer)
    }

}

public class TrampolineModelFactory: NSObject, ModelFactoryTrampoline {
    public static func modelFactory() -> (any MLXLMCommon.ModelFactory)? {
        LLMModelFactory.shared
    }
}
