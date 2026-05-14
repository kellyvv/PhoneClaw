import Foundation
import CoreImage

// MARK: - Agent ViewModels
//
// Plan §3.1 把 UI 层画成只依赖 ChatViewModel / ConfigViewModel / LiveModeViewModel
// 三个 ViewModel,不直接碰 AgentEngine。
//
// 当前 v1.3 现状:
//   - SwiftUI + @Observable 让 ContentView/ConfigurationsView 直接绑 engine 工作得
//     很好,无 boilerplate
//   - AgentEngine 已经瘦身到 215 行 (wiring hub),不是 God Class
//   - 强行加 ViewModel 中间层意味着大量 forwarding properties,边际收益低
//
// 这里提供的是 façade 形式 — ViewModel 类型存在(plan §3.1 承诺),暴露派生属性
// 入口让 unit-test 或未来 UI 重写有 stable API,但底层仍然通过 engine 提供数据。
// 这不强制 UI 层去用 — ContentView/ConfigurationsView 维持现状不动。

// MARK: - ChatViewModel

/// 聊天界面派生数据的逻辑分组。façade 形式 — 持有 engine,转发派生属性。
@MainActor
@Observable
final class ChatViewModel {

    /// 持有 engine 引用。unowned 因为 ChatViewModel 生命周期短于 engine。
    private unowned let engine: AgentEngine

    init(engine: AgentEngine) {
        self.engine = engine
    }

    // MARK: - Observable state (forwarded)

    var messages: [ChatMessage] { engine.messages }
    var isProcessing: Bool { engine.isProcessing }
    var isModelReady: Bool { engine.isModelReady }
    var isModelGenerating: Bool { engine.isModelGenerating }

    // MARK: - Derived data

    /// 当前会话是否为空(用于显示 empty state 引导)。
    var isEmptySession: Bool { engine.messages.isEmpty }

    /// 最后一条消息(用于 scroll-to-bottom 触发器)。
    var lastMessage: ChatMessage? { engine.messages.last }

    /// 是否可以重试上一轮(只有最后一条是 user 消息且无 audio 时)。
    var canRetry: Bool {
        guard !engine.isProcessing, engine.isModelReady else { return false }
        guard let lastUser = engine.messages.last(where: { $0.role == .user }) else { return false }
        return lastUser.audios.isEmpty
    }

    // MARK: - Actions

    func send(_ text: String, images: [PlatformImage] = [], audio: AudioCaptureSnapshot? = nil) async {
        await engine.processInput(text, images: images, audio: audio)
    }

    func cancel() {
        engine.cancelActiveGeneration()
    }

    func retry() async {
        await engine.retryLastResponse()
    }

    func newSession() {
        engine.startNewSession()
    }
}

// MARK: - ConfigViewModel

/// 配置/模型管理界面的逻辑分组。façade 形式。
@MainActor
@Observable
final class ConfigViewModel {

    private unowned let engine: AgentEngine

    init(engine: AgentEngine) {
        self.engine = engine
    }

    // MARK: - Observable state

    var availableModels: [ModelDescriptor] { engine.availableModels }
    var isModelReady: Bool { engine.isModelReady }
    var sessionState: RuntimeSessionState { engine.coordinator.sessionState }

    // MARK: - Install state queries

    func installState(for modelID: String) -> ModelInstallState {
        engine.installer.installState(for: modelID)
    }

    func downloadProgress(for modelID: String) -> DownloadProgress? {
        engine.installer.downloadProgress[modelID]
    }

    // MARK: - Actions

    func install(_ model: ModelDescriptor) async throws {
        try await engine.installer.install(model: model)
    }

    func cancelInstall(modelID: String) {
        engine.installer.cancelInstall(modelID: modelID)
    }

    func remove(_ model: ModelDescriptor) throws {
        try engine.installer.remove(model: model)
    }

    func reloadModel() {
        engine.reloadModel()
    }

    func exportDiagnostics() -> DiagnosticsBundle {
        PCLog.exportDiagnosticsBundle()
    }
}
