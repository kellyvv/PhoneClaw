# PhoneClaw 运行时架构收敛方案 v2

> 目标：不换框架，做一次运行时架构收敛。把散落在 AgentEngine / LiteRTBackend /
> BackendDispatcher / LiteRTModelStore 里的隐式状态流转，收敛成可预测、可测试、
> 可维护的模块化架构。
>
> v2 修订基于代码审阅反馈，核心修正：
> 1. 安装状态（per model）与运行时状态（per active session）分离
> 2. LiteRT Environment 初始化作为最高优先级硬约束
> 3. 引入 GenerationTransaction 管理 stream 生命周期和取消安全
> 4. InferenceService 协议需要演进（async unload、结构化错误）
> 5. IPA 验证脚本覆盖 framework 内嵌 dylib

---

## 一、现状诊断

### 1.1 当前模块职责边界

```
┌─────────────────────────────────────────────────────────┐
│  ContentView (UI)                                       │
│  @State engine = AgentEngine()                          │
│  直接读 engine.messages / engine.isProcessing / ...     │
└────────────────────────┬────────────────────────────────┘
                         │ 直接持有
┌────────────────────────▼────────────────────────────────┐
│  AgentEngine (2051 行 God Class)                        │
│  集成: 路由 / Prompt / 流式 / Session / 工具 / 配置     │
│  let inference: InferenceService (= BackendDispatcher)  │
│  let catalog: LiteRTCatalog                             │
│  let installer: LiteRTModelStore                        │
└────────┬──────────────────────────┬─────────────────────┘
         │                          │
┌────────▼────────┐    ┌────────────▼─────────────────────┐
│ BackendDispatcher│    │ LiteRTModelStore (ModelInstaller) │
│ active → LiteRT │    │ install / remove / progress       │
│        → MiniCPM│    │ ResumableAssetDownloader           │
└──┬──────────┬───┘    └──────────────────────────────────┘
   │          │
┌──▼───┐  ┌──▼──────────┐
│LiteRT│  │MiniCPMVBack.│
│994行 │  │1149行       │
└──────┘  └─────────────┘
```

### 1.2 核心问题

| 问题 | 根因 | 体现 |
|------|------|------|
| **状态散落** | `isLoaded` / `isLoading` / `isGenerating` 是独立 bool，不互斥 | 理论上可以 `isLoading && isGenerating` 同时为 true |
| **转移无约束** | 没有状态机，任何地方都能直接改 bool | GPU 切换时 unload 还没完成就 load |
| **安装与运行时混淆** | 安装状态（per model）和推理状态（per session）没有分离 | 一个模型在推理时另一个模型无法同时下载；GPU 加载失败 state 跟下载 state 互相干扰 |
| **职责耦合** | AgentEngine 既管推理又管 UI 状态又管会话又管工具 | 加新功能必须改 2051 行大文件 |
| **错误恢复不统一** | catch 块散落在各处，有的删文件有的不删，有的重试有的不重试 | GPU 加载失败曾误删完好的模型文件 |
| **取消不安全** | cancel 只设 flag，不等底层 stream 终止就 reset KV | 可能污染下一轮生成的 KV cache |
| **LiteRT Environment 时机隐患** | GPU accelerator 预加载时机不够硬，"或 ContentView.onAppear" 会晚于首次 engine_create | CPU→GPU 热切失败的根因 |

---

## 二、架构三条主线

### 设计原则

安装状态和运行时状态是两个正交维度：
- **InstallState** 是 per-model 的，多个模型可以同时处于不同安装阶段（E2B 在用、E4B 在下载、MiniCPM-V 已安装）
- **RuntimeSessionState** 是 per-active-session 的，同一时刻只有一个 active model 在推理
- **GenerationTransaction** 是 per-turn 的，管理单次生成的完整生命周期

```
主线 1: InstallState (per model)
  notInstalled → downloading → verifying → installed
                                         → corrupt

主线 2: RuntimeSessionState (per active session)
  idle → loading → ready → generating → ready
                        → switching → loading
                        → unloading → idle
                 → failed → (recovery)

主线 3: GenerationTransaction (per turn)
  created → streaming → committed
                      → cancelled → awaitingTermination → terminated
                      → failed
```

三条主线之间的关系：
- `ModelRuntimeCoordinator` **组合编排**这三条主线，但不是一个大状态机
- 只有 `installStates[modelID] == .installed` 的模型才能进入 RuntimeSessionState 的 `loading`
- 只有 RuntimeSessionState 为 `ready` 时才能创建 GenerationTransaction
- GenerationTransaction 完成/终止后 RuntimeSessionState 才回到 `ready`

---

## 三、目标架构

### 3.1 分层总览

```
┌──────────────────────────────────────────────────────────────┐
│  UI Layer (SwiftUI, 保持不变)                                 │
│  ContentView / ConfigurationsView / ...                      │
│  只依赖 ViewModel 层，不直接碰推理/安装                        │
└───────────────────────────┬──────────────────────────────────┘
                            │ @Observable
┌───────────────────────────▼──────────────────────────────────┐
│  ViewModel Layer                                              │
│  ┌─────────────┐  ┌───────────────┐  ┌──────────────────┐    │
│  │ChatViewModel │  │ConfigViewModel│  │LiveModeViewModel │    │
│  └──────┬──────┘  └───────┬───────┘  └────────┬─────────┘    │
└─────────┼─────────────────┼────────────────────┼─────────────┘
          │                 │                    │
┌─────────▼─────────────────▼────────────────────▼─────────────┐
│  Coordinator Layer                                            │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐    │
│  │  ModelRuntimeCoordinator                               │    │
│  │  组合编排 install + runtime + generation               │    │
│  │  不是全局大状态机，而是三条主线的协调者                   │    │
│  └──┬──────────────────┬──────────────────┬──────────────┘    │
│     │                  │                  │                    │
│  ┌──▼───────────┐  ┌───▼──────────┐  ┌───▼──────────────┐    │
│  │ModelInstall   │  │ChatSession   │  │AgentOrchestrator │    │
│  │Manager        │  │Controller    │  │路由/Prompt/工具  │    │
│  │per-model 状态 │  │消息/流式/历史│  │                  │    │
│  └──────────────┘  └──────────────┘  └──────────────────┘    │
│                                                               │
│  ┌──────────────────┐  ┌──────────────────────────────────┐   │
│  │DiagnosticsLogger │  │LiteRTBootstrap                   │   │
│  │结构化日志/诊断包 │  │进程启动期硬约束 (accelerator等) │   │
│  └──────────────────┘  └──────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────┘
          │
┌─────────▼────────────────────────────────────────────────────┐
│  Engine Layer (需要接口演进，内部实现基本不变)                  │
│  InferenceService (补 async unload / 结构化错误)              │
│  BackendDispatcher / LiteRTBackend / MiniCPMVBackend          │
│  PhoneClawEngine (C wrapper)                                  │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 各模块职责

---

#### `LiteRTBootstrap` — 进程启动期硬约束（新增，最高优先级）

```swift
/// LiteRT 运行时的进程级初始化。
///
/// 硬约束：LiteRT 的 internal Environment / accelerator registry 是进程级单例，
/// 在第一次 litert_lm_engine_create() 调用时被 sealed。GPU accelerator 必须
/// 在此之前注册完毕，否则后续任何 GPU engine 创建都会失败。
///
/// 这个模块必须在 App 的 main() / @main init / App.init() 里同步调用，
/// 早于任何可能触发 engine_create 的代码路径。不能放在 ContentView.onAppear
/// 或 Task 里 — 那些时机不够早、不够确定。
enum LiteRTBootstrap {

    /// 进程级一次性初始化。同步执行，阻塞调用线程直到完成。
    /// 幂等 — 多次调用安全（内部 dispatch_once）。
    ///
    /// 做的事：
    /// 1. dlopen LiteRtMetalAccelerator.framework 注册 GPU backend
    /// 2. 记录 bootstrap 完成时间戳（供诊断）
    /// 3. 设置 min log level
    ///
    /// 不做的事：
    /// - 不创建任何 engine（那是 RuntimeSessionState 的职责）
    /// - 不加载 TopK Metal Sampler（那要等 GPU engine 创建成功后）
    /// - 不做任何 async 操作
    private(set) static var isBootstrapped = false
    private(set) static var bootstrapTimestamp: CFAbsoluteTime = 0

    static func bootstrap() {
        guard !isBootstrapped else { return }
        // GPU accelerator preload — 必须在任何 engine_create 之前
        _ = _preloadGpuAcceleratorOnce
        bootstrapTimestamp = CFAbsoluteTimeGetCurrent()
        isBootstrapped = true
        DiagnosticsLogger.shared.event("litert_bootstrap_complete")
    }
}

// 调用点 — 必须是最早的同步初始化
@main
struct PhoneClawApp: App {
    init() {
        LiteRTBootstrap.bootstrap()  // ← 第一行，早于一切
        PCLog.suppressRuntimeNoise()
    }
    // ...
}
```

**为什么必须是 `@main init()` 而不是 "或 ContentView.onAppear"：**
- `@main init()` 在进程启动时同步执行，保证早于任何 SwiftUI body 求值
- `ContentView.onAppear` 的时机不确定（可能 body 已经求值触发了其他初始化）
- `Task {}` 是异步的，不保证在同步代码路径的 engine_create 之前完成
- 当前 CPU→GPU 热切失败的根因就是 accelerator 注册晚于首次 CPU engine 创建

---

#### `ModelInstallManager` — per-model 安装状态（从 LiteRTModelStore 演化）

```swift
/// per-model 安装状态管理。每个模型独立状态，互不干扰。
/// 用户可以一边用 E2B 聊天一边下载 E4B。
@Observable
final class ModelInstallManager {

    // ── per-model 安装状态 ──────────────────
    enum InstallState: Equatable {
        case notInstalled
        case downloading(progress: DownloadProgress)
        case verifying                      // 下载完做完整性检查
        case installed(fileSize: Int64)     // 带文件大小，方便 UI 显示
        case corrupt(reason: String)        // 文件损坏（区别于 notInstalled）
    }

    /// 每个模型的安装状态。key = modelID
    private(set) var states: [String: InstallState] = [:]

    // ── 安装状态转移 ────────────────────────
    //  notInstalled → downloading        (install 触发)
    //  downloading  → verifying          (下载完成)
    //  downloading  → notInstalled       (取消) | failed → notInstalled
    //  verifying    → installed          (校验通过)
    //  verifying    → corrupt            (校验失败)
    //  installed    → notInstalled       (remove)
    //  corrupt      → notInstalled       (remove)
    //  corrupt      → downloading        (重新下载)
    //
    //  注意：任何状态都可以 refreshStates() 刷新（磁盘扫描可能发现状态变化）

    func install(model: ModelDescriptor) async throws
    func verify(model: ModelDescriptor) async -> VerifyResult
    func remove(model: ModelDescriptor) throws
    func cancelDownload(modelID: String)
    func artifactPath(for model: ModelDescriptor) -> URL?
    func hasResumableDownload(for modelID: String) -> Bool

    /// 启动时调用 — 扫描磁盘，校验已安装模型完整性
    func refreshStates()
}
```

**与现有 LiteRTModelStore 的关系：** 演化而非重写。内部继续用
ResumableAssetDownloader / DownloadManifestStore / ZipExtractor。主要变化：
1. 补 `verifying` 和 `corrupt` 状态
2. 状态转移加 guard（不允许 `installed` 直接跳 `downloading`）
3. 加 SHA256 校验（如果 ModelDescriptor 提供 hash）
4. `states` 字典替代现在的 `installStates + resumableModelIDs` 两个散字段

---

#### `RuntimeSessionState` — per-active-session 运行时状态（新增）

```swift
/// 当前 active model 的运行时状态。同一时刻只有一个 active session。
/// 与 InstallState 完全正交 — 模型 A 在 ready 时，模型 B 可以同时在 downloading。
enum RuntimeSessionState: Equatable {
    case idle                                   // 无模型加载
    case loading(modelID: String, phase: LoadPhase)  // 加载中
    case ready(modelID: String, backend: String)     // 可推理
    case generating(modelID: String, txnID: UUID)    // 推理中（绑定 transaction）
    case switching(modelID: String, from: String, to: String)  // 切后端
    case unloading(modelID: String)             // 卸载中
    case failed(RuntimeError)                   // 失败（含恢复信息）
}

enum LoadPhase: Equatable {
    case preparingAccelerator    // GPU accelerator 确认（正常应该已在 bootstrap 完成）
    case loadingWeights          // 加载模型权重到内存
    case openingSession          // 打开 KV session
}

/// 结构化错误 — 包含恢复建议，UI 可据此显示不同操作
struct RuntimeError: Equatable {
    let message: String
    let category: ErrorCategory
    let recoveryOptions: [RecoveryOption]

    enum ErrorCategory: Equatable {
        case engineCreationFailed       // litert_lm_engine_create NULL
        case outOfMemory                // jetsam 风险
        case modelFileCorrupt           // 文件损坏
        case backendNotAvailable        // GPU 不可用
    }

    enum RecoveryOption: Equatable {
        case retry                      // 原参数重试
        case switchBackend(String)      // 换 CPU/GPU
        case redownloadModel            // 重新下载
        case reduceKVCache              // 降低 KV cache
    }
}

// ── 转移表 ──────────────────────────────
//  idle       → loading             (load)
//  loading    → ready | failed      (engine create 结果)
//  ready      → generating          (创建 GenerationTransaction)
//  ready      → switching           (switchBackend)
//  ready      → unloading           (unload / 切模型)
//  generating → ready               (transaction committed/terminated)
//  generating → failed              (生成过程中 OOM 等)
//  switching  → loading             (内部：旧引擎已销毁，开始新加载)
//  unloading  → idle                (卸载完成)
//  failed     → idle | loading      (recover: 恢复到稳定态)
```

---

#### `GenerationTransaction` — per-turn 生成事务（新增）

```swift
/// 单次生成的完整生命周期。解决取消安全和 KV 状态一致性问题。
///
/// 关键约束：
/// - cancel 不是瞬时操作 — 必须等底层 stream 真正终止后才能 reset KV
/// - 一个 transaction 必须走到 terminal state 后才能创建下一个
/// - RuntimeSessionState 只在 transaction 到达 terminal state 后才回到 ready
final class GenerationTransaction {
    let id: UUID
    let modelID: String

    enum State {
        case created                    // 刚创建，尚未开始 stream
        case streaming                  // stream 活跃中
        case committed(fullResponse: String)  // 正常完成 ← terminal
        case cancelling                 // 已请求取消，等待 stream 终止
        case terminated(partial: String?)     // 取消/错误后 stream 已终止 ← terminal
    }

    private(set) var state: State = .created

    // ── stream 生命周期 ─────────────────
    func begin(stream: AsyncThrowingStream<String, Error>)    // created → streaming
    func commit(fullResponse: String)                          // streaming → committed
    func cancel()                                              // streaming → cancelling
    func onStreamTerminated()                                  // cancelling → terminated
    func fail(error: Error)                                    // streaming → terminated

    // ── 完成信号 ─────────────────────────
    /// 等待 transaction 到达 terminal state。cancel 后必须 await 这个。
    var termination: AsyncStream<Void> { get }

    var isTerminal: Bool {
        switch state {
        case .committed, .terminated: return true
        default: return false
        }
    }
}
```

**取消流程（修正后）：**

```
用户按取消
  → coordinator.cancelCurrentGeneration()
    → transaction.cancel()                // state = .cancelling
    → inference.cancel()                  // 设 cancelled flag
    → await transaction.termination       // ← 关键：等底层 stream 真正结束
    → transaction.onStreamTerminated()    // state = .terminated
    → 清理 UI：移除 cursor、标记消息 "已中断"
    → resetKVSession()                    // ← 现在安全了，stream 已终止
    → runtimeState = .ready               // ← 干净的 ready
```

对比旧方案的问题：旧方案 `cancel → resetKVSession → ready`，中间没有
`await stream termination`，如果 LiteRT C 层还在写 KV cache 就 reset，
下一轮 KV 会脏。

---

#### `ModelRuntimeCoordinator` — 三条主线的组合编排

```swift
/// 组合编排 InstallState + RuntimeSessionState + GenerationTransaction。
/// 不是全局大状态机，而是三条独立状态流的协调者。
@Observable
final class ModelRuntimeCoordinator {

    // ── 三条主线 ────────────────────────────
    let installManager: ModelInstallManager          // per-model 安装状态
    private(set) var sessionState: RuntimeSessionState = .idle  // active session 运行时状态
    private(set) var currentTransaction: GenerationTransaction? // 当前生成事务

    // ── 依赖 ────────────────────────────────
    private let inference: InferenceService
    private let diagnostics: DiagnosticsLogger

    // ── 编排 API ────────────────────────────

    /// 加载模型。前置条件：installStates[modelID] == .installed
    func load(modelID: String, backend: String) async throws {
        guard installManager.states[modelID]?.isInstalled == true else {
            throw CoordinatorError.modelNotInstalled(modelID)
        }
        guard case .idle = sessionState else {
            // 如果有 active session，先 unload
            await unload()
        }

        sessionState = .loading(modelID: modelID, phase: .loadingWeights)
        do {
            inference.setPreferredBackend(backend)
            try await inference.load(modelID: modelID)
            sessionState = .ready(modelID: modelID, backend: backend)
        } catch {
            sessionState = .failed(RuntimeError.from(error, modelID: modelID))
        }
    }

    /// 切换后端。前置条件：sessionState == .ready
    func switchBackend(to newBackend: String) async throws {
        guard case .ready(let modelID, let currentBackend) = sessionState else {
            throw CoordinatorError.invalidStateTransition
        }
        guard newBackend != currentBackend else { return }

        sessionState = .switching(modelID: modelID, from: currentBackend, to: newBackend)

        // 同步销毁旧引擎（必须等完成才能创建新引擎）
        await inference.unloadAsync()   // ← 需要协议演进

        // 重新加载
        sessionState = .loading(modelID: modelID, phase: .loadingWeights)
        do {
            inference.setPreferredBackend(newBackend)
            try await inference.load(modelID: modelID)
            sessionState = .ready(modelID: modelID, backend: newBackend)
        } catch {
            // 切换失败 — 尝试恢复到原 backend
            sessionState = .failed(RuntimeError(
                message: "GPU 引擎创建失败",
                category: .engineCreationFailed,
                recoveryOptions: [.switchBackend(currentBackend), .retry]
            ))
        }
    }

    /// 开始生成。前置条件：sessionState == .ready，无活跃 transaction
    func beginGeneration(
        prompt: String
    ) -> (GenerationTransaction, AsyncThrowingStream<String, Error>) {
        guard case .ready(let modelID, _) = sessionState else {
            fatalError("beginGeneration called in wrong state: \(sessionState)")
        }
        precondition(currentTransaction == nil || currentTransaction!.isTerminal)

        let txn = GenerationTransaction(id: UUID(), modelID: modelID)
        currentTransaction = txn
        sessionState = .generating(modelID: modelID, txnID: txn.id)

        let stream = inference.generate(prompt: prompt)
        txn.begin(stream: stream)
        return (txn, stream)
    }

    /// 取消当前生成。等待底层 stream 终止后才 reset KV。
    func cancelCurrentGeneration() async {
        guard let txn = currentTransaction, !txn.isTerminal else { return }

        txn.cancel()
        inference.cancel()

        // 关键：等待 stream 真正终止
        for await _ in txn.termination { break }

        // stream 已终止，现在安全 reset KV
        await inference.resetKVSession()

        if case .generating(let modelID, _) = sessionState {
            sessionState = .ready(modelID: modelID, backend: activeBackend ?? "cpu")
        }
    }

    /// 卸载当前模型。
    func unload() async {
        guard case .ready(let modelID, _) = sessionState else { return }
        sessionState = .unloading(modelID: modelID)
        await inference.unloadAsync()
        sessionState = .idle
    }
}
```

---

#### `InferenceService` 协议演进

```swift
/// v2 变更点（向后兼容，通过默认实现）
public protocol InferenceService: AnyObject {

    // ── 现有，保持 ────────────────────────
    func load(modelID: String) async throws
    func cancel()
    func generate(prompt: String) -> AsyncThrowingStream<String, Error>
    // ... 其他现有方法 ...

    // ── 新增 ──────────────────────────────

    /// 异步卸载 — 等待底层资源释放完成后才返回。
    /// 替代现有的同步 unload()，解决 Coordinator 需要确保卸载完成后才 load 的问题。
    /// 现有同步 unload() 保留但标记 deprecated。
    func unloadAsync() async

    /// 当前后端能力查询 — Coordinator 判断状态转移用
    var activeCapabilities: ModelCapabilities? { get }

    /// 结构化加载错误 — 替代 catch 里解析 error message 字符串
    /// 后端 load 失败时 throw 这个类型，Coordinator 按 category 做恢复决策
    // (通过 RuntimeError.from(error) 转换，不改现有 throw 签名)
}

// 默认实现 — 不破坏现有后端
public extension InferenceService {
    func unloadAsync() async {
        // 默认：包装同步 unload
        unload()
    }
    var activeCapabilities: ModelCapabilities? { nil }
}
```

**为什么不能 "不动 InferenceService"：** Coordinator 要保证原子切换（unload 完成 →
load 开始），必须 await unload 完成。现有 `unload()` 是同步 void，里面调
`destroySynchronously()`，但从 Coordinator 视角看不到完成信号。`unloadAsync()`
给 Coordinator 一个明确的完成点。通过默认实现保持向后兼容，现有 MiniCPMVBackend
不需要立刻改。

---

#### `ChatSessionController` — 会话管理（从 AgentEngine 抽取）

```swift
/// 只管消息、流式、取消、历史裁剪。不知道模型是什么，不知道推理怎么跑。
@Observable
final class ChatSessionController {

    private(set) var messages: [ChatMessage] = []
    private(set) var isStreaming = false
    private(set) var streamingCursor: String?

    // ── 会话管理 ────────────────────────
    func newSession()
    func loadSession(id: String)
    func appendUserMessage(_ text: String, images: [UIImage]?)
    func appendAssistantPlaceholder() -> UUID

    // ── 流式控制（由 GenerationTransaction 驱动）──
    func startStreaming(messageID: UUID)
    func appendTokens(_ tokens: String, to messageID: UUID)
    func finishStreaming(messageID: UUID, fullResponse: String)

    /// 取消流式 — 只管 UI 侧清理（移除 cursor、标记中断）。
    /// KV reset 由 Coordinator 在确认 stream 终止后处理。
    func markStreamingCancelled(messageID: UUID)

    // ── 历史裁剪 ────────────────────────
    func trimHistory(to depth: Int)

    // ── 持久化 ──────────────────────────
    private let store: SessionStore
    func save()
}
```

---

#### `AgentOrchestrator` — Agent 编排（AgentEngine 核心逻辑抽取）

```swift
/// 路由、Prompt 构建、工具执行。是 AgentEngine 的"大脑"部分。
/// 不持有 UI 状态，不管消息列表，不管推理生命周期。
final class AgentOrchestrator {

    private let router: Router
    private let planner: Planner
    private let toolChain: ToolChain
    private let promptBuilder: PromptBuilder

    func plan(
        input: String,
        history: [ChatMessage],
        capabilities: ModelCapabilities,
        budgetTokens: Int
    ) -> PromptPlan

    func executeToolCalls(in response: String) async -> [CanonicalToolResult]
    func needsFollowUp(toolResults: [CanonicalToolResult]) -> Bool
}
```

---

#### `DiagnosticsLogger` — 诊断日志（新增）

```swift
actor DiagnosticsLogger {
    static let shared = DiagnosticsLogger()

    enum Level { case debug, info, warn, error }
    enum Category { case bootstrap, runtime, download, inference, session, tool }

    func log(_ message: String, level: Level, category: Category,
             metadata: [String: String]? = nil)
    func event(_ name: String, properties: [String: String] = [:])
    func exportDiagnostics() -> DiagnosticsBundle
}
```

---

## 四、状态转移图（双轨制）

### 4.1 InstallState（per model，互相独立）

```
┌──────────────┐
│ notInstalled │◄──────────────────── remove() ──────┐
└──────┬───────┘                                     │
       │ install()                                   │
┌──────▼───────┐  cancel      ┌──────────┐          │
│ downloading  │─────────────►│(回到 not │          │
└──────┬───────┘  失败+清理   │ Installed)│          │
       │ complete             └──────────┘          │
┌──────▼───────┐                                    │
│  verifying   │                                    │
└──┬───────┬───┘                                    │
   │ OK    │ fail                                   │
┌──▼────┐ ┌▼─────────┐                              │
│install│ │ corrupt   │──── 用户确认重下 ─► downloading
│  ed   │ │           │                              │
└───────┘ └───────────┘                              │
    │                                                │
    └────────────────────────────────────────────────┘
```

### 4.2 RuntimeSessionState（单实例，active session）

```
                    ┌──────┐
                    │ idle │◄──────────────────────────┐
                    └──┬───┘                           │
                       │ load()                        │ unload complete
                ┌──────▼───────┐                  ┌────┴──────┐
                │   loading    │                  │ unloading  │
                │ .weights     │                  └────────────┘
                │ .session     │                       ▲
                └──┬───────┬───┘                       │
                   │ OK    │ fail                      │
            ┌──────▼──┐  ┌─▼───────┐                   │
            │  ready   │  │ failed  │── recover ──►idle │
            │(model,be)│  │ (.retry │                   │
            └─┬──┬──┬──┘  │ .switch)│                   │
              │  │  │     └─────────┘                   │
    generate()│  │  │ unload()                          │
              │  │  └───────────────────────────────────┘
              │  │ switchBackend()
              │  │
    ┌─────────▼┐ ┌▼──────────┐
    │generating│ │ switching  │──► loading (新 backend)
    │(txn.id)  │ └────────────┘
    └────┬─────┘
         │ txn committed/terminated
         ▼
       ready
```

### 4.3 GenerationTransaction（per turn）

```
  created ──► streaming ──► committed (terminal)
                  │
                  │ cancel()
                  ▼
              cancelling ──► terminated (terminal)
                  │              ▲
                  │ error         │
                  └──────────────┘
```

---

## 五、GPU/CPU 切换策略

### 5.1 LiteRT Environment 硬约束（不可协商）

```
进程启动
  │
  ├─ @main init()
  │   └─ LiteRTBootstrap.bootstrap()    ← 同步，第一行
  │       └─ dlopen(LiteRtMetalAccelerator.framework)
  │       └─ isBootstrapped = true
  │
  ├─ ... SwiftUI body 求值 ...
  │
  ├─ 用户进入聊天页
  │   └─ coordinator.load(modelID, backend: "cpu")
  │       └─ assert(LiteRTBootstrap.isBootstrapped)  ← 硬检查
  │       └─ litert_lm_engine_create(...)
  │           └─ LiteRT Environment 此时被 sealed
  │           └─ GPU accelerator 已在 registry 中 ✓
  │
  ├─ 用户切 GPU
  │   └─ coordinator.switchBackend(to: "gpu")
  │       └─ litert_lm_engine_create(..., backend: "gpu")
  │           └─ GPU accelerator 在 registry 中找到 ✓
  │           └─ 成功创建 Metal engine
```

### 5.2 热切换流程

```
switchBackend("gpu")
  precondition: sessionState == .ready
  precondition: LiteRTBootstrap.isBootstrapped
  →
  sessionState = .switching(modelID, from: "cpu", to: "gpu")
  → await inference.unloadAsync()     // 同步销毁旧 CPU engine
  sessionState = .loading(modelID, phase: .loadingWeights)
  → try await inference.load(modelID)  // 创建新 GPU engine
  sessionState = .ready(modelID, backend: "gpu")
  →
  成功: UI 正常
  失败: sessionState = .failed(RuntimeError(
           recoveryOptions: [.switchBackend("cpu"), .retry]
         ))
         → UI 显示 "GPU 加载失败" + "切回 CPU" 按钮
```

### 5.3 如果热切换仍不稳定（v1.5+ fallback）

```
用户切 GPU → 保存到 UserDefaults
  → UI 提示 "GPU 模式将在下次启动时生效"
  → 下次冷启动 → LiteRTBootstrap.bootstrap() → load(backend: "gpu")
```

---

## 六、启动流程

```swift
@main
struct PhoneClawApp: App {
    init() {
        // ▸ 第一行：LiteRT 进程级初始化（同步，必须在任何 engine_create 之前）
        LiteRTBootstrap.bootstrap()

        PCLog.suppressRuntimeNoise()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// ContentView.onAppear (或 .task) — 非阻塞异步
func onAppearSequence() async {
    // 1. 刷新安装状态
    installManager.refreshStates()

    // 2. 不立即加载模型 — 等用户操作或配置允许
    let selectedModelID = UserDefaults.preferredModel
    guard installManager.states[selectedModelID]?.isInstalled == true else {
        // 模型未安装，显示下载引导
        return
    }

    // 3. 自动加载到 ready（带 loading 动画）
    try? await coordinator.load(
        modelID: selectedModelID,
        backend: UserDefaults.preferredBackend
    )
}
```

---

## 七、聊天体验优化

### 7.1 输入 → 首 token

```
用户按发送
  │  0ms   sessionController.appendUserMessage()  ← 立刻显示
  │  0ms   sessionController.appendAssistantPlaceholder()  ← "正在思考…"
  │
  │        orchestrator.plan() — prompt 构建
  │        let (txn, stream) = coordinator.beginGeneration(prompt)
  │        sessionController.startStreaming(messageID)
  │
  │  TTFT  首 token → sessionController.appendTokens()
  │        后续 → batched flush (保持现有 160/标点/50ms)
  │
  │  Done  txn.commit(fullResponse)
  │        sessionController.finishStreaming()
  │        coordinator.sessionState = .ready
```

### 7.2 取消生成（安全版）

```
用户按取消
  → coordinator.cancelCurrentGeneration()
      → txn.cancel()                        // txn: streaming → cancelling
      → inference.cancel()                   // 设 cancelled flag
      → sessionController.markStreamingCancelled()  // UI 侧：cursor 移除，标 "已中断"
      → await txn.termination               // ← 等 stream for-await-in 退出循环
      → txn.onStreamTerminated()            // txn: cancelling → terminated (terminal)
      → await inference.resetKVSession()     // ← 此时 stream 已终止，KV reset 安全
      → sessionState = .ready               // 干净的 ready
```

**为什么需要 await txn.termination：**

当前 LiteRT 的 cancel 只是设一个 `cancelled` bool flag。生成线程在下一次
`for try await token in stream` 迭代时才会检查 flag 并退出循环。如果不等这个
循环退出就 `resetKVSession()`，LiteRT C 层可能还在写 KV cache：

```
时间线（旧方案，有竞态）:
  T0: cancel() — 设 cancelled=true
  T1: resetKVSession() — 关闭旧 session，打开新 session
  T2: C 层还在执行最后一个 token 的 decode，写入旧 session 的 KV buffer
      → 但旧 session 已被 delete → use-after-free 或脏数据
```

```
时间线（新方案，安全）:
  T0: cancel() — 设 cancelled=true
  T1: await txn.termination — 阻塞
  T2: C 层完成最后一个 token，stream yield 触发 for-await-in 检查 cancelled → 退出
  T3: txn.onStreamTerminated() — await 返回
  T4: resetKVSession() — 旧 session 的 C 层操作已全部结束 → 安全
```

### 7.3 流式刷新（保持现有）

`streamWithBatchedCallbacks` 的三条件刷新已合理，不改。

---

## 八、IPA 验证脚本（修正版）

```bash
#!/bin/bash
# validate-ipa.sh — 打包后自动检查常见问题
# 修正：覆盖 framework 内嵌 dylib（如 CLiteRTLM.framework/libXxx.dylib）

set -euo pipefail
IPA="${1:?Usage: validate-ipa.sh <path-to-ipa>}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
unzip -q "$IPA" -d "$TMPDIR"
APP=$(find "$TMPDIR/Payload" -name "*.app" -maxdepth 1 -type d | head -1)
ERRORS=0

echo "=== IPA Validation: $(basename "$IPA") ==="

# 1. 裸 dylib — App bundle 顶层（非 Frameworks/ 内）
echo ""
echo "--- Check 1: Bare dylibs outside Frameworks/ ---"
BARE=$(find "$APP" -maxdepth 1 -name "*.dylib" 2>/dev/null)
if [ -n "$BARE" ]; then
    echo "❌ Bare dylibs in app root:"
    echo "$BARE"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ No bare dylibs in app root"
fi

# 2. Framework 内嵌 dylib — framework 内不应有额外 .dylib（只应有主 binary）
#    这会导致 App Store 拒包（之前 CLiteRTLM.framework 内嵌 dylib 踩过）
echo ""
echo "--- Check 2: Nested dylibs inside frameworks ---"
NESTED_ISSUES=""
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    FW_NAME=$(basename "$fw" .framework)
    # framework 内的 .dylib 文件（排除主 binary 本身）
    NESTED=$(find "$fw" -name "*.dylib" -not -name "$FW_NAME" 2>/dev/null)
    if [ -n "$NESTED" ]; then
        NESTED_ISSUES="$NESTED_ISSUES\n  $(basename "$fw"): $NESTED"
    fi
    # framework 内不应有非主 binary 的 Mach-O（可能是被误放进来的 .so 等）
    for f in "$fw"/*; do
        [ -f "$f" ] || continue
        BASENAME=$(basename "$f")
        [ "$BASENAME" = "$FW_NAME" ] && continue
        [ "$BASENAME" = "Info.plist" ] && continue
        [[ "$BASENAME" == *.plist ]] && continue
        [[ "$BASENAME" == *.modulemap ]] && continue
        # 检查是否是 Mach-O
        if file "$f" 2>/dev/null | grep -q "Mach-O"; then
            NESTED_ISSUES="$NESTED_ISSUES\n  $(basename "$fw"): unexpected Mach-O: $BASENAME"
        fi
    done
done
if [ -n "$NESTED_ISSUES" ]; then
    echo "❌ Nested dylibs/Mach-O inside frameworks:"
    echo -e "$NESTED_ISSUES"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ No nested dylibs inside frameworks"
fi

# 3. Framework MinimumOSVersion
echo ""
echo "--- Check 3: Framework MinimumOSVersion ---"
for fw in "$APP/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    PLIST="$fw/Info.plist"
    if [ -f "$PLIST" ]; then
        MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$PLIST" 2>/dev/null || echo "?")
        echo "  $(basename "$fw"): MinOS=$MIN_OS"
    else
        echo "  ⚠️  $(basename "$fw"): no Info.plist"
    fi
done

# 4. otool -L — 主 binary 链接检查
echo ""
echo "--- Check 4: Main binary link dependencies ---"
BINARY="$APP/$(basename "$APP" .app)"
if [ -f "$BINARY" ]; then
    BAD_LINKS=$(otool -L "$BINARY" 2>/dev/null | grep -v "@rpath\|/usr/lib\|/System\|:" | sed 's/^[[:space:]]*/  /')
    if [ -n "$BAD_LINKS" ]; then
        echo "❌ Suspicious linked libraries:"
        echo "$BAD_LINKS"
        ERRORS=$((ERRORS + 1))
    else
        echo "✅ All linked libraries look correct"
    fi
fi

# 5. ITSAppUsesNonExemptEncryption
echo ""
echo "--- Check 5: Export compliance ---"
ENCRYPTION=$(/usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$APP/Info.plist" 2>/dev/null || echo "")
if [ "$ENCRYPTION" = "false" ]; then
    echo "✅ ITSAppUsesNonExemptEncryption = false"
elif [ -z "$ENCRYPTION" ]; then
    echo "⚠️  ITSAppUsesNonExemptEncryption not set (will prompt on ASC upload)"
else
    echo "❌ ITSAppUsesNonExemptEncryption = $ENCRYPTION (should be false)"
    ERRORS=$((ERRORS + 1))
fi

# 6. SwiftSupport
echo ""
echo "--- Check 6: SwiftSupport ---"
if [ -d "$TMPDIR/SwiftSupport" ]; then
    echo "✅ SwiftSupport present"
else
    echo "ℹ️  No SwiftSupport directory (normal for iOS 12.2+ minimum deployment)"
fi

# 7. codesign 验证
echo ""
echo "--- Check 7: Code signature ---"
codesign -vvv "$APP" 2>&1 | head -5

echo ""
echo "=== Result: $ERRORS error(s) ==="
exit $ERRORS
```

---

## 九、落地顺序（修正版）

### Phase 1: LiteRT Bootstrap 硬约束（1 周）

```
目标：确保 GPU accelerator preload 绝对早于任何 engine_create

做的事：
  - 新建 LiteRTBootstrap enum
  - 从 PhoneClawEngine.swift 的 _preloadGpuAcceleratorOnce 挪到 Bootstrap
  - PhoneClawApp.init() 第一行调 LiteRTBootstrap.bootstrap()
  - LiteRTBackend.load() 入口加 assert(LiteRTBootstrap.isBootstrapped)
  - 加诊断日志确认 bootstrap 时间戳

验收：
  - CPU 冷启动 → 切 GPU → 成功 (不需要重启)
  - GPU 冷启动 → 切 CPU → 切回 GPU → 成功
  - bootstrap 日志在所有 engine_create 日志之前
```

### Phase 2: RuntimeSessionState（2 周）

```
目标：active session 状态机，只接管 LiteRT load/unload/switch

做的事：
  - 新建 RuntimeSessionState enum
  - 新建 ModelRuntimeCoordinator (只管 session state + install state 编排)
  - AgentEngine.reloadModel() 改为调 coordinator.switchBackend() 或 coordinator.load()
  - 去掉 LiteRTBackend 的 isLoaded/isLoading bool，改为 coordinator 统一管

验收：
  - 非法状态转移在 debug 模式 assert fail
  - UI 在 loading/switching/unloading 期间按钮正确灰置
  - 所有现有功能不回归
```

### Phase 3: PromptBudgeter + 真实 token 估算（1 周）

```
目标：修正 count/4 的粗糙估算，让 context budget 更准确

做的事：
  - 新建 PromptBudgeter，从 AgentEngine 抽取 budget 相关逻辑
  - 中文按 ~1.5 字/token 估算（而非 4 字/token）
  - 或集成 SentencePiece tokenizer 做精确计数（如果 overhead 可接受）

验收：
  - 中文对话可用历史深度提升 30-50%
  - 不超 KV cache limit（4096）
```

### Phase 4: GenerationTransaction + ChatSessionController（2 周）

```
目标：取消安全 + 会话管理独立

做的事：
  - 新建 GenerationTransaction（stream 生命周期 + cancel safety）
  - 新建 ChatSessionController（从 AgentEngine 抽取消息管理）
  - InferenceService 补 unloadAsync()
  - cancel 流程改为 await txn.termination → resetKVSession

验收：
  - 快速连续 cancel + 重新生成，KV 不脏
  - 取消后立刻发新消息，不卡顿不报错
  - session 持久化不再 fire-and-cancel 频繁抖动
```

### Phase 5: AgentOrchestrator + ViewModel（3 周）

```
目标：AgentEngine 瘦身到 ~500 行

做的事：
  - 新建 AgentOrchestrator（路由/Prompt/工具）
  - 新建 ChatViewModel / ConfigViewModel
  - AgentEngine 变成纯粹的 thin coordinator
  - DiagnosticsLogger 替代 print()

验收：
  - AgentEngine < 600 行
  - 新模块各有基本 unit test
  - 所有功能不回归
```

### 每个 Phase 的验收标准

- 手工回归 checklist（至少覆盖：纯文本聊天、图片输入、CPU/GPU 切换、模型下载、取消生成、Live 模式）
- 新模块有 unit test
- AgentEngine 行数持续减少
- 打 TestFlight 验证

---

## 十、App Store Connect 合规约束

> 这些规则是架构约束，不是打包阶段临时修。PhoneClaw 已经踩过裸 dylib 拒包、
> framework 内嵌 dylib、MinimumOSVersion 不一致、Missing Compliance 等问题。
> 后续所有 runtime / framework / model 打包方案都必须默认满足以下规则。

### 10.1 Framework 与 Binary 规则

| # | 规则 | 违反后果 |
|---|------|---------|
| F1 | App bundle 里不能有裸 `.dylib`，尤其不能塞在 `Frameworks/*.framework/` 里当资源 | App Store 拒包 |
| F2 | 第三方动态库必须包成合法 `.framework` / `.xcframework` | 拒包 |
| F3 | framework binary 名必须和 framework 目录名匹配，如 `LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator` | 签名校验失败 |
| F4 | 每个 embedded framework 必须有正确 `Info.plist`：`CFBundleExecutable` 匹配 binary 名、`CFBundlePackageType=FMWK`、`MinimumOSVersion` | 拒包 |
| F5 | nested framework 的 `MinimumOSVersion` 不能低于主 App 的最低系统版本 | 拒包 / 审核警告 |
| F6 | 不要手动塞 `libswift*.dylib` 到 `Payload/PhoneClaw.app/Frameworks/`。Swift runtime / SwiftSupport 交给 Xcode archive/export 处理 | 签名冲突 / 拒包 |
| F7 | 不要对 Swift runtime dylib 重新签名 | 签名无效 |
| F8 | `otool -L` 不能出现无法在 app bundle 中解析的 `@rpath/libLiteRt*.dylib` hard-link。主 app 不能 hard-link 到不存在的裸 dylib | 启动崩溃 / 拒包 |
| F9 | 可以保留 framework binary 的 install name 用于 runtime `dlopen` 兼容，但主 app 不能静态链接到它 | 运行时 OK，链接期约束 |

### 10.2 签名与合规规则

| # | 规则 | 违反后果 |
|---|------|---------|
| S1 | `ITSAppUsesNonExemptEncryption=false` 固化在主 App 的 `Info.plist` | TestFlight Missing Compliance，阻塞分发 |
| S2 | 所有 embedded framework 和主 binary 必须用同一 signing identity 签名 | 安装失败 / 拒包 |
| S3 | Archive → Export 时使用 Xcode 的 automatic signing，不手动 strip + 重签 | 确保签名链完整 |

### 10.3 热更新边界（架构红线）

这条约束直接影响未来的"模型热更新"和"插件化"设计。App Store Review Guidelines 2.5.2
禁止 App 下载并执行可执行代码（native binary）。

| 类别 | 可热更新 | 说明 |
|------|---------|------|
| 模型权重 | ✅ | `.litertlm` / `.gguf` / `.safetensors` / `.mlmodelc` — 纯数据文件 |
| Prompt / System Prompt | ✅ | `SYSPROMPT.md` / `SKILL.md` — 纯文本 |
| Skill schema / manifest | ✅ | JSON / YAML 配置 |
| Tokenizer 文件 | ✅ | `tokenizer.json` / `spiece.model` — 纯数据 |
| 用户配置 | ✅ | UserDefaults / JSON config |
| LiteRT native runtime (`CLiteRTLM.framework`) | ❌ | 包含 Mach-O binary，必须走 App 更新 |
| Metal accelerator (`LiteRtMetalAccelerator.framework`) | ❌ | 同上 |
| TopK Metal sampler (`LiteRtTopKMetalSampler.framework`) | ❌ | 同上 |
| llama.cpp runtime (`llama.framework`) | ❌ | 同上 |
| 任何 `.dylib` / `.framework` / Mach-O | ❌ | App Store Guidelines 2.5.2 禁止 |
| CoreML 编译后的 `.mlmodelc` | ✅ | 是模型数据，不是可执行代码。可热更新 |

**架构约束：** `ModelInstallManager` 的 `install()` 方法只允许下载上表中 ✅
类别的文件。如果 `ModelDescriptor` 或 `CompanionFile` 的 `fileName` 以
`.framework` / `.dylib` / `.so` 结尾，应该在编译期（或至少运行时）拒绝，
而不是静默下载。

```swift
// ModelInstallManager 中的安全检查
private static let forbiddenExtensions = [".framework", ".dylib", ".so", ".a"]

func install(model: ModelDescriptor) async throws {
    // 架构红线：不允许下载 native binary
    let allFiles = [model.fileName] + model.companionFiles.map(\.fileName)
    for file in allFiles {
        for ext in Self.forbiddenExtensions {
            precondition(
                !file.hasSuffix(ext),
                "ModelInstallManager 不允许下载 native binary: \(file)。" +
                "Native runtime 升级必须走 App 更新。"
            )
        }
    }
    // ... 正常下载流程 ...
}
```

### 10.4 自动化验证

`validate-ipa.sh`（第八章）必须从文档变成可执行脚本，进 CI / release checklist。

**执行时机：**
- 每次 `xcodebuild archive` + `exportArchive` 后自动运行
- Transporter 上传前人工确认
- 未来接入 CI 时作为 gate check（非 0 退出码阻塞流水线）

**最低检查项（对应上述规则编号）：**

| 检查 | 对应规则 | validate-ipa.sh Check # |
|------|---------|------------------------|
| 裸 dylib（app root） | F1 | Check 1 |
| framework 内嵌 dylib | F1, F3 | Check 2 |
| framework Info.plist 完整性 | F4, F5 | Check 3 |
| otool -L hard-link | F8 | Check 4 |
| ITSAppUsesNonExemptEncryption | S1 | Check 5 |
| codesign 验证 | S2, S3 | Check 7 |

---

## 十一、保持与演进

| 模块 | 策略 | 说明 |
|------|------|------|
| SwiftUI | 保持 | 没有换的理由 |
| InferenceService 协议 | **演进** | 补 `unloadAsync()` / `activeCapabilities`，通过默认实现向后兼容 |
| BackendDispatcher | **演进** | 转发 `unloadAsync()`，被 Coordinator 管理生命周期 |
| LiteRTBackend 内部实现 | 基本保持 | `load()` / `generate()` 不变，`unload()` 补 async 版本 |
| MiniCPMVBackend | 保持 | 后续按需补 `unloadAsync()` 真实实现 |
| PhoneClawEngine (C wrapper) | 保持 | `destroySynchronously()` 已够用 |
| ResumableAssetDownloader | 保持 | 断点续传逻辑已验证 |
| Router / Planner / ToolChain | 保持 | 直接挪到 AgentOrchestrator 下 |
| streamWithBatchedCallbacks | 保持 | 流式刷新策略合理 |
| PromptShape / SessionGroup / ReuseDecision | 保持 | 类型设计好 |

---

## 十二、收益总结

| 维度 | 现状 | 改后 |
|------|------|------|
| **状态可预测性** | bool 散落，可能矛盾 | 三条独立状态流，枚举互斥，转移白名单 |
| **多模型并行** | 下载和推理状态绑定 | InstallState per-model，推理独立，可边聊边下 |
| **GPU/CPU 切换** | 隐式 unload+load，accelerator 时机不确定 | Bootstrap 硬保证 + switching 原子状态 |
| **取消安全** | cancel→resetKV 有竞态 | GenerationTransaction + await termination |
| **新增功能成本** | 改 2051 行大文件 | 改对应模块，~200-500 行文件 |
| **可测试性** | 几乎无法 unit test | 每个模块独立可测 |
| **错误恢复** | catch 散落，不一致 | RuntimeError 结构化 + 统一恢复路径 |
| **调试效率** | print 散落 | DiagnosticsLogger + 可导出诊断包 |
| **UI 体验** | "正在加载模型..." | LoadPhase 细粒度 + 按钮状态绑定状态机 |
