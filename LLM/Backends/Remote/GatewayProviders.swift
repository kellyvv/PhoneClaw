import Foundation

// MARK: - Gateway Providers (② 多 provider 路由)
//
// 网关把多个 provider (Ollama / Codex CLI / LM Studio …) 聚合成统一 OpenAI 接口:
//   - /v1/models 汇总各 provider 的模型 (id 加 "provider/" 前缀去歧义)
//   - /v1/chat/completions 按 model 前缀路由到对应 provider
//
// 现实现 OpenAICompatibleProvider (Ollama / OpenAI / LM Studio / LiteLLM / vLLM 等)
// + EchoProvider (占位, 证明非 HTTP provider 也能被路由)。Codex CLI 这类进程型 provider
// 以后实现同一协议 (spawn 进程 + 包成 SSE)。

protocol GatewayProvider: Sendable {
    var id: String { get }
    /// Provider health and model inventory for UI diagnostics and preflight.
    func health() async -> GatewayProviderHealth
    /// 该 provider 提供的 model id (裸名, 不带 provider 前缀)。
    func listModels() async -> [String]
    /// 该 provider 提供的模型信息;displayName 用于客户端展示,不参与路由。
    func listModelInfo() async -> [GatewayModelInfo]
    /// 处理一次 chat completion。model 是去掉前缀的裸名;body 已改写;逐行 yield SSE。
    func chat(model: String, body: Data, yield: @Sendable @escaping (String) -> Void) async throws
    /// 选择模型时的预备动作。Ollama 本地模型用它触发加载;云端/API/CLI provider 默认 no-op。
    func prepare(model: String) async throws -> GatewayModelPrepareResult
}

extension GatewayProvider {
    func listModels() async -> [String] {
        await health().models
    }

    func listModelInfo() async -> [GatewayModelInfo] {
        let models = await listModels()
        return models.map { GatewayModelInfo(id: $0, displayName: nil) }
    }

    func prepare(model: String) async throws -> GatewayModelPrepareResult {
        GatewayModelPrepareResult(
            status: "noop",
            detail: "Provider does not require explicit model loading.",
            loaded: false
        )
    }
}

struct GatewayProviderHealth: Sendable {
    let reachable: Bool
    let models: [String]
    let detail: String?
}

struct GatewayModelInfo: Sendable {
    let id: String
    let displayName: String?
}

enum AntigravityModelCatalog {
    static let models: [GatewayModelInfo] = [
        GatewayModelInfo(id: "Gemini 3.5 Flash (Medium)", displayName: "Gemini 3.5 Flash (Medium)"),
        GatewayModelInfo(id: "Gemini 3.5 Flash (High)", displayName: "Gemini 3.5 Flash (High)"),
        GatewayModelInfo(id: "Gemini 3.5 Flash (Low)", displayName: "Gemini 3.5 Flash (Low)"),
        GatewayModelInfo(id: "Gemini 3.1 Pro (Low)", displayName: "Gemini 3.1 Pro (Low)"),
        GatewayModelInfo(id: "Gemini 3.1 Pro (High)", displayName: "Gemini 3.1 Pro (High)"),
        GatewayModelInfo(id: "Claude Sonnet 4.6 (Thinking)", displayName: "Claude Sonnet 4.6 (Thinking)"),
        GatewayModelInfo(id: "Claude Opus 4.6 (Thinking)", displayName: "Claude Opus 4.6 (Thinking)"),
        GatewayModelInfo(id: "GPT-OSS 120B (Medium)", displayName: "GPT-OSS 120B (Medium)"),
    ]
}

struct GatewayModelPrepareResult: Sendable {
    let status: String
    let detail: String?
    let loaded: Bool
}

enum GatewayProviderError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpStatus(Int)
    case timeout
    case unsupportedCLI(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let base):
            return "Invalid provider URL: \(base)"
        case .invalidResponse:
            return "Invalid provider response"
        case .httpStatus(let status):
            return "HTTP \(status)"
        case .timeout:
            return "CLI timed out"
        case .unsupportedCLI(let message):
            return message
        }
    }
}

// MARK: - OpenAI-compatible HTTP upstream

struct OpenAICompatibleProvider: GatewayProvider {
    let id: String
    let base: String   // e.g. http://127.0.0.1:11434 or https://api.openai.com/v1
    let apiKey: String?
    let advertisedModels: [String]
    let extraHeaders: [String: String]
    let restrictToAdvertisedModels: Bool
    let supportsOllamaTags: Bool

    init(
        id: String,
        base: String,
        apiKey: String? = nil,
        advertisedModels: [String] = [],
        extraHeaders: [String: String] = [:],
        restrictToAdvertisedModels: Bool = false,
        supportsOllamaTags: Bool = false
    ) {
        self.id = id
        self.base = base
        self.apiKey = apiKey
        self.advertisedModels = advertisedModels
        self.extraHeaders = extraHeaders
        self.restrictToAdvertisedModels = restrictToAdvertisedModels
        self.supportsOllamaTags = supportsOllamaTags
    }

    func health() async -> GatewayProviderHealth {
        do {
            let models = try await fetchModels()
            let visibleModels = resolveVisibleModels(from: models)
            let detail: String?
            if visibleModels.isEmpty {
                detail = restrictToAdvertisedModels && !advertisedModels.isEmpty
                    ? "Connected, but selected models were not returned."
                    : "Connected, but no models were returned."
            } else {
                detail = nil
            }
            return GatewayProviderHealth(reachable: true, models: visibleModels, detail: detail)
        } catch {
            if !advertisedModels.isEmpty && !restrictToAdvertisedModels {
                return GatewayProviderHealth(
                    reachable: true,
                    models: advertisedModels,
                    detail: "Using configured models; model listing unavailable: \(error.localizedDescription)"
                )
            }
            return GatewayProviderHealth(reachable: false, models: [], detail: error.localizedDescription)
        }
    }

    func chat(model: String, body: Data, yield: @Sendable @escaping (String) -> Void) async throws {
        guard let url = endpointURL("chat/completions") else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders where !value.isEmpty {
            r.setValue(value, forHTTPHeaderField: key)
        }
        r.httpBody = body
        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayProviderError.httpStatus(http.statusCode)
        }
        for try await line in bytes.lines { yield(line + "\n") }
    }

    func prepare(model: String) async throws -> GatewayModelPrepareResult {
        guard supportsOllamaTags else {
            return GatewayModelPrepareResult(
                status: "noop",
                detail: "OpenAI-compatible provider does not require explicit model loading.",
                loaded: false
            )
        }

        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else {
            throw GatewayProviderError.unsupportedCLI("Missing model")
        }

        let tags = try await fetchOllamaTagItems()
        guard let tag = Self.ollamaTag(named: cleanModel, in: tags) else {
            if Self.isCloudOllamaModelName(cleanModel) {
                return GatewayModelPrepareResult(
                    status: "skipped_cloud",
                    detail: "Ollama cloud model does not require local loading.",
                    loaded: false
                )
            }
            throw GatewayProviderError.unsupportedCLI("Ollama model \(cleanModel) was not returned by /api/tags.")
        }

        if Self.isCloudOllamaTag(tag, fallbackName: cleanModel) {
            return GatewayModelPrepareResult(
                status: "skipped_cloud",
                detail: "Ollama cloud model does not require local loading.",
                loaded: false
            )
        }

        try await prepareOllamaLocalModel(cleanModel)
        return GatewayModelPrepareResult(
            status: "loaded",
            detail: "Ollama local model loaded into memory.",
            loaded: true
        )
    }

    private func fetchModels() async throws -> [String] {
        do {
            return try await fetchOpenAIModels()
        } catch {
            guard supportsOllamaTags else { throw error }
            return try await fetchOllamaTagModels()
        }
    }

    private func fetchOpenAIModels() async throws -> [String] {
        guard let url = endpointURL("models") else {
            throw GatewayProviderError.invalidBaseURL(base)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayProviderError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw GatewayProviderError.invalidResponse
        }
        return arr.compactMap { $0["id"] as? String }
    }

    private func fetchOllamaTagModels() async throws -> [String] {
        try await fetchOllamaTagItems().compactMap(Self.ollamaTagName)
    }

    private func fetchOllamaTagItems() async throws -> [[String: Any]] {
        guard let url = rootEndpointURL("api/tags") else {
            throw GatewayProviderError.invalidBaseURL(base)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayProviderError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["models"] as? [[String: Any]] else {
            throw GatewayProviderError.invalidResponse
        }
        return arr
    }

    private func prepareOllamaLocalModel(_ model: String) async throws {
        guard let url = rootEndpointURL("api/generate") else {
            throw GatewayProviderError.invalidBaseURL(base)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": "",
            "stream": false,
            "keep_alive": "30m",
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayProviderError.httpStatus(http.statusCode)
        }
    }

    private static func ollamaTagName(_ item: [String: Any]) -> String? {
        ((item["name"] as? String) ?? (item["model"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ollamaTag(named model: String, in tags: [[String: Any]]) -> [String: Any]? {
        tags.first { item in
            guard let name = ollamaTagName(item) else { return false }
            return name == model
        }
    }

    private static func isCloudOllamaTag(_ item: [String: Any], fallbackName: String) -> Bool {
        item["remote_host"] != nil
            || item["remote_model"] != nil
            || isCloudOllamaModelName(ollamaTagName(item) ?? fallbackName)
    }

    private static func isCloudOllamaModelName(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("-cloud") || lower.hasSuffix(":cloud")
    }

    private func resolveVisibleModels(from fetchedModels: [String]) -> [String] {
        guard restrictToAdvertisedModels else {
            return mergeModels(fetchedModels, advertisedModels)
        }
        let selected = cleanUniqueModels(advertisedModels)
        guard !selected.isEmpty else {
            return cleanUniqueModels(fetchedModels)
        }
        let fetchedSet = Set(cleanUniqueModels(fetchedModels))
        return selected.filter { fetchedSet.contains($0) }
    }

    private func endpointURL(_ endpoint: String) -> URL? {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == "v1" || path.hasSuffix("/v1") {
            components.path = "/" + [path, cleanEndpoint].joined(separator: "/")
        } else {
            components.path = "/" + [path, "v1", cleanEndpoint].filter { !$0.isEmpty }.joined(separator: "/")
        }
        return components.url
    }

    private func rootEndpointURL(_ endpoint: String) -> URL? {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        var pathParts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        if pathParts.last?.lowercased() == "v1" {
            pathParts.removeLast()
        }
        pathParts.append(contentsOf: endpoint
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty })
        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }
}

/// Backward-compatible name for existing CLI harness code.
typealias OllamaProvider = OpenAICompatibleProvider

private func mergeModels(_ primary: [String], _ fallback: [String]) -> [String] {
    cleanUniqueModels(primary + fallback)
}

private func cleanUniqueModels(_ models: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for model in models {
        let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
        result.append(clean)
    }
    return result
}

// MARK: - Echo (占位 provider, 证明路由到非 Ollama)

enum LocalCLIMode: Sendable, Equatable {
    case codex
    case antigravity

    var modelName: String {
        switch self {
        case .codex: return "codex"
        case .antigravity: return "antigravity"
        }
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity CLI"
        }
    }

    func arguments(prompt: String) throws -> [String] {
        switch self {
        case .codex:
            return ["exec", "--skip-git-repo-check", "--sandbox", "read-only", prompt]
        case .antigravity:
            return ["--prompt", prompt]
        }
    }
}

struct LocalCLIProvider: GatewayProvider {
    let id: String
    let command: String
    let mode: LocalCLIMode
    let advertisedModels: [String]

    func health() async -> GatewayProviderHealth {
        guard let resolved = Self.resolveExecutable(command) else {
            return GatewayProviderHealth(
                reachable: false,
                models: [],
                detail: "未找到 \(mode.displayName)"
            )
        }
        return GatewayProviderHealth(reachable: true, models: modelsForHealth, detail: resolved)
    }

    func listModelInfo() async -> [GatewayModelInfo] {
        modelInfoForHealth
    }

    func chat(model: String, body: Data, yield: @Sendable @escaping (String) -> Void) async throws {
        guard let resolved = Self.resolveExecutable(command) else {
            throw GatewayProviderError.unsupportedCLI("\(mode.displayName) command not found.")
        }
        let prompt = GatewayBody.lastUserContent(body) ?? ""
        switch mode {
        case .codex:
            let output = try Self.runCodexStreaming(resolved, prompt: prompt, model: model) { chunk in
                sendSSEDelta(chunk, yield: yield)
            }
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GatewayProviderError.unsupportedCLI("Codex CLI returned no output.")
            }
            yield("data: [DONE]\n")
            yield("\n")
        case .antigravity:
            let output = try Self.runAntigravity(
                resolved,
                prompt: prompt,
                model: model
            )
            sendSSE(output.trimmingCharacters(in: .whitespacesAndNewlines), yield: yield)
        }
    }

    private var modelsForHealth: [String] {
        modelInfoForHealth.map(\.id)
    }

    private var modelInfoForHealth: [GatewayModelInfo] {
        let clean = advertisedModels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !clean.isEmpty {
            return clean.map { GatewayModelInfo(id: $0, displayName: nil) }
        }
        switch mode {
        case .codex:
            let cached = Self.codexModelCache()
            if !cached.isEmpty { return cached }
            if let configured = Self.codexConfiguredModelName() {
                return [GatewayModelInfo(id: configured, displayName: nil)]
            }
            return []
        case .antigravity:
            return AntigravityModelCatalog.models
        }
    }

    private struct CodexModelsCache: Decodable {
        let models: [CodexModelEntry]
    }

    private struct CodexModelEntry: Decodable {
        let slug: String
        let displayName: String?
        let visibility: String?
        let priority: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case visibility
            case priority
        }
    }

    private static func codexModelCache() -> [GatewayModelInfo] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data) else {
            return []
        }
        return cache.models
            .filter { ($0.visibility ?? "list") == "list" }
            .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
            .map { GatewayModelInfo(id: $0.slug, displayName: $0.displayName) }
    }

    private static func codexConfiguredModelName() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("model ") || line.hasPrefix("model=") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func resolveExecutable(_ command: String) -> String? {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if clean.contains("/") {
            return FileManager.default.isExecutableFile(atPath: clean) ? clean : nil
        }
        if clean == "codex" {
            for candidate in fallbackExecutablePaths(for: clean) {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        if let shellPath = try? runExecutable("/bin/zsh", arguments: ["-lc", "command -v \(shellQuote(clean))"], timeout: 2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init),
           FileManager.default.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        for candidate in fallbackExecutablePaths(for: clean) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func fallbackExecutablePaths(for command: String) -> [String] {
        var paths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(NSHomeDirectory())/.local/bin/\(command)",
        ]
        if command == "codex" {
            paths.append(contentsOf: codexExecutablePathsFromNVM())
        }
        if command == "agy" {
            paths.append("\(NSHomeDirectory())/.local/bin/agy")
        }
        return paths
    }

    private static func codexExecutablePathsFromNVM() -> [String] {
        let versionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".nvm/versions/node")
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versions
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .flatMap { codexExecutablePaths(for: $0) }
    }

    private static func codexExecutablePaths(for nodeVersionURL: URL) -> [String] {
        [
            nodeVersionURL.appendingPathComponent("lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex").path,
            nodeVersionURL.appendingPathComponent("bin/codex").path,
        ]
    }

    private static func runCodex(_ path: String, prompt: String, model: String) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneclaw-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--cd", "/private/tmp",
            "--color", "never",
            "--output-last-message", outputURL.path,
        ]
        if !cleanModel.isEmpty, cleanModel != "codex" {
            arguments += ["--model", cleanModel]
        }
        arguments.append(prompt)

        let stdout = try runExecutable(
            path,
            arguments: arguments,
            timeout: 300
        )

        let final = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !final.isEmpty {
            return final
        }
        let cleanedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedStdout.isEmpty else {
            throw GatewayProviderError.unsupportedCLI("Codex CLI returned no output.")
        }
        return cleanedStdout
    }

    private static func runCodexStreaming(
        _ path: String,
        prompt: String,
        model: String,
        onText: @Sendable @escaping (String) -> Void
    ) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneclaw-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--cd", "/private/tmp",
            "--color", "never",
            "--output-last-message", outputURL.path,
        ]
        if !cleanModel.isEmpty, cleanModel != "codex" {
            arguments += ["--model", cleanModel]
        }
        arguments.append(prompt)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lock = NSLock()
        var lineBuffer = ""
        var capturedOutput = ""
        var capturedError = ""
        var emittedText = ""
        var finalText = ""

        func consumeStdout(_ text: String) -> [String] {
            lock.lock()
            capturedOutput += text
            lineBuffer += text
            let parts = lineBuffer.components(separatedBy: .newlines)
            lineBuffer = parts.last ?? ""
            var chunks: [String] = []
            for line in parts.dropLast() {
                chunks += parseCodexJSONLine(line, emittedText: &emittedText, finalText: &finalText)
            }
            lock.unlock()
            return chunks
        }

        func consumeRemainingStdout() -> [String] {
            lock.lock()
            let remaining = lineBuffer
            lineBuffer = ""
            var chunks: [String] = []
            if !remaining.isEmpty {
                chunks += parseCodexJSONLine(remaining, emittedText: &emittedText, finalText: &finalText)
            }
            lock.unlock()
            return chunks
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for chunk in consumeStdout(text) where !chunk.isEmpty {
                onText(chunk)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            capturedError += text
            lock.unlock()
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()

        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw GatewayProviderError.timeout
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        for chunk in consumeRemainingStdout() where !chunk.isEmpty {
            onText(chunk)
        }

        lock.lock()
        let stderr = capturedError
        let parsedFinal = finalText
        let parsedEmitted = emittedText
        lock.unlock()

        guard process.terminationStatus == 0 else {
            throw GatewayProviderError.unsupportedCLI(stderr.isEmpty ? "CLI exited with \(process.terminationStatus)." : stderr)
        }

        let fileFinal = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedFinal = fileFinal.isEmpty ? parsedFinal.trimmingCharacters(in: .whitespacesAndNewlines) : fileFinal
        if !resolvedFinal.isEmpty {
            if parsedEmitted.isEmpty {
                onText(resolvedFinal)
            } else if resolvedFinal.hasPrefix(parsedEmitted) {
                let suffix = String(resolvedFinal.dropFirst(parsedEmitted.count))
                if !suffix.isEmpty { onText(suffix) }
            }
            return resolvedFinal
        }

        let diagnostic = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if diagnostic.isEmpty {
            throw GatewayProviderError.unsupportedCLI("Codex CLI returned no final message.")
        }
        throw GatewayProviderError.unsupportedCLI(diagnostic)
    }

    private static func runAntigravity(_ path: String, prompt: String, model: String) throws -> String {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelArgs = (!cleanModel.isEmpty && cleanModel != "antigravity") ? ["--model", cleanModel] : []
        let baseAttempts = [
            ["--prompt", prompt],
            ["-p", prompt],
            ["--print", prompt],
        ]
        let attempts = modelArgs.isEmpty
            ? baseAttempts
            : baseAttempts.map { modelArgs + $0 } + baseAttempts

        var diagnostics: [String] = []
        for arguments in attempts {
            do {
                let output = try runExecutable(path, arguments: arguments, timeout: 300)
                let cleaned = cleanCLIOutput(output)
                if !cleaned.isEmpty {
                    return cleaned
                }
                diagnostics.append("agy \(arguments.joined(separator: " ")) returned no output")
            } catch {
                diagnostics.append(error.localizedDescription)
            }
        }

        throw GatewayProviderError.unsupportedCLI(
            diagnostics.last ?? "Antigravity CLI returned no output."
        )
    }

    private static func parseCodexJSONLine(
        _ line: String,
        emittedText: inout String,
        finalText: inout String
    ) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var chunks: [String] = []
        if let delta = codexDeltaText(from: json), !delta.isEmpty {
            emittedText += delta
            chunks.append(delta)
        }

        guard (json["type"] as? String) == "item.completed",
              let item = json["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message",
              let text = item["text"] as? String else {
            return chunks
        }

        finalText = text
        if emittedText.isEmpty {
            emittedText = text
            chunks.append(text)
        } else if text.hasPrefix(emittedText) {
            let suffix = String(text.dropFirst(emittedText.count))
            if !suffix.isEmpty {
                emittedText += suffix
                chunks.append(suffix)
            }
        }
        return chunks
    }

    private static func codexDeltaText(from json: [String: Any]) -> String? {
        let type = (json["type"] as? String) ?? ""
        guard type.contains("delta") else { return nil }
        for key in ["delta", "text_delta", "content_delta"] {
            if let value = json[key] as? String { return value }
        }
        if let item = json["item"] as? [String: Any] {
            for key in ["delta", "text_delta", "content_delta"] {
                if let value = item[key] as? String { return value }
            }
        }
        return nil
    }

    private static func runExecutable(_ path: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputLock = NSLock()
        var outputData = Data()
        var errorData = Data()
        func append(_ data: Data, to target: inout Data) {
            guard !data.isEmpty else { return }
            outputLock.lock()
            if target.count < 1_000_000 {
                target.append(data.prefix(1_000_000 - target.count))
            }
            outputLock.unlock()
        }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            var target = Data()
            target.append(handle.availableData)
            append(target, to: &outputData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            var target = Data()
            target.append(handle.availableData)
            append(target, to: &errorData)
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw GatewayProviderError.timeout
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputLock.lock()
        let capturedOutput = outputData
        let capturedError = errorData
        outputLock.unlock()
        let output = String(data: capturedOutput, encoding: .utf8) ?? ""
        let error = String(data: capturedError, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GatewayProviderError.unsupportedCLI(error.isEmpty ? "CLI exited with \(process.terminationStatus)." : error)
        }
        return output
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanCLIOutput(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendSSE(_ text: String, yield: @Sendable @escaping (String) -> Void) {
        sendSSEDelta(text, yield: yield)
        yield("data: [DONE]\n")
        yield("\n")
    }

    private func sendSSEDelta(_ text: String, yield: @Sendable @escaping (String) -> Void) {
        guard !text.isEmpty else { return }
        let payload: [String: Any] = ["choices": [["delta": ["content": text]]]]
        yield("data: \(providerJSONString(payload))\n")
        yield("\n")
    }
}

struct EchoProvider: GatewayProvider {
    let id: String

    func health() async -> GatewayProviderHealth {
        GatewayProviderHealth(reachable: true, models: ["echo"], detail: "Local echo provider for diagnostics.")
    }

    func chat(model: String, body: Data, yield: @Sendable @escaping (String) -> Void) async throws {
        let user = GatewayBody.lastUserContent(body) ?? "(empty)"
        let reply = "echo[\(model)] ← \(user.prefix(60))"
        if let d = try? JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": reply]]]]),
           let s = String(data: d, encoding: .utf8) {
            yield("data: \(s)\n"); yield("\n")
        }
        yield("data: [DONE]\n"); yield("\n")
    }
}

private func providerJSONString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"JSON encoding failed\"}"
    }
    return string
}

// MARK: - 请求体 helpers

enum GatewayBody {
    /// 从 chat body 取 model 字段。
    static func model(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String
    }
    /// 改写 body 里的 model 为裸名 (去掉 provider 前缀)。
    static func rewriteModel(_ body: Data, to model: String) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        json["model"] = model
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }
    /// 取最后一条 user message 的 content (给 echo)。
    static func lastUserContent(_ body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let msgs = json["messages"] as? [[String: Any]] else { return nil }
        return msgs.last(where: { ($0["role"] as? String) == "user" })?["content"] as? String
    }

    /// 从 /pair body 取设备名 ({"name": "..."})。
    static func deviceName(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["name"] as? String
    }
}
