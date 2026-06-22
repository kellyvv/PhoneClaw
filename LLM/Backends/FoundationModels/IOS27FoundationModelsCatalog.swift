import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationModelsCatalog {
    static let systemModelID = "foundation::system-language-model"

    static var availableModels: [ModelDescriptor] {
        guard HotfixFeatureFlags.enableFoundationModelsInferenceService else {
            return []
        }

        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            return FoundationModelsRuntimeCatalog.availableModels
        }
        #endif

        return []
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
private enum FoundationModelsRuntimeCatalog {
    static var availableModels: [ModelDescriptor] {
        guard case .available = SystemLanguageModel.default.availability else {
            return []
        }

        return [
            ModelDescriptor(
                id: FoundationModelsCatalog.systemModelID,
                displayName: "Apple Foundation Models",
                family: .gemma4,
                artifactKind: .foundationModels,
                downloadURLs: [],
                fileName: "",
                expectedFileSize: 0,
                capabilities: ModelCapabilities(
                    supportsVision: false,
                    supportsAudio: false,
                    supportsLive: true,
                    supportsStructuredPlanning: true,
                    supportsThinking: false,
                    supportsPersistentSession: true,
                    supportsSessionSnapshot: false,
                    safeContextBudgetTokens: 4096,
                    defaultReservedOutputTokens: 700
                ),
                runtimeProfile: MLXModelProfiles.gemma4_e2b
            )
        ]
    }
}
#endif
