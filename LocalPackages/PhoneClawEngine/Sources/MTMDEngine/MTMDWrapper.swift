//
//  MTMDWrapper.swift
//  MiniCPM-V-demo
//
//  Created by AI Assistant on 2024/12/19.
//

import Foundation
import Combine
internal import CMTMDBridge


/// MTMD 多模态推理包装器
@MainActor
public class MTMDWrapper: ObservableObject {
    
    // MARK: - Published Properties
    
    /// 当前输出 Token
    @Published public private(set) var currentToken: MTMDToken = .empty
    
    /// 完整的输出内容
    @Published public private(set) var fullOutput: String = ""
    
    /// 生成状态
    @Published public private(set) var generationState: MTMDGenerationState = .idle
    
    /// 初始化状态
    @Published public private(set) var initializationState: MTMDInitializationState = .notInitialized
    
    /// 是否有内容可以生成
    @Published public private(set) var hasContent: Bool = false
    
    // MARK: - Private Properties
    
    /// MTMD 上下文指针
    private var context: OpaquePointer?
    
    /// 生成参数
    private var params: MTMDParams?
    
    /// 生成任务
    private var generationTask: Task<Void, Never>?
    
    /// 生成队列
    private let generationQueue = DispatchQueue(label: "com.mtmd.generation", qos: .userInitiated)
    
    /// 线程锁
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    public init() {
        print("MTMDWrapper: 初始化")
    }
    
    deinit {
        // 在 deinit 中同步清理资源
        generationTask?.cancel()
        generationTask = nil
        
        // 清理资源
        if let ctx = context {
            cmtmd_free(ctx)
            context = nil
        }
        
        print("MTMDWrapper: 析构函数清理完成")
    }
    
    // MARK: - Public Methods
    
    /// 初始化 MTMD 上下文
    /// - Parameter params: 初始化参数
    public func initialize(with params: MTMDParams) async throws {
        guard initializationState != .initializing else {
            throw MTMDError.alreadyInitializing
        }
        
        guard initializationState != .initialized else {
            throw MTMDError.alreadyInitialized
        }
        
        updateInitializationState(.initializing)
        
        // 在后台线程执行初始化
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 直接调 C 桥接, 把 Swift String 作为 C-string 传过去 —
                // 不再需要 Swift 端用 std.string(...) 构造 C++ 字段。
                let ctx = params.modelPath.withCString { modelPathC in
                    params.mmprojPath.withCString { mmprojPathC in
                        params.coremlPath.withCString { coremlPathC in
                            cmtmd_init(
                                modelPathC,
                                mmprojPathC,
                                coremlPathC,
                                Int32(params.nPredict),
                                Int32(params.nCtx),
                                Int32(params.nThreads),
                                params.temperature,
                                params.useGPU,
                                params.mmprojUseGPU,
                                params.warmup,
                                Int32(params.imageMaxSliceNums)
                            )
                        }
                    }
                }

                if ctx == nil {
                    continuation.resume(throwing: MTMDError.initializationFailed("无法创建 MTMD 上下文"))
                    return
                }
                
                // 回到主线程更新状态
                Task { @MainActor in
                    self.context = ctx
                    self.params = params
                    self.initializationState = .initialized
                    print("MTMDWrapper: 初始化成功")
                    continuation.resume()
                }
            }
        }
    }

    /// addImageInBackground / addFrameInBackground 默认超时（秒）。
    ///
    /// MiniCPM-V 4.6 + 9 切片 + 首次 ANE 编译，最坏路径在老设备上也通常 < 60s。
    /// 给 180s 是为了"宁可慢但保住功能"，超过这个时间几乎一定是 ANE driver
    /// 卡住或者磁盘 IO 卡住，应当上报失败让 UI 兜底。
    public static let defaultPrefillTimeoutSeconds: TimeInterval = 180

    /// 在后台线程中添加图片（非 @MainActor 版本）
    /// - Parameters:
    ///   - imagePath: 图片路径
    ///   - timeoutSeconds: 等待 mtmd_ios_prefill_image 的最长时间。超时即抛
    ///     `MTMDError.timeout`，让上层（cell 进度条 / "预处理耗时" 文本）能
    ///     走兜底分支，而不是永远卡在没有耗时的状态。
    ///     注意：由于 C++ 同步 API 没法被中断，超时后底层调用仍会在后台跑完，
    ///     但 Swift 这边已经放手，UI 不再被它绑住。
    public func addImageInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addImageInBackground timed out after \(Int(timeoutSeconds))s (image=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { cmtmd_prefill_image(ctx, $0) }

                if result != 0 {
                    let errorMessage = cmtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addImageInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }

    public func addFrameInBackground(_ imagePath: String,
                                     timeoutSeconds: TimeInterval = MTMDWrapper.defaultPrefillTimeoutSeconds) async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }

        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }

        try await runWithWatchdog(
            timeoutSeconds: timeoutSeconds,
            timeoutMessage: "addFrameInBackground timed out after \(Int(timeoutSeconds))s (frame=\(imagePath))"
        ) { resumeOnce in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = imagePath.withCString { cmtmd_prefill_frame(ctx, $0) }

                if result != 0 {
                    let errorMessage = cmtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    print("MTMDWrapper: addFrameInBackground failed, imagePath=\(imagePath), error=\(error)")
                    resumeOnce(.failure(MTMDError.imageLoadFailed(error)))
                } else {
                    Task { @MainActor in
                        self.hasContent = true
                        resumeOnce(.success(()))
                    }
                }
            }
        }
    }
    
    /// 在后台线程中添加文本（非 @MainActor 版本）
    /// - Parameters:
    ///   - text: 文本内容
    ///   - role: 角色（user/assistant）
    public func addTextInBackground(_ text: String, role: String = "user") async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard let ctx = context else {
            throw MTMDError.contextNotInitialized
        }
        
        // 在后台线程执行 C 函数调用
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = text.withCString { textC in
                    role.withCString { roleC in
                        cmtmd_prefill_text(ctx, textC, roleC)
                    }
                }

                if result != 0 {
                    let errorMessage = cmtmd_get_last_error(ctx)
                    let error = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
                    continuation.resume(throwing: MTMDError.textAddFailed(error))
                } else {
                    // 回到主线程更新状态
                    Task { @MainActor in
                        self.hasContent = true
                        print("MTMDWrapper: 文本添加成功（后台线程）: \(text)")
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    /// 开始生成
    public func startGeneration() async throws {
        guard initializationState == .initialized else {
            throw MTMDError.contextNotInitialized
        }
        
        guard hasContent else {
            throw MTMDError.noContentToGenerate
        }
        
        // 允许在空闲或已完成状态下重新开始生成
        guard generationState == .idle || generationState == .completed else {
            throw MTMDError.generationInProgress
        }
        
        updateGenerationState(.generating)
        
        // 取消之前的生成任务
        generationTask?.cancel()
        
        // 创建新的生成任务
        generationTask = Task {
            await performGeneration()
        }
    }
    
    /// 停止生成
    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        // 只有在当前状态不是 completed 时才重置为 idle
        if generationState != .completed {
            updateGenerationState(.completed)
        }
        print("MTMDWrapper: 生成已停止")
    }
    
    /// 运行时调整单张图最大切片数（无需 reload mmproj）。
    ///
    /// clip 在每张图编码时都会重新读取 hparams.custom_image_max_slice_nums，
    /// 所以这里只是把新值写入上下文，下一张图自然就用新档位生效。
    /// - Parameter n: 1 表示不切图（最快），9 表示 MiniCPM-V 模型上限（最清晰）。
    ///                传 -1 等价于"按模型默认"。
    public func setImageMaxSliceNums(_ n: Int) {
        guard let ctx = context else {
            // 还没 init 完，下一次 initialize() 会通过 MTMDParams 把值带进去。
            print("MTMDWrapper: setImageMaxSliceNums 调用时上下文未就绪，nop")
            return
        }
        cmtmd_set_image_max_slice_nums(ctx, Int32(n))
        print("MTMDWrapper: image_max_slice_nums 已切换为 \(n)")
    }

    /// 重置上下文
    public func reset() async {
        stopGeneration()
        
        // 清理资源
        if let ctx = context {
            cmtmd_free(ctx)
            context = nil
        }
        
        // 重置状态
        initializationState = .notInitialized
        generationState = .idle
        currentToken = .empty
        fullOutput = ""
        hasContent = false
        params = nil
        
        print("MTMDWrapper: 上下文已重置")
    }
    
    /// 清理资源
    public func cleanup() async {
        await reset()
    }
    
    // MARK: - Private Methods
    
    /// 执行生成
    private func performGeneration() async {
        guard let ctx = context else {
            updateGenerationState(.failed(.contextNotInitialized))
            return
        }
        
        fullOutput = ""
        
        // 生成循环
        while !Task.isCancelled {
            
            // 在后台线程执行 C 函数调用
            let cToken = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let token = cmtmd_loop(ctx)
                    continuation.resume(returning: token)
                }
            }
            
            var tokenString = cToken.token != nil ? String(cString: cToken.token) : ""
            
            // 在主线程更新状态
            currentToken = MTMDToken(content: tokenString, isEnd: cToken.is_end)
            if fullOutput.isEmpty && tokenString == "\n" {
                tokenString = ""
            }
            fullOutput += tokenString
            
            // 释放 C 字符串
            if cToken.token != nil {
                // mtmd_ios_string_free(cToken.token)
            }
            
            // 检查是否生成完成
            if cToken.is_end {
                updateGenerationState(.completed)
                print("MTMDWrapper: 生成完成: \(fullOutput)")
                // 清理任务引用但不重置状态，让状态保持为 completed
                // 注意：不在这里清 KV cache，否则多轮上下文会丢。
                // KV 的清理统一交给显式 reset()（切换模型 / 新对话入口）
                generationTask = nil
                return
            }
            
            // 避免过度占用 CPU
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    /// 给同步阻塞型 C 调用包一层 watchdog 超时。
    ///
    /// 这里的 contract：
    /// - `body` 一定要在某个后台线程上启动 C 调用，并把它的成功 / 失败用
    ///   `resumeOnce` 上报。`resumeOnce` 自带 idempotency，多次调用只生效首次。
    /// - watchdog 在 `timeoutSeconds` 后会再调 `resumeOnce(.failure(.timeout))`，
    ///   如果 body 的 success / failure 已经先到，watchdog 是 no-op。
    /// - 反过来如果 watchdog 先到，body 后到的 resumeOnce 是 no-op，但 C 调用
    ///   仍会在后台跑完。这是有意为之 —— 我们没法中断同步 C API，但至少不
    ///   让 UI 永远等。下一次进入会先 `mtmd_ios_clean_kv_cache` / reset，
    ///   被孤儿化的那次推理对状态没有持续污染。
    private func runWithWatchdog(
        timeoutSeconds: TimeInterval,
        timeoutMessage: String,
        body: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        // 把 idempotent 的 resume 状态寄存到一个引用类型上（class wrapper），
        // 避免在 @escaping 闭包之间共享 var 导致的 Sendable 警告。
        final class ResumeState {
            let lock = NSLock()
            var didResume = false
        }
        let state = ResumeState()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                state.lock.lock()
                if state.didResume {
                    state.lock.unlock()
                    return
                }
                state.didResume = true
                state.lock.unlock()

                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            body(resumeOnce)

            // watchdog：用 utility QoS 的全局队列，避免抢占 userInitiated。
            // 时机点过了就触发 timeout，但如果 worker 已经先 resume，
            // resumeOnce 会自动 no-op。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                resumeOnce(.failure(MTMDError.timeout(timeoutMessage)))
            }
        }
    }

    /// 更新初始化状态
    private func updateInitializationState(_ state: MTMDInitializationState) {
        initializationState = state
    }
    
    /// 更新生成状态
    private func updateGenerationState(_ state: MTMDGenerationState) {
        generationState = state
    }
}

