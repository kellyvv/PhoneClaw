import Foundation

// MARK: - MLXLocalLLMService install-state extension
//
// selectModel / isModelAvailable / installState / refreshModelInstallStates /
// downloadMetrics。纯 bookkeeping, 不触碰模型权重加载 (那在主类 load() 里)。

extension MLXLocalLLMService {

    public func selectModel(id: String) -> Bool {
        guard let option = Self.availableModels.first(where: { $0.id == id }),
              option != selectedModel else {
            return false
        }

        selectedModel = option

        // KV cache reuse 按模型适配 (真机 2026-04-16 验证):
        //   E4B (4B params): multi-round tool_call follow-up 时能正确从 delta
        //                    "消化" 新 prompt 里的 "工具已执行, 该总结" 指令,
        //                    享受 1869ms→532ms 3.5x TTFT 加速.
        //   E2B (2B params): 被 cached prefix 锚住, follow-up prompt 的"工具结果"
        //                    段权重弱, **反复输出同一 tool_call**, 死循环
        //                    (真机日志: 4 轮重复 calendar-create-event,
        //                    E4B 同 prompt 1 轮 tool + 1 轮总结正常).
        //
        // F3 + KV reuse: E4B 验证 OK (cache hit 89-96%, 真机不闪崩); E2B 实测
        // R2 follow-up 0 token 空输出 (推测 KV cache 复用 R1 prefix 时模型状态
        // 包含 end-of-turn 信号, F3 follow-up prompt 交互导致提前 EOS).
        // E2B 暂关 KV reuse, F3 prompt 结构本身仍生效.
        kvReuseEnabled = !option.id.contains("e2b")

        statusMessage = isLoaded
            ? "已选择 \(option.displayName)，准备重新加载..."
            : "已选择 \(option.displayName)，等待加载..."
        return true
    }

    public func isModelAvailable(_ model: BundledModelOption) -> Bool {
        ModelPaths.bundled(for: model) != nil
            || ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model))
    }

    public func installState(for model: BundledModelOption) -> ModelInstallState {
        if ModelPaths.bundled(for: model) != nil {
            return .bundled
        }
        if ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model)) {
            return .downloaded
        }
        return modelInstallStates[model.id] ?? .notInstalled
    }

    public func refreshModelInstallStates() {
        cleanupStalePartialDirectories()
        for model in Self.availableModels {
            if ModelPaths.bundled(for: model) != nil {
                modelInstallStates[model.id] = .bundled
            } else if ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model)) {
                modelInstallStates[model.id] = .downloaded
            } else if case .checkingSource = modelInstallStates[model.id] {
                continue
            } else if case .downloading = modelInstallStates[model.id] {
                continue
            } else {
                modelInstallStates[model.id] = .notInstalled
            }
        }
    }

    public func downloadMetrics(for modelID: String) -> ModelDownloadMetrics? {
        modelDownloadMetrics[modelID]
    }
}
