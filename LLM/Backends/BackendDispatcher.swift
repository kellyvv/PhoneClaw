import Foundation
import CoreImage

// MARK: - Backend Dispatcher
//
// InferenceService 实现, 内部持两个真实 backend 实例 — LiteRTBackend (Gemma 4)
// 和 MiniCPMVBackend (MiniCPM-V 4.6). 按 load 时传入的 modelID 查到对应
// `ModelDescriptor.artifactKind`, 切换 `active` 指向, 之后所有协议方法都
// 转发给 active backend。
//
// 路由表:
//   ArtifactKind.litertlmFile  → LiteRTBackend   (Gemma 4 / .litertlm)
//   ArtifactKind.ggufBundle    → MiniCPMVBackend (MiniCPM-V / GGUF + ANE)
//   ArtifactKind.mlxDirectory  → 错误 (MLX backend 当前未集成, 保留 case 占位)
//
// 为什么是 dispatcher 而不是"换 inference 实例":
//   AgentEngine.inference 字段是 `let inference: InferenceService`, 改成 var 要
//   动整套调用链。dispatcher 让该字段语义不变 (一个稳定的 InferenceService),
//   切换隐藏在内部, 上层代码完全无感。
//
// 不破坏现有路径的保证:
//   - 调用方只 load Gemma 4 模型时, dispatcher 只把请求转发给 liteRT,
//     MiniCPMVBackend 实例只是个轻量壳子 (没 load 模型时不占模型内存)。
//   - LiteRTBackend 自身行为完全跟集成 MiniCPM-V 之前一字不变。
//   - 协议默认实现的 KV session / MTP 方法都自动按 active 后端处理 (LiteRT
//     真实生效, MiniCPM-V no-op)。

@Observable
final class BackendDispatcher: InferenceService {

    // MARK: - Backends

    let liteRT: LiteRTBackend
    let miniCPMV: MiniCPMVBackend

    /// 当前 active 的后端。`load` 时按 ModelDescriptor 路由切换。
    /// 协议要求的所有方法/属性都转发到这里。
    private var active: any InferenceService

    // MARK: - Routing

    @ObservationIgnored
    private let modelLookup: (String) -> ModelDescriptor?

    // MARK: - Init

    init(
        liteRT: LiteRTBackend,
        miniCPMV: MiniCPMVBackend,
        modelLookup: @escaping (String) -> ModelDescriptor?
    ) {
        self.liteRT = liteRT
        self.miniCPMV = miniCPMV
        self.modelLookup = modelLookup
        // 默认 active 走 LiteRT — 保持现有路径行为不变 (app 启动时如果还没
        // 选 MiniCPM-V, 任何对 inference 的访问都是 LiteRT)。
        self.active = liteRT
    }

    // MARK: - InferenceService: Lifecycle

    func load(modelID: String) async throws {
        try await switchActive(forModelID: modelID)
        try await active.load(modelID: modelID)
    }

    func unload() {
        active.unload()
    }

    func cancel() {
        active.cancel()
    }

    func enterLiveMode(systemPrompt: String?) async throws {
        try await active.enterLiveMode(systemPrompt: systemPrompt)
    }

    func exitLiveMode() async {
        await active.exitLiveMode()
    }

    // MARK: - InferenceService: Generation

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        active.generate(prompt: prompt)
    }

    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        active.generateMultimodal(
            images: images,
            audios: audios,
            prompt: prompt,
            systemPrompt: systemPrompt
        )
    }

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        active.generateRaw(text: text, images: images)
    }

    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        active.generateLive(prompt: prompt, images: images, audios: audios)
    }

    // MARK: - InferenceService: Observable State

    var isLoaded: Bool { active.isLoaded }
    var isLoading: Bool { active.isLoading }
    var isGenerating: Bool { active.isGenerating }

    var statusMessage: String {
        get { active.statusMessage }
        set { active.statusMessage = newValue }
    }

    var stats: InferenceStats { active.stats }

    // MARK: - InferenceService: Sampling

    var samplingTopK: Int {
        get { active.samplingTopK }
        set { active.samplingTopK = newValue }
    }
    var samplingTopP: Float {
        get { active.samplingTopP }
        set { active.samplingTopP = newValue }
    }
    var samplingTemperature: Float {
        get { active.samplingTemperature }
        set { active.samplingTemperature = newValue }
    }
    var maxOutputTokens: Int {
        get { active.maxOutputTokens }
        set { active.maxOutputTokens = newValue }
    }

    // MARK: - InferenceService: KV Session (LiteRT-specific, forward as-is)

    var lastKVPrefillTokens: Int { active.lastKVPrefillTokens }
    var kvSessionActive: Bool { active.kvSessionActive }
    var sessionHasContext: Bool { active.sessionHasContext }

    func resetKVSession() async {
        await active.resetKVSession()
    }

    func revertToTextOnly() async {
        await active.revertToTextOnly()
    }

    func setPreferredBackend(_ backend: String) {
        // 两个后端都接受这个偏好, 各自 reload 时生效。下次切到任一边都会
        // 用上最新值, 不需要 dispatcher 自己维护状态。
        liteRT.setPreferredBackend(backend)
        miniCPMV.setPreferredBackend(backend)
    }

    func setEnableSpeculativeDecoding(_ enabled: Bool) {
        // MTP 只 LiteRT 有意义, MiniCPM-V 走默认 no-op 实现。
        liteRT.setEnableSpeculativeDecoding(enabled)
        miniCPMV.setEnableSpeculativeDecoding(enabled)
    }

    func prepareForSessionGroupTransition(
        from previousGroup: SessionGroup?,
        to nextGroup: SessionGroup
    ) async {
        await active.prepareForSessionGroupTransition(from: previousGroup, to: nextGroup)
    }

    // MARK: - Private

    /// 按 modelID 查 descriptor.artifactKind, 切换 `active`。
    /// 切换时把旧 active 上的模型 unload, 防止内存重叠。
    private func switchActive(forModelID modelID: String) async throws {
        guard let descriptor = modelLookup(modelID) else {
            // 上层 (catalog) 没有这个 modelID。让 active.load 自己抛
            // ModelBackendError.modelNotLoaded / modelFileMissing。
            return
        }

        let target: any InferenceService
        switch descriptor.artifactKind {
        case .litertlmFile:
            target = liteRT
        case .ggufBundle:
            target = miniCPMV
        case .mlxDirectory:
            // 当前 PhoneClaw 不集成 MLX backend, descriptor 也不应该出现 mlxDirectory,
            // 但 enum case 存在所以这里给个明确错误而不是 silent fallback。
            throw BackendDispatcherError.unsupportedArtifactKind(modelID: modelID, kind: ".mlxDirectory")
        }

        // 同一后端继续用, 没什么要切的。
        if target === active {
            return
        }

        // 切换到不同后端 — 先把旧的 unload, 防止两个 backend 同时持模型内存。
        if active.isLoaded {
            active.unload()
        }

        active = target
    }
}

// MARK: - Errors

public enum BackendDispatcherError: LocalizedError {
    case unsupportedArtifactKind(modelID: String, kind: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArtifactKind(let id, let kind):
            return tr(
                "模型 \(id) 的资产类型 \(kind) 当前后端不支持",
                "Model \(id) has unsupported artifact kind: \(kind)"
            )
        }
    }
}
