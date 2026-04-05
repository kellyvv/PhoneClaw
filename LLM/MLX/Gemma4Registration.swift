import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

// MARK: - Gemma 4 Model Registration

/// Register the "gemma4" model type with both the text and VLM registries.
///
/// Call this once at app startup before loading models:
/// ```swift
/// await Gemma4Registration.register()
/// ```
public enum Gemma4Registration {

    public static func register() async {
        await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let configuration = try JSONDecoder.json5().decode(
                Gemma4ModelConfiguration.self, from: data)
            return Gemma4Model(configuration)
        }

        await VLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let configuration = try JSONDecoder.json5().decode(
                Gemma4ModelConfiguration.self, from: data)
            return Gemma4Model(configuration)
        }

        await VLMProcessorTypeRegistry.shared.registerProcessorType("Gemma4Processor") { data, tokenizer in
            let configuration = try JSONDecoder.json5().decode(
                Gemma4ProcessorConfiguration.self,
                from: data
            )
            return Gemma4Processor(configuration, tokenizer: tokenizer)
        }
    }
}
