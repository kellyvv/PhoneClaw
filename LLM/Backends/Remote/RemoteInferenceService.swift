import Foundation
import CoreImage

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Remote Inference Service (P0)
//
// 第 4 个推理 backend：把推理甩给局域网内 Mac 上的 OpenAI 兼容网关。
// P0 直连「裸 Ollama」(手填地址) 验证整条链路；之后 Mac 端换成自研网关，本类基本不动。
//
// 对产品层完全透明 —— 跟 LiteRT / MiniCPM-V 一样实现 InferenceService，
// AgentEngine / UI 不知道 token 是手机本地算的还是 Mac 算的。
//
// 为什么本类这么薄 (契约决定，见 InferenceService.swift / BackendDispatcher.swift)：
//   1. generate(prompt:) 收到「已渲染好的完整 prompt 字符串」(PromptBuilder 出的
//      Gemma 4 <|turn> 模板)，不是 messages、也不带 tools。
//   2. 工具调用是「文本协议」：模型吐 <tool_call>…</tool_call> 纯文本，AgentEngine
//      在 token 流上解析 + 手机本地执行 + 拼进下一轮 prompt。
//   ⇒ 远程 backend 只干一件事：prompt → PromptRuntimeProfile → ChatCompletions messages → POST 给 Mac →
//      把回来的 SSE 文本流逐块 yield。agent 循环 / 工具 / 多轮编排全留在 AgentEngine。
//
// Gemma 模板 → messages：复用 PromptRuntimeProfile 的结构化 transcript，让 Foundation
//   Models / Remote ChatCompletions 走同一套 role 解析，而不是各自维护 parser。
//
// P0 取舍 (明确标记，P1 收敛)：
//   - 端点 /v1/chat/completions + stream；SSE 逐行解析 choices[].delta.content。
//   - 图片/音频：generateMultimodal 暂走纯文本 (忽略媒体 + 日志)，P1 接 vision content。
//   - Live：generateLive / enterLiveMode 暂不支持 (空流 / no-op)。
//   - 端点配置从 UserDefaults 读 (手填)，throwaway —— P2 被「自动发现 + 配对绑定」取代，
//     故意不进 ModelConfig，不污染正式配置层。

@Observable
final class RemoteInferenceService: InferenceService {

    // MARK: - Endpoint Config (P0 throwaway)

    static let endpointDefaultsKey = "PhoneClaw.remote.endpointURL"  // e.g. http://192.168.1.10:11434/v1
    static let modelNameDefaultsKey = "PhoneClaw.remote.modelName"   // e.g. gemma2:9b (Ollama tag)

    /// OpenAI 兼容网关 base (内部拼 /chat/completions、/models)。nil = 未配置。
    var baseURL: URL?
    /// 发给网关的 `model` 字段 (Ollama tag)，跟手机侧 descriptor.id 解耦。
    var remoteModelName: String
    /// 配对握手拿到的 token;非 nil 时所有请求带 `Authorization: Bearer`。
    var authToken: String?
    /// 注入的端点解析器: 给 modelID 返回 (绑定解析出的 url, token, 远程模型名)。
    /// AgentEngine 用它把"选中的远程模型"映射到对应 Mac;nil 则回退 UserDefaults (P0)。
    @ObservationIgnored var endpointResolver: (@Sendable (String) async -> (url: URL, token: String?, modelName: String)?)?

    // MARK: - Observable State

    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var statusMessage = ""
    private(set) var stats = InferenceStats()

    // MARK: - Sampling

    var samplingTopK = 64
    var samplingTopP: Float = 0.95
    var samplingTemperature: Float = 1.0
    var maxOutputTokens = 1024

    // MARK: - Internals

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    private static let defaultRemoteContextBudgetTokens = 8192

    // MARK: - Init

    init(
        baseURL: URL? = RemoteInferenceService.storedEndpoint(),
        remoteModelName: String = RemoteInferenceService.storedModelName(),
        authToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.remoteModelName = remoteModelName
        self.authToken = authToken
        let cfg = URLSessionConfiguration.ephemeral
        // 这是"多久没收到新数据就超时"。对流式 LLM,危险窗口在**首 token 之前**:
        // 大模型(12B/云端 120B)prefill 一段长 prompt(agent 的总结/工具回合 prompt 可达数千字)
        // 再吐第一个 token,常 >30s。卡这里会让长 prompt 轮整轮无输出(本机 LiteRT 无此闸)。
        // 放宽到 180s 容忍 TTFT;开始流式后 token 间隔很小,不会误伤。整体仍有 resource 600s 兜底。
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        self.stats.backend = "remote"
    }

    static func storedEndpoint() -> URL? {
        guard let s = UserDefaults.standard.string(forKey: endpointDefaultsKey),
              !s.isEmpty, let u = URL(string: s) else { return nil }
        return u
    }

    static func storedModelName() -> String {
        UserDefaults.standard.string(forKey: modelNameDefaultsKey) ?? ""
    }

    // MARK: - Lifecycle

    /// 远程模型没有「加载」概念 —— 刷新配置 + 确认网关可达即视为已加载。
    func load(modelID: String) async throws {
        isLoading = true
        defer { isLoading = false }

        // P0：用户可能刚在设置里改了地址 / 模型名，每次 load 重新取。
        // 优先用注入的 resolver (从绑定解析 endpoint/token/model);否则回退 UserDefaults (P0)。
        if let resolver = endpointResolver, let r = await resolver(modelID) {
            baseURL = r.url
            authToken = r.token
            remoteModelName = r.modelName
        } else {
            baseURL = RemoteInferenceService.storedEndpoint() ?? baseURL
            if remoteModelName.isEmpty {
                remoteModelName = RemoteInferenceService.storedModelName()
            }
        }
        guard let baseURL else {
            throw RemoteInferenceError.notConfigured
        }
        statusMessage = tr("正在连接 Mac · \(remoteModelName)", "Connecting to Mac · \(remoteModelName)", "Mac に接続中 · \(remoteModelName)")
        try await pingReachable(baseURL)
        try await prepareRemoteModelIfSupported(baseURL)
        isLoaded = true
        statusMessage = tr("已连接 Mac · \(remoteModelName)", "Connected to Mac · \(remoteModelName)", "Mac に接続済み · \(remoteModelName)")
        PCLog.debug("[Remote] loaded \(baseURL.absoluteString) model=\(remoteModelName)")
    }

    func unload() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.streamTask?.cancel()
            self.streamTask = nil
            self.isGenerating = false
            self.isLoaded = false
            self.statusMessage = ""
        }
    }

    func cancel() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.streamTask?.cancel()
            self.streamTask = nil
            self.isGenerating = false
        }
    }

    // Live：P0 不支持远程 Live。enter / exit 走 no-op (不抛，免得切模型时炸)。
    func enterLiveMode(systemPrompt: String?) async throws { /* P0: no-op */ }
    func exitLiveMode() async { /* P0: no-op */ }

    // MARK: - Generation

    func generate(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamChat(messages: Self.chatCompletionMessages(
            from: prompt,
            maxInputTokens: maxInputTokensForCurrentRequest()
        ))
    }

    func generateRaw(text: String, images: [CIImage]) -> AsyncThrowingStream<String, Error> {
        if !images.isEmpty {
            PCLog.debug("[Remote] generateRaw: \(images.count) image(s) ignored (P0 text-only)")
        }
        return streamChat(messages: Self.chatCompletionMessages(
            from: text,
            maxInputTokens: maxInputTokensForCurrentRequest()
        ))
    }

    func generateMultimodal(
        images: [CIImage],
        audios: [AudioInput],
        prompt: String,
        systemPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        // P0：忽略图/音，只走文本。P1 接 OpenAI vision content (base64 data URL)。
        if !images.isEmpty || !audios.isEmpty {
            PCLog.debug("[Remote] generateMultimodal: \(images.count) img / \(audios.count) audio ignored (P0 text-only)")
        }
        let profile = PromptRuntimeProfile(instructions: systemPrompt, prompt: prompt)
        return streamChat(messages: profile
            .applyingTokenBudget(maxInputTokens: maxInputTokensForCurrentRequest())
            .chatCompletionMessages()
            .map(\.dictionary))
    }

    func generateLive(
        prompt: String,
        images: [CIImage],
        audios: [AudioInput]
    ) -> AsyncThrowingStream<String, Error> {
        // P0：远程 Live 未支持 —— 返回空流 (立即 finish)，不让上层卡住。
        AsyncThrowingStream { $0.finish() }
    }

    // MARK: - Streaming Core

    private func streamChat(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                guard let baseURL = self.baseURL else {
                    continuation.finish(throwing: RemoteInferenceError.notConfigured)
                    return
                }

                self.isGenerating = true
                let startTime = CFAbsoluteTimeGetCurrent()
                var ttftMs: Double?
                var chunkCount = 0

                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let token = self.authToken {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let body: [String: Any] = [
                        "model": self.remoteModelName,
                        "messages": messages,
                        "stream": true,
                        "temperature": Double(self.samplingTemperature),
                        "top_p": Double(self.samplingTopP),
                        "max_tokens": self.maxOutputTokens,
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw RemoteInferenceError.unreachable
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw RemoteInferenceError.httpStatus(http.statusCode)
                    }

                    // SSE：每行 "data: {json}"，[DONE] 收尾。只取 choices[0].delta.content。
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else { continue }
                        if ttftMs == nil { ttftMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000 }
                        chunkCount += 1
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                // 收尾：perf 埋点 + 状态复位 (都在 main)。
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.isGenerating = false
                self.stats.ttftMs = ttftMs ?? 0
                self.stats.totalChunks = chunkCount
                self.stats.chunksPerSec = (elapsed > 0 && chunkCount > 0) ? Double(chunkCount) / elapsed : 0
            }
            // streamTask 仅在 main 上读写 (cancel/unload 也 hop 到 main)，避免数据竞争。
            Task { @MainActor [weak self] in self?.streamTask = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reachability

    private func pingReachable(_ base: URL) async throws {
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.timeoutInterval = 6
        if let authToken { req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await session.data(for: req)
            // 2xx 理想；4xx 也算「连得上」(可能 /models 需要 auth)，真正生成时再暴露。
            guard let http = response as? HTTPURLResponse, http.statusCode < 500 else {
                throw RemoteInferenceError.unreachable
            }
        } catch let e as RemoteInferenceError {
            throw e
        } catch {
            throw RemoteInferenceError.unreachable
        }
    }

    private func prepareRemoteModelIfSupported(_ base: URL) async throws {
        let cleanModel = remoteModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { return }

        statusMessage = tr("正在请求 Mac 加载模型 · \(cleanModel)", "Asking Mac to load · \(cleanModel)", "Mac にモデル読込を要求中 · \(cleanModel)")

        var req = URLRequest(url: base
            .appendingPathComponent("model")
            .appendingPathComponent("prepare"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken { req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": cleanModel])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteInferenceError.unreachable
            }
            switch http.statusCode {
            case 200..<300:
                let status = Self.prepareStatus(from: data)
                if status == "loaded" {
                    statusMessage = tr("Mac 已加载模型 · \(cleanModel)", "Mac loaded · \(cleanModel)", "Mac が読込済み · \(cleanModel)")
                } else {
                    PCLog.debug("[Remote] prepare \(cleanModel) status=\(status ?? "unknown")")
                }
            case 404, 405:
                // 兼容旧的手填 OpenAI-compatible endpoint:没有 PhoneClaw prepare 端点也能继续使用。
                PCLog.debug("[Remote] prepare endpoint unavailable (\(http.statusCode)); continuing without preload")
            default:
                throw RemoteInferenceError.httpStatus(http.statusCode)
            }
        } catch let e as RemoteInferenceError {
            throw e
        } catch {
            throw RemoteInferenceError.unreachable
        }
    }

    private static func prepareStatus(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
    }

    // MARK: - Prompt profile → OpenAI messages
    //
    // `PromptRuntimeProfile` is the compatibility bridge shared with the iOS 27
    // Foundation Models adapter. Remote keeps native tool calling disabled at the
    // gateway boundary; PhoneClaw's text tool protocol still drives execution.
    private func maxInputTokensForCurrentRequest() -> Int {
        max(512, Self.defaultRemoteContextBudgetTokens - max(256, maxOutputTokens))
    }

    static func chatCompletionMessages(
        from prompt: String,
        maxInputTokens: Int? = nil
    ) -> [[String: String]] {
        let profile = PromptRuntimeProfile.fromGemmaPrompt(
            prompt,
            includeSystemTurnsInPrompt: false
        )
        let boundedProfile = maxInputTokens.map {
            profile.applyingTokenBudget(maxInputTokens: $0)
        } ?? profile

        return boundedProfile
            .chatCompletionMessages()
            .map(\.dictionary)
    }
}

// MARK: - Errors

enum RemoteInferenceError: LocalizedError {
    case notConfigured
    case unreachable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return tr("未配置 Mac 推理地址，请在设置里填写。",
                      "Mac inference endpoint not configured. Set it in Settings.",
                      "Mac 推論のアドレスが未設定です。設定で入力してください。")
        case .unreachable:
            return tr("连不上 Mac 推理服务，确认在同一局域网且服务已开启。",
                      "Can't reach the Mac inference service — check you're on the same LAN and it's running.",
                      "Mac 推論サービスに接続できません。同じLANにいて、サービスが起動しているか確認してください。")
        case .httpStatus(let code):
            return tr("Mac 推理返回错误 (HTTP \(code))。",
                      "Mac inference returned an error (HTTP \(code)).",
                      "Mac 推論がエラーを返しました (HTTP \(code))。")
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
struct ChatCompletionsLanguageModel: LanguageModel, Sendable {
    typealias Executor = ChatCompletionsLanguageModelExecutor

    let baseURL: URL
    let modelName: String
    let authToken: String?

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [])
    }

    var executorConfiguration: ChatCompletionsLanguageModelExecutor.Configuration {
        ChatCompletionsLanguageModelExecutor.Configuration(
            baseURL: baseURL,
            modelName: modelName,
            authToken: authToken
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct ChatCompletionsLanguageModelExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        let baseURL: URL
        let modelName: String
        let authToken: String?
    }

    typealias Model = ChatCompletionsLanguageModel

    let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func prewarm(model: ChatCompletionsLanguageModel, transcript: Transcript) {
        // Remote OpenAI-compatible gateways have no local cache to prewarm.
    }

    nonisolated func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ChatCompletionsLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var urlRequest = URLRequest(url: model.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let authToken = model.authToken {
            urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let messages = Self.chatCompletionMessages(from: request.transcript)
        let body: [String: Any] = [
            "model": model.modelName,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": request.generationOptions.temperature ?? 1.0,
            "max_tokens": request.generationOptions.maximumResponseTokens ?? 1024
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ChatCompletionsLanguageModelError.httpStatus(code)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let usage = json["usage"] as? [String: Any] {
                await channel.send(.response(action: .updateUsage(
                    input: .init(
                        totalTokenCount: usage["prompt_tokens"] as? Int ?? 0,
                        cachedTokenCount: 0
                    ),
                    output: .init(
                        totalTokenCount: usage["completion_tokens"] as? Int ?? 0,
                        reasoningTokenCount: 0
                    )
                )))
                continue
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty else {
                continue
            }
            await channel.send(.response(action: .appendText(
                content,
                tokenCount: PromptTokenEstimator.estimate(content)
            )))
        }
    }

    private static func chatCompletionMessages(from transcript: Transcript) -> [[String: String]] {
        var messages: [[String: String]] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                appendMessage(role: "system", segments: instructions.segments, to: &messages)
            case .prompt(let prompt):
                appendMessage(role: "user", segments: prompt.segments, to: &messages)
            case .response(let response):
                appendMessage(role: "assistant", segments: response.segments, to: &messages)
            case .toolOutput(let output):
                appendMessage(role: "user", segments: output.segments, to: &messages)
            case .toolCalls(let calls):
                let content = calls.map { call in
                    RuntimeToolCall(
                        name: call.toolName,
                        arguments: FoundationModelsGeneratedContentBridge.dictionary(from: call.arguments),
                        source: .nativeToolCall,
                        callID: call.id,
                        rawPayload: call.arguments.jsonString
                    ).textProtocolEnvelope
                }.joined(separator: "\n")
                appendMessage(role: "assistant", content: content, to: &messages)
            case .reasoning:
                continue
            @unknown default:
                continue
            }
        }
        return messages.isEmpty ? [["role": "user", "content": ""]] : messages
    }

    private static func appendMessage(
        role: String,
        segments: [Transcript.Segment],
        to messages: inout [[String: String]]
    ) {
        let content = segments.map(segmentText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        appendMessage(role: role, content: content, to: &messages)
    }

    private static func appendMessage(
        role: String,
        content: String,
        to messages: inout [[String: String]]
    ) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(["role": role, "content": content])
    }

    private static func segmentText(_ segment: Transcript.Segment) -> String {
        switch segment {
        case .text(let text):
            return text.content
        case .structure(let structure):
            return structure.content.jsonString
        case .attachment(let attachment):
            return attachment.description
        case .custom(let custom):
            return custom.description
        @unknown default:
            return segment.description
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
private enum FoundationModelsGeneratedContentBridge {
    static func dictionary(from content: GeneratedContent) -> [String: Any] {
        guard let data = content.jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

enum ChatCompletionsLanguageModelError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Chat Completions gateway returned HTTP \(code)."
        }
    }
}
#endif
