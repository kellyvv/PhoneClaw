import Foundation

// MARK: - Model Catalog Protocol
//
// UI 和配置页用的模型目录。不负责推理，只负责：
//   - 列出可用模型
//   - 当前选择 / 当前已加载
//   - 能力查询
//   - 运行时策略查询

public protocol ModelCatalog: AnyObject {

    /// 所有可用模型
    var availableModels: [ModelDescriptor] { get }

    /// 当前选中的模型 (不一定已加载)
    var selectedModel: ModelDescriptor { get }

    /// 当前已加载的模型 (nil = 没有加载任何模型)
    var loadedModel: ModelDescriptor? { get }

    /// 切换选中的模型。返回 true = 新模型存在且已切换。
    @discardableResult
    func select(modelID: String) -> Bool

    /// 查询指定模型的能力
    func capabilities(for modelID: String) -> ModelCapabilities

    /// 查询指定模型的运行时策略
    func runtimePolicy(for modelID: String) -> RuntimePolicy

    /// 后端加载成功后调用，同步 loadedModel 状态
    func markLoaded(_ model: ModelDescriptor)

    /// 后端卸载后调用，清除 loadedModel 状态
    func markUnloaded()

    /// 注入远程模型 (来自已绑定 Mac);默认 no-op (本地-only catalog 不实现)。
    func setRemoteModels(_ models: [ModelDescriptor])
}

// MARK: - Convenience

public extension ModelCatalog {
    func setRemoteModels(_ models: [ModelDescriptor]) { /* 默认 no-op */ }

    /// 当前选中模型的能力
    var selectedCapabilities: ModelCapabilities {
        capabilities(for: selectedModel.id)
    }

    /// 当前已加载模型的显示名称
    var loadedModelDisplayName: String? {
        loadedModel?.displayName
    }

    /// 显示名称 (已加载 > 选中)
    var modelDisplayName: String {
        loadedModel?.displayName ?? selectedModel.displayName
    }
}
