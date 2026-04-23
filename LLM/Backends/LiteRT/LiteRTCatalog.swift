import Foundation

// MARK: - LiteRT Model Catalog
//
// ModelCatalog conformer for LiteRT-LM models.
// 管理模型列表、当前选择、能力查询。

@Observable
final class LiteRTCatalog: ModelCatalog {

    // MARK: - State

    private(set) var selectedModel: ModelDescriptor = .defaultModel
    private(set) var loadedModel: ModelDescriptor?

    let availableModels: [ModelDescriptor] = ModelDescriptor.allModels

    // MARK: - ModelCatalog

    @discardableResult
    func select(modelID: String) -> Bool {
        guard let model = availableModels.first(where: { $0.id == modelID }) else {
            return false
        }
        selectedModel = model
        return true
    }

    func capabilities(for modelID: String) -> ModelCapabilities {
        availableModels.first(where: { $0.id == modelID })?.capabilities
            ?? ModelCapabilities()
    }

    func runtimePolicy(for modelID: String) -> RuntimePolicy {
        let descriptor = availableModels.first(where: { $0.id == modelID }) ?? .defaultModel
        return RuntimePolicy(
            profile: descriptor.runtimeProfile,
            capabilities: descriptor.capabilities
        )
    }

    // MARK: - ModelCatalog: Load State

    func markLoaded(_ model: ModelDescriptor) {
        loadedModel = model
    }

    func markUnloaded() {
        loadedModel = nil
    }
}
