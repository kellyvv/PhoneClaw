import Foundation

// MARK: - RuntimeSessionState
//
// Per-active-session 运行时状态。同一时刻只有一个 active model session。
// 与 InstallState 完全正交 — 模型 A 在 ready 时，模型 B 可以同时在 downloading。
//
// 设计约束:
//   - 所有状态转移必须通过 RuntimeSessionStateMachine 的 guard 方法
//   - 不允许直接赋值 state — 防止非法跳转
//   - generating 状态绑定 GenerationTransaction.id，确保一对一
//
// 与 InferenceService 的关系:
//   RuntimeSessionState 是上层 Coordinator 的编排状态。
//   InferenceService 内部的 isLoaded/isLoading/isGenerating 逐步退化为
//   底层实现细节，UI 层不再直接依赖。

/// 当前 active model 的运行时状态。
public enum RuntimeSessionState: Equatable, Sendable {
    /// 无模型加载
    case idle
    /// 加载中 — 包含加载阶段便于 UI 显示进度
    case loading(modelID: String, phase: LoadPhase)
    /// 可推理 — 引擎就绪，等待用户输入
    case ready(modelID: String, backend: String)
    /// 推理中 — 绑定 GenerationTransaction ID
    case generating(modelID: String, txnID: UUID)
    /// 切后端 — 内部状态：旧引擎销毁中，即将开始新加载
    case switching(from: BackendSwitch, to: BackendSwitch)
    /// 卸载中
    case unloading(modelID: String)
    /// 失败 — 带结构化恢复建议
    case failed(RuntimeError)
}

/// 模型加载阶段（loading 的子状态）
public enum LoadPhase: Equatable, Sendable {
    /// GPU accelerator 确认（正常应该已在 bootstrap 完成，此处为诊断用）
    case preparingAccelerator
    /// 加载模型权重到内存 / Metal buffer
    case loadingWeights
    /// 打开 KV session
    case openingSession
}

/// 后端切换描述
public struct BackendSwitch: Equatable, Sendable {
    public let modelID: String
    public let backend: String

    public init(modelID: String, backend: String) {
        self.modelID = modelID
        self.backend = backend
    }
}

// MARK: - RuntimeSessionState Queries

public extension RuntimeSessionState {

    /// 当前活跃的 modelID（如果有）
    var activeModelID: String? {
        switch self {
        case .idle: return nil
        case .loading(let id, _): return id
        case .ready(let id, _): return id
        case .generating(let id, _): return id
        case .switching(_, let to): return to.modelID
        case .unloading(let id): return id
        case .failed: return nil
        }
    }

    /// 当前使用的 backend（仅 ready/generating 有值）
    var activeBackend: String? {
        switch self {
        case .ready(_, let b): return b
        case .generating: return nil  // 从 ready 进入，backend 信息在 coordinator 层
        default: return nil
        }
    }

    /// 是否处于稳定态（可以安全发起新操作）
    var isStable: Bool {
        switch self {
        case .idle, .ready, .failed: return true
        default: return false
        }
    }

    /// 是否可以接受新的生成请求
    var canGenerate: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 是否正在生成
    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    /// 是否正在加载
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - RuntimeSessionState Transition Validation

/// 状态转移验证器。集中管理合法的状态跳转，防止非法转移。
public enum RuntimeSessionTransition {

    /// 验证从 `from` 到 `to` 的转移是否合法。
    /// 返回 nil 表示合法，否则返回错误描述。
    public static func validate(from: RuntimeSessionState, to: RuntimeSessionState) -> String? {
        switch (from, to) {
        // idle → loading (开始加载)
        case (.idle, .loading):
            return nil

        // loading → ready (加载成功)
        case (.loading, .ready):
            return nil

        // loading → failed (加载失败)
        case (.loading, .failed):
            return nil

        // ready → generating (开始生成)
        case (.ready, .generating):
            return nil

        // ready → switching (切后端)
        case (.ready, .switching):
            return nil

        // ready → unloading (主动卸载或切模型)
        case (.ready, .unloading):
            return nil

        // generating → ready (生成完成/终止)
        case (.generating, .ready):
            return nil

        // generating → failed (生成过程中 OOM 等)
        case (.generating, .failed):
            return nil

        // switching → loading (旧引擎销毁完成，开始新加载)
        case (.switching, .loading):
            return nil

        // switching → failed (切换过程中失败)
        case (.switching, .failed):
            return nil

        // unloading → idle (卸载完成)
        case (.unloading, .idle):
            return nil

        // failed → idle (放弃恢复 / recover 重置)
        case (.failed, .idle):
            return nil

        // failed → loading (重试加载)
        case (.failed, .loading):
            return nil

        // failed → unloading (先卸载再恢复，如切模型场景)
        case (.failed, .unloading):
            return nil

        default:
            return "Invalid transition: \(from) → \(to)"
        }
    }
}

// MARK: - RuntimeError

/// 结构化运行时错误 — 包含恢复建议，UI 可据此显示不同操作按钮。
public struct RuntimeError: Equatable, Sendable {
    public let message: String
    public let category: ErrorCategory
    public let recoveryOptions: [RecoveryOption]

    public init(message: String, category: ErrorCategory, recoveryOptions: [RecoveryOption] = []) {
        self.message = message
        self.category = category
        self.recoveryOptions = recoveryOptions
    }

    public enum ErrorCategory: Equatable, Sendable {
        /// litert_lm_engine_create 返回 NULL
        case engineCreationFailed
        /// jetsam 风险 / Metal 内存不足
        case outOfMemory
        /// 模型文件损坏 (size < 90% expected)
        case modelFileCorrupt
        /// GPU 后端不可用 (registry sealed without GPU / Metal shader 编译失败)
        case backendNotAvailable
        /// 其他未分类错误
        case other
    }

    public enum RecoveryOption: Equatable, Sendable {
        /// 原参数重试
        case retry
        /// 切换到指定后端
        case switchBackend(String)
        /// 重新下载模型
        case redownloadModel
        /// 降低 KV cache 大小
        case reduceKVCache
    }
}
