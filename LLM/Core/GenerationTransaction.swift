import Foundation
import os

// MARK: - GenerationTransaction
//
// 单次生成的完整生命周期管理。解决取消安全和 KV 状态一致性问题。
//
// 核心约束:
//   - cancel 不是瞬时操作 — 必须等底层 stream 真正终止后才能 reset KV
//   - 一个 transaction 必须走到 terminal state 后才能创建下一个
//   - RuntimeSessionState 只在 transaction 到达 terminal state 后才回到 ready
//
// 取消流程（安全版）:
//   1. 用户按取消
//   2. coordinator.cancelCurrentGeneration()
//   3.   → transaction.cancel()              // state = .cancelling
//   4.   → inference.cancel()                // 设底层 cancelled flag
//   5.   → await transaction.termination     // ← 关键：等底层 stream 真正结束
//   6.   → transaction.markTerminated()      // state = .terminated
//   7.   → resetKVSession()                  // ← 现在安全了，stream 已终止
//   8.   → runtimeState = .ready
//
// 对比旧方案:
//   旧方案 cancel → resetKVSession → ready，中间没有 await stream termination。
//   如果 LiteRT C 层还在写 KV cache 就 reset，下一轮 KV 会脏。

/// 单次推理生成事务。管理从 stream 开始到结束的完整生命周期。
public final class GenerationTransaction: @unchecked Sendable {

    // MARK: - State

    /// 事务状态
    public enum State: Equatable, Sendable {
        /// 刚创建，尚未开始 stream
        case created
        /// stream 活跃中，正在接收 token
        case streaming
        /// 正常完成 — terminal state
        case committed
        /// 已请求取消，等待底层 stream 终止
        case cancelling
        /// 取消/错误后 stream 已终止 — terminal state
        case terminated(reason: TerminationReason)
    }

    /// 终止原因
    public enum TerminationReason: Equatable, Sendable {
        /// 用户主动取消
        case userCancelled
        /// 推理错误
        case error(String)
        /// 内存不足紧急终止
        case memoryPressure
    }

    // MARK: - Properties

    /// 事务唯一 ID
    public let id: UUID

    /// 关联的模型 ID
    public let modelID: String

    /// 事务创建时间
    public let createdAt: Date

    /// 当前状态 — 通过 unfair lock 保护并发访问
    public var state: State {
        stateLock.withLock { $0 }
    }

    /// Whether `begin()` was successfully called (stream was started).
    ///
    /// Used by `ModelRuntimeCoordinator.cancelCurrentGeneration()` to distinguish
    /// "cancelled before stream started" (no one will call markTerminated, so
    /// coordinator must do it directly) from "cancelled during active stream"
    /// (onComplete → finishTurn() will call markTerminated, so coordinator
    /// should await termination).
    ///
    /// Once cancel() changes state to .cancelling, the original pre-cancel
    /// state (.created vs .streaming) is lost. This flag preserves that info.
    public private(set) var didBeginStreaming: Bool = false

    // MARK: - Private

    /// Lock protecting the mutable state.
    /// `OSAllocatedUnfairLock(initialState:)` closure receives `inout State`.
    private let stateLock = OSAllocatedUnfairLock(initialState: State.created)

    /// Tagged waiter: pairs a unique ID with a continuation so we can
    /// remove exactly our own entry during the post-registration double-check.
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Monotonic counter for waiter IDs.
    private let nextWaiterID = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Continuations waiting for terminal state.
    private let contLock = OSAllocatedUnfairLock(initialState: [Waiter]())

    private let log = Logger(subsystem: "PhoneClaw", category: "GenTxn")

    // MARK: - Init

    public init(modelID: String) {
        self.id = UUID()
        self.modelID = modelID
        self.createdAt = .now
        log.info("[\(self.id.uuidString.prefix(8), privacy: .public)] created for model=\(modelID, privacy: .public)")
    }

    // MARK: - Lifecycle Transitions

    /// created → streaming. Call when the inference stream starts producing tokens.
    public func begin() {
        let ok = stateLock.withLock { (s: inout State) -> Bool in
            guard s == .created else { return false }
            s = .streaming
            return true
        }
        if ok {
            didBeginStreaming = true
            log.info("[\(self.id.uuidString.prefix(8), privacy: .public)] streaming started")
        } else {
            log.warning("[\(self.id.uuidString.prefix(8), privacy: .public)] begin() in wrong state: \(String(describing: self.state), privacy: .public)")
        }
    }

    /// streaming → committed. Call when the full response has been received.
    public func commit() {
        let ok = stateLock.withLock { (s: inout State) -> Bool in
            guard s == .streaming else { return false }
            s = .committed
            return true
        }
        if ok {
            log.info("[\(self.id.uuidString.prefix(8), privacy: .public)] committed")
            resumeAllWaiters()
        } else {
            log.warning("[\(self.id.uuidString.prefix(8), privacy: .public)] commit() in wrong state: \(String(describing: self.state), privacy: .public)")
        }
    }

    /// created|streaming → cancelling. Call when cancel is requested.
    /// After this, the caller MUST await `termination` before touching KV state.
    ///
    /// Accepts `.created` too — if cancel arrives before the stream starts,
    /// we still need a path to terminal (via `markTerminated`). Without this,
    /// `await termination` would deadlock on a `.created` transaction.
    public func cancel() {
        let ok = stateLock.withLock { (s: inout State) -> Bool in
            guard s == .created || s == .streaming else { return false }
            s = .cancelling
            return true
        }
        if ok {
            log.info("[\(self.id.uuidString.prefix(8), privacy: .public)] cancelling — awaiting stream termination")
        } else {
            log.warning("[\(self.id.uuidString.prefix(8), privacy: .public)] cancel() in wrong state: \(String(describing: self.state), privacy: .public)")
        }
    }

    /// created|cancelling|streaming → terminated. Call when the underlying stream has ACTUALLY stopped.
    /// This is the signal that it's safe to reset KV / start a new generation.
    ///
    /// Accepts `.created` for the edge case where cancel arrives before any stream
    /// starts — the transaction was never streaming, so it can terminate directly.
    public func markTerminated(reason: TerminationReason = .userCancelled) {
        let ok = stateLock.withLock { (s: inout State) -> Bool in
            guard s == .created || s == .cancelling || s == .streaming else { return false }
            s = .terminated(reason: reason)
            return true
        }
        if ok {
            log.info("[\(self.id.uuidString.prefix(8), privacy: .public)] terminated reason=\(String(describing: reason), privacy: .public)")
            resumeAllWaiters()
        } else {
            log.warning("[\(self.id.uuidString.prefix(8), privacy: .public)] markTerminated() in wrong state: \(String(describing: self.state), privacy: .public)")
        }
    }

    // MARK: - Await Termination

    /// Await until the transaction reaches a terminal state (committed or terminated).
    ///
    /// This is the critical safety mechanism for cancel flows:
    /// ```swift
    /// transaction.cancel()
    /// inference.cancel()
    /// await transaction.termination   // blocks until stream actually stops
    /// resetKVSession()                // now safe
    /// ```
    public var termination: Void {
        get async {
            // Fast path: already terminal
            let alreadyDone = stateLock.withLock { (s: inout State) -> Bool in s.isTerminal }
            if alreadyDone { return }

            // Slow path: register continuation and suspend
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Check again under lock — might have transitioned while we were setting up
                let done = stateLock.withLock { (s: inout State) -> Bool in s.isTerminal }
                if done {
                    continuation.resume()
                    return
                }

                // Assign a unique ID so we can remove exactly our own entry later
                let myID = nextWaiterID.withLock { (id: inout UInt64) -> UInt64 in
                    id += 1
                    return id
                }
                contLock.withLock { (conts: inout [Waiter]) in
                    conts.append(Waiter(id: myID, continuation: continuation))
                }

                // Double-check after registration to avoid missed wakeup.
                // Between our append and this check, resumeAllWaiters() may have
                // already drained and resumed our continuation. Use the tagged ID
                // to remove exactly our entry — not someone else's.
                let doneFinal = stateLock.withLock { (s: inout State) -> Bool in s.isTerminal }
                if doneFinal {
                    let found = contLock.withLock { (conts: inout [Waiter]) -> Bool in
                        if let idx = conts.firstIndex(where: { $0.id == myID }) {
                            conts.remove(at: idx)
                            return true
                        }
                        return false
                    }
                    if found {
                        continuation.resume()
                    }
                    // If not found, resumeAllWaiters() already drained and resumed it
                }
            }
        }
    }

    // MARK: - Queries

    /// Whether the transaction has reached a terminal state.
    public var isTerminal: Bool {
        state.isTerminal
    }

    /// Elapsed time since creation.
    public var elapsed: TimeInterval {
        Date.now.timeIntervalSince(createdAt)
    }

    // MARK: - Private Helpers

    /// Resume all waiting continuations. Called after state becomes terminal.
    private func resumeAllWaiters() {
        let waiters = contLock.withLock { (conts: inout [Waiter]) -> [Waiter] in
            let copy = conts
            conts.removeAll()
            return copy
        }
        for w in waiters { w.continuation.resume() }
    }
}

// MARK: - State.isTerminal

public extension GenerationTransaction.State {
    var isTerminal: Bool {
        switch self {
        case .committed, .terminated: return true
        default: return false
        }
    }
}
