import Foundation
import os

// MARK: - ModelRuntimeCoordinator
//
// 组合编排 InstallState + RuntimeSessionState + GenerationTransaction。
// 不是全局大状态机，而是三条独立状态流的协调者。
//
// 设计约束:
//   - 不直接持有任何推理框架类型（只持有 InferenceService 协议引用）
//   - 所有状态变更通过显式方法，带 guard 前置条件
//   - @Observable 让 SwiftUI 可以直接绑定 sessionState
//   - 线程安全：所有状态变更在 @MainActor 上
//
// 迁移策略:
//   Phase 3a: 创建 Coordinator，AgentEngine 持有它但不用它          ✅
//   Phase 3b: AgentEngine.reloadModel() 开始委托给 Coordinator       ✅
//   Phase 3c: UI 层从 inference.isLoaded 迁移到 coordinator.sessionState ✅
//   Phase 4:  GenerationTransaction 接入生成流 + 取消安全             ✅
//
// 与 AgentEngine 的关系:
//   AgentEngine 当前是 God Class (2051行)。Coordinator 从中抽出:
//   - 模型 load/unload 编排
//   - 后端切换逻辑
//   - 生成事务管理
//   AgentEngine 保留: 路由、Prompt 构建、工具调用、UI 消息管理

@Observable
@MainActor
public final class ModelRuntimeCoordinator {

    // MARK: - Three State Lines

    /// Per-model 安装状态 (managed by external ModelInstaller, observed here)
    public private(set) var installStates: [String: InstallState] = [:]

    /// Active session 运行时状态
    public private(set) var sessionState: RuntimeSessionState = .idle

    /// 当前生成事务 (nil = 无活跃生成)
    public private(set) var currentTransaction: GenerationTransaction?

    // MARK: - Dependencies

    /// 底层推理服务
    private let inference: InferenceService

    /// 模型安装管理器 (用于查询安装状态)
    private let installer: ModelInstaller

    /// 最后一次成功 load/switch 使用的 backend。
    /// 用于 generating → ready 和 cancel → ready 回退时恢复 backend 信息。
    private var lastKnownBackend: String = "cpu"

    private let log = Logger(subsystem: "PhoneClaw", category: "Coordinator")

    // MARK: - Init

    /// Nonisolated so AgentEngine (not @MainActor) can create this in its init.
    /// Only stores references — no MainActor-bound work happens here.
    nonisolated public init(inference: InferenceService, installer: ModelInstaller) {
        self.inference = inference
        self.installer = installer
    }

    // MARK: - Load Model

    /// 加载模型。
    ///
    /// 前置条件:
    ///   - 模型已安装 (installer.installState == .downloaded/.bundled)
    ///   - sessionState 为 idle 或 ready（ready 时先 unload）
    ///
    /// 状态流: idle → loading → ready | failed
    public func load(modelID: String, backend: String) async throws {
        // Guard: LiteRT bootstrap 必须已完成
        if !LiteRTBootstrap.isBootstrapped {
            log.fault("load() called before LiteRTBootstrap.bootstrap()! GPU may not work.")
            assertionFailure("LiteRTBootstrap.bootstrap() must be called in @main init() before any load()")
        }

        // Guard: 模型必须已安装
        let state = installer.installState(for: modelID)
        guard state == .downloaded || state == .bundled else {
            log.error("load(\(modelID, privacy: .public)) rejected: not installed (state=\(String(describing: state), privacy: .public))")
            throw CoordinatorError.modelNotInstalled(modelID)
        }

        // Guard: 如果有 active session，先 unload
        if case .ready = sessionState {
            await unload()
        } else if case .generating = sessionState {
            await cancelCurrentGeneration()
            await unload()
        }

        guard sessionState == .idle || sessionState.isStable else {
            log.error("load(\(modelID, privacy: .public)) rejected: sessionState=\(String(describing: self.sessionState), privacy: .public)")
            throw CoordinatorError.invalidStateTransition("Cannot load from \(sessionState)")
        }

        // Transition: idle → loading
        transition(to: .loading(modelID: modelID, phase: .loadingWeights))
        log.info("load(\(modelID, privacy: .public), backend=\(backend, privacy: .public)) started")

        do {
            inference.setPreferredBackend(backend)
            try await inference.load(modelID: modelID)

            // Transition: loading → ready
            lastKnownBackend = backend
            transition(to: .ready(modelID: modelID, backend: backend))
            log.info("load(\(modelID, privacy: .public)) → ready")
        } catch {
            // Transition: loading → failed
            let runtimeError = RuntimeError.from(error, backend: backend)
            transition(to: .failed(runtimeError))
            log.error("load(\(modelID, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Switch Backend

    /// 切换后端 (CPU↔GPU)。
    ///
    /// 前置条件: sessionState == .ready
    /// 状态流: ready → switching → loading → ready | failed
    public func switchBackend(to newBackend: String) async throws {
        guard case .ready(let modelID, let currentBackend) = sessionState else {
            throw CoordinatorError.invalidStateTransition("switchBackend requires .ready state")
        }
        guard newBackend != currentBackend else {
            log.info("switchBackend: already on \(newBackend, privacy: .public), no-op")
            return
        }

        // Transition: ready → switching
        transition(to: .switching(
            from: BackendSwitch(modelID: modelID, backend: currentBackend),
            to: BackendSwitch(modelID: modelID, backend: newBackend)
        ))
        log.info("switchBackend(\(currentBackend, privacy: .public) → \(newBackend, privacy: .public))")

        // Synchronous teardown of old engine — must complete before new engine creation
        await inference.unloadAsync()

        // Transition: switching → loading
        transition(to: .loading(modelID: modelID, phase: .loadingWeights))

        do {
            inference.setPreferredBackend(newBackend)
            try await inference.load(modelID: modelID)
            lastKnownBackend = newBackend
            transition(to: .ready(modelID: modelID, backend: newBackend))
            log.info("switchBackend → ready on \(newBackend, privacy: .public)")
        } catch {
            // Switch failed — offer recovery to original backend
            let runtimeError = RuntimeError(
                message: "\(newBackend.uppercased()) engine creation failed",
                category: .engineCreationFailed,
                recoveryOptions: [.switchBackend(currentBackend), .retry]
            )
            transition(to: .failed(runtimeError))
            log.error("switchBackend failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Begin Generation

    /// 创建一个新的生成事务。
    ///
    /// 前置条件: sessionState == .ready, 无活跃 transaction
    /// 状态流: ready → generating
    ///
    /// 返回 transaction 对象，调用方负责:
    ///   1. 调 txn.begin() 当 stream 开始产出
    ///   2. 调 txn.commit() 当 stream 正常结束
    ///   3. 或调 txn.cancel() + await txn.termination 当需要取消
    public func beginGeneration() -> GenerationTransaction {
        guard case .ready(let modelID, _) = sessionState else {
            fatalError("beginGeneration() called in wrong state: \(sessionState)")
        }
        precondition(
            currentTransaction == nil || currentTransaction!.isTerminal,
            "Previous transaction \(currentTransaction?.id.uuidString ?? "?") still active"
        )

        let txn = GenerationTransaction(modelID: modelID)
        currentTransaction = txn
        transition(to: .generating(modelID: modelID, txnID: txn.id))
        log.info("beginGeneration txn=\(txn.id.uuidString.prefix(8), privacy: .public)")
        return txn
    }

    /// 当前 transaction 完成后，回到 ready。
    ///
    /// 调用方在 stream 结束后调用此方法。内部会检查 transaction 是否已 terminal。
    public func completeGeneration() {
        guard let txn = currentTransaction, txn.isTerminal else {
            log.warning("completeGeneration() called but transaction not terminal")
            return
        }
        guard case .generating(let modelID, _) = sessionState else {
            log.warning("completeGeneration() called in wrong state: \(String(describing: self.sessionState), privacy: .public)")
            return
        }

        transition(to: .ready(modelID: modelID, backend: lastKnownBackend))
        log.info("completeGeneration → ready")
    }

    // MARK: - Cancel Generation

    /// 取消当前生成。等待底层 stream 真正终止后才允许 reset KV。
    ///
    /// 安全保证: await 返回时，底层 stream 已完全停止，可以安全 reset KV session。
    ///
    /// 调用方式 (Phase 4):
    ///   AgentEngine.cancelActiveGeneration() 先同步调 txn.cancel() + inference.cancel()
    ///   以保证 UI 即时响应，然后 Task 调此方法做异步清理。因此此方法需要处理:
    ///   - txn 已经是 .cancelling (AgentEngine 预先设置)
    ///   - txn 已经是 terminal (onComplete 中 finishTurn() 先于本方法执行)
    public func cancelCurrentGeneration() async {
        guard let txn = currentTransaction else { return }

        if txn.isTerminal {
            // onComplete → finishTurn() 已经 terminated 了 txn.
            // 仍然 reset KV 以确保安全 — stream 此时必定已停止.
            await inference.resetKVSession()
        } else {
            // Snapshot: 是否有活跃 stream 需要等待?
            // .streaming = begin() 已调用，stream 活跃中
            // .cancelling = AgentEngine 已调 txn.cancel()，stream 可能还在跑
            let needsStreamWait = (txn.state == .streaming || txn.state == .cancelling)

            if txn.state != .cancelling {
                txn.cancel()
            }

            if needsStreamWait {
                inference.cancel()

                // 关键：等待 stream 真正终止
                // onComplete → finishTurn() 会 markTerminated(), 解除此 await
                await txn.termination

                // stream 已终止，reset KV
                await inference.resetKVSession()
            } else {
                // Was .created — stream never started, mark terminated directly.
                txn.markTerminated(reason: .userCancelled)
            }
        }

        if case .generating(let modelID, _) = sessionState {
            transition(to: .ready(modelID: modelID, backend: lastKnownBackend))
        }
        log.info("cancelCurrentGeneration complete")
    }

    // MARK: - Unload

    /// 卸载当前模型。
    ///
    /// 状态流: ready → unloading → idle
    public func unload() async {
        switch sessionState {
        case .idle:
            return // nothing to unload
        case .generating:
            await cancelCurrentGeneration()
        default:
            break
        }

        if let modelID = sessionState.activeModelID {
            transition(to: .unloading(modelID: modelID))
        }

        await inference.unloadAsync()
        transition(to: .idle)
        log.info("unload → idle")
    }

    // MARK: - Recovery

    /// 从 failed 状态恢复。
    public func recover(option: RuntimeError.RecoveryOption) async throws {
        guard case .failed(let error) = sessionState else {
            throw CoordinatorError.invalidStateTransition("recover requires .failed state")
        }

        switch option {
        case .retry:
            // 回到 idle，让调用方重新 load
            transition(to: .idle)

        case .switchBackend(let backend):
            transition(to: .idle)
            // 调用方需要重新 load with new backend
            log.info("recover: will switch to \(backend, privacy: .public)")

        case .redownloadModel:
            transition(to: .idle)
            log.info("recover: user will redownload model")

        case .reduceKVCache:
            transition(to: .idle)
            log.info("recover: user will reduce KV cache")
        }

        _ = error // suppress unused warning
    }

    // MARK: - Install State Sync

    /// 从 ModelInstaller 同步安装状态快照。
    /// 调用时机: app 启动、下载完成、磁盘扫描后。
    public func syncInstallStates() {
        var newStates: [String: InstallState] = [:]
        for model in ModelDescriptor.allModels {
            let legacy = installer.installState(for: model.id)
            newStates[model.id] = InstallState.from(legacy: legacy)
        }
        installStates = newStates
    }

    // MARK: - Private

    private func transition(to newState: RuntimeSessionState) {
        if let error = RuntimeSessionTransition.validate(from: sessionState, to: newState) {
            log.fault("Invalid state transition: \(String(describing: self.sessionState), privacy: .public) → \(String(describing: newState), privacy: .public): \(error, privacy: .public)")
            assertionFailure(error)
            // In release, force the transition anyway to avoid deadlocking
        }
        sessionState = newState
    }

}

// MARK: - CoordinatorError

public enum CoordinatorError: LocalizedError {
    case modelNotInstalled(String)
    case invalidStateTransition(String)
    case transactionStillActive

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let id):
            return "Model '\(id)' is not installed"
        case .invalidStateTransition(let detail):
            return "Invalid state transition: \(detail)"
        case .transactionStillActive:
            return "Previous generation transaction is still active"
        }
    }
}

// MARK: - RuntimeError Factory

public extension RuntimeError {
    /// Create a RuntimeError from a raw Error, inferring category and recovery options.
    static func from(_ error: Error, backend: String = "cpu") -> RuntimeError {
        let message = error.localizedDescription

        // Classify the error
        if message.contains("engine_create returned NULL") || message.contains("engine init failed") {
            return RuntimeError(
                message: message,
                category: .engineCreationFailed,
                recoveryOptions: backend == "gpu"
                    ? [.switchBackend("cpu"), .retry]
                    : [.retry, .reduceKVCache]
            )
        }

        if message.contains("memory") || message.contains("jetsam") || message.contains("Metal") {
            return RuntimeError(
                message: message,
                category: .outOfMemory,
                recoveryOptions: [.switchBackend("cpu"), .reduceKVCache]
            )
        }

        if message.contains("corrupt") || message.contains("file size") {
            return RuntimeError(
                message: message,
                category: .modelFileCorrupt,
                recoveryOptions: [.redownloadModel]
            )
        }

        return RuntimeError(
            message: message,
            category: .other,
            recoveryOptions: [.retry]
        )
    }
}

// MARK: - InstallState Legacy Bridge

public extension InstallState {
    /// Convert from legacy ModelInstallState to new InstallState.
    static func from(legacy: ModelInstallState) -> InstallState {
        switch legacy {
        case .notInstalled:
            return .notInstalled
        case .checkingSource:
            return .downloading(progress: DownloadProgress(bytesReceived: 0, totalBytes: nil, currentFile: "checking"))
        case .downloading(_, _, let currentFile):
            return .downloading(progress: DownloadProgress(bytesReceived: 0, totalBytes: nil, currentFile: currentFile))
        case .downloaded:
            return .installed(info: InstalledModelInfo(fileSize: 0, source: .downloaded))
        case .bundled:
            return .installed(info: InstalledModelInfo(fileSize: 0, source: .bundled))
        case .failed(let reason):
            return .corrupt(reason: reason)
        }
    }
}
