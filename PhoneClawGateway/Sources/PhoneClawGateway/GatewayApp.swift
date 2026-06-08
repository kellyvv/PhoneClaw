import SwiftUI
import AppKit
import Foundation
import Security

// MARK: - PhoneClaw Gateway (C · macOS 客户端)
//
// 常驻 Mac 客户端:跑 MacGateway(Bonjour 广播 + 多 provider 路由 + /pair 审批鉴权),
// 把本机 Ollama 等暴露给局域网内的 PhoneClaw 手机。
// UI:主窗口(状态 · Providers · 已配对设备 · 配置 · 事件) + MenuBarExtra 快捷入口。
// 网关核心 (MacGateway / GatewayProviders / LANService) 经 symlink 复用主工程同一份。

@main
struct PhoneClawGatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = GatewayModel()

    var body: some Scene {
        WindowGroup("PhoneClaw Gateway", id: "main") {
            GatewayDashboardView(model: model)
        }
        .defaultSize(width: 1280, height: 854)

        MenuBarExtra("PhoneClaw Gateway", systemImage: "antenna.radiowaves.left.and.right") {
            GatewayPopover(model: model)
        }
        .menuBarExtraStyle(.window)   // 富 SwiftUI 弹窗,而非简单菜单

        Settings {
            ProviderSettingsView(model: model)
        }
    }
}

/// 标准 Mac 客户端:保留 Dock 和主窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        GatewayAppIcon.install()
        DispatchQueue.main.async {
            GatewayAppIcon.install()
        }
    }
}

private enum GatewayAppIcon {
    static func install() {
        guard
            let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return
        }
        icon.isTemplate = false
        NSApplication.shared.applicationIconImage = icon
        let tileSize = NSApplication.shared.dockTile.size
        let side = max(tileSize.width, tileSize.height, 128)
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        NSApplication.shared.dockTile.contentView = imageView
        NSApplication.shared.dockTile.display()
    }
}

private enum GatewayWindowMetrics {
    static let designWidth: CGFloat = 1280
    static let designHeight: CGFloat = 854
    static let designSize = CGSize(width: designWidth, height: designHeight)
    static let minSize = CGSize(width: 1080, height: 720)
}

struct GatewayWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(nsView.window)
        }
    }

    final class Coordinator {
        private var configuredWindows = Set<ObjectIdentifier>()

        func configure(_ window: NSWindow?) {
            guard let window else { return }
            let id = ObjectIdentifier(window)
            guard configuredWindows.insert(id).inserted else { return }
            window.contentMinSize = GatewayWindowMetrics.minSize
            window.setContentSize(GatewayWindowMetrics.designSize)
            window.center()
        }
    }
}

// MARK: - Types

struct ProviderStatus: Identifiable {
    let id: String
    let reachable: Bool
    let modelCount: Int
    let detail: String?
}

enum ProviderCategory: String, CaseIterable, Identifiable {
    case cli
    case byok

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cli: return "CLI"
        case .byok: return "BYOK"
        }
    }

    var subtitle: String {
        switch self {
        case .cli: return "本机或自托管推理服务"
        case .byok: return "使用自己的 API Key 接入云端模型"
        }
    }

    var systemImage: String {
        switch self {
        case .cli: return "terminal"
        case .byok: return "key"
        }
    }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case codexCLI
    case antigravityCLI
    case ollama
    case openai
    case openRouter
    case deepSeek
    case miniMax
    case miMo
    case aiHubMix
    case senseAudio
    case lmStudio
    case liteLLM
    case vLLM
    case openAICompatible
    case echo

    var id: String { rawValue }

    static var catalogCases: [ProviderKind] {
        [.codexCLI, .antigravityCLI, .ollama]
    }

    static func catalogCases(in category: ProviderCategory) -> [ProviderKind] {
        catalogCases.filter { $0.category == category }
    }

    var title: String {
        switch self {
        case .codexCLI: return "Codex CLI"
        case .antigravityCLI: return "Antigravity CLI"
        case .ollama: return "Ollama"
        case .openai: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .miniMax: return "MiniMax"
        case .miMo: return "MiMo"
        case .aiHubMix: return "AIHubMix"
        case .senseAudio: return "SenseAudio"
        case .lmStudio: return "LM Studio"
        case .liteLLM: return "LiteLLM"
        case .vLLM: return "vLLM"
        case .openAICompatible: return "OpenAI 兼容"
        case .echo: return "诊断 Echo"
        }
    }

    var category: ProviderCategory {
        switch self {
        case .codexCLI, .antigravityCLI, .ollama, .lmStudio, .liteLLM, .vLLM, .echo:
            return .cli
        case .openai, .openRouter, .deepSeek, .miniMax, .miMo, .aiHubMix, .senseAudio, .openAICompatible:
            return .byok
        }
    }

    var systemImage: String {
        switch self {
        case .codexCLI: return "chevron.left.forwardslash.chevron.right"
        case .antigravityCLI: return "sparkle.magnifyingglass"
        case .ollama: return "circle.hexagongrid"
        case .openai: return "sparkles"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .deepSeek: return "waveform.path.ecg"
        case .miniMax: return "bolt.horizontal"
        case .miMo: return "m.circle"
        case .aiHubMix: return "square.grid.2x2"
        case .senseAudio: return "waveform"
        case .lmStudio: return "desktopcomputer"
        case .liteLLM: return "switch.2"
        case .vLLM: return "cpu"
        case .openAICompatible: return "globe"
        case .echo: return "wrench.and.screwdriver"
        }
    }

    var shortDescription: String {
        switch self {
        case .codexCLI: return "本机 Codex 命令"
        case .antigravityCLI: return "本机 Antigravity 命令"
        case .ollama: return "本机 Ollama 服务"
        case .openai: return "OpenAI 官方 API"
        case .openRouter: return "多模型聚合路由"
        case .deepSeek: return "DeepSeek API"
        case .miniMax: return "MiniMax API"
        case .miMo: return "小米 MiMo API"
        case .aiHubMix: return "AIHubMix 聚合"
        case .senseAudio: return "SenseAudio API"
        case .lmStudio: return "本机 LM Studio"
        case .liteLLM: return "自托管 LiteLLM"
        case .vLLM: return "自托管 vLLM"
        case .openAICompatible: return "兼容接口"
        case .echo: return "本地诊断"
        }
    }

    var defaultID: String {
        switch self {
        case .codexCLI: return "codex"
        case .antigravityCLI: return "antigravity"
        case .ollama: return "ollama"
        case .openai: return "openai"
        case .openRouter: return "openrouter"
        case .deepSeek: return "deepseek"
        case .miniMax: return "minimax"
        case .miMo: return "mimo"
        case .aiHubMix: return "aihubmix"
        case .senseAudio: return "senseaudio"
        case .lmStudio: return "lmstudio"
        case .liteLLM: return "litellm"
        case .vLLM: return "vllm"
        case .openAICompatible: return "custom"
        case .echo: return "echo"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .codexCLI: return "codex"
        case .antigravityCLI: return "agy"
        case .ollama: return "http://127.0.0.1:11434"
        case .openai: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .miniMax: return "https://api.minimaxi.com/v1"
        case .miMo: return "https://token-plan-cn.xiaomimimo.com/v1"
        case .aiHubMix: return "https://aihubmix.com/v1"
        case .senseAudio: return "https://api.senseaudio.cn"
        case .lmStudio: return "http://127.0.0.1:1234"
        case .liteLLM: return "http://127.0.0.1:4000"
        case .vLLM: return "http://127.0.0.1:8000"
        case .openAICompatible: return "https://"
        case .echo: return ""
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openai, .openRouter, .deepSeek, .miniMax, .miMo, .aiHubMix, .senseAudio: return true
        case .codexCLI, .antigravityCLI, .ollama, .lmStudio, .liteLLM, .vLLM, .openAICompatible, .echo: return false
        }
    }

    var commonlyUsesAPIKey: Bool {
        switch self {
        case .openai, .openRouter, .deepSeek, .miniMax, .miMo, .aiHubMix, .senseAudio, .liteLLM, .openAICompatible: return true
        case .codexCLI, .antigravityCLI, .ollama, .lmStudio, .vLLM, .echo: return false
        }
    }

    var isMainRuntimeSource: Bool {
        switch self {
        case .codexCLI, .antigravityCLI, .ollama: return true
        default: return false
        }
    }

    var usesCommand: Bool {
        switch self {
        case .codexCLI, .antigravityCLI: return true
        default: return false
        }
    }

    var canSelectAsRuntimeSource: Bool {
        isMainRuntimeSource
    }

    var defaultModelsText: String {
        switch self {
        case .codexCLI:
            return ""
        case .antigravityCLI:
            return ""
        case .ollama:
            return ""
        case .openai:
            return "gpt-4o-mini, gpt-4o"
        case .openRouter:
            return "anthropic/claude-3.7-sonnet, google/gemini-2.5-flash, openai/gpt-4o"
        case .deepSeek:
            return "deepseek-chat, deepseek-reasoner"
        case .miniMax:
            return "MiniMax-M2.7-highspeed, MiniMax-M2.7"
        case .miMo:
            return "mimo-v2.5-pro"
        case .aiHubMix:
            return "gpt-5.5, gpt-4o-mini, claude-sonnet-4-5, gemini-2.0-flash, deepseek-chat"
        case .senseAudio:
            return "senseaudio-s2, senseaudio-s2-flash, deepseek-v4-flash"
        case .lmStudio, .liteLLM, .vLLM, .openAICompatible:
            return ""
        case .echo:
            return "echo"
        }
    }

}

/// 用户可配置的 provider。`name` 是路由用 id;`kind/baseURL/apiKey/modelsText` 对齐 OpenDesign/OpenClaw 的 BYOK provider 模式。
struct ProviderConfig: Codable, Identifiable, Equatable {
    var uuid = UUID()
    var name: String
    var baseURL: String
    var kind: ProviderKind
    var apiKey: String
    var modelsText: String
    var enabled: Bool
    var id: UUID { uuid }

    init(
        uuid: UUID = UUID(),
        name: String,
        baseURL: String,
        kind: ProviderKind = .openAICompatible,
        apiKey: String = "",
        modelsText: String = "",
        enabled: Bool
    ) {
        self.uuid = uuid
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.apiKey = apiKey
        self.modelsText = modelsText
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case uuid, name, baseURL, kind, apiKey, modelsText, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        kind = try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? (baseURL.isEmpty ? .echo : .openAICompatible)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelsText = try c.decodeIfPresent(String.self, forKey: .modelsText) ?? ""
        enabled = try c.decode(Bool.self, forKey: .enabled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(kind, forKey: .kind)
        try c.encode(modelsText, forKey: .modelsText)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// 一条待审批的配对请求。`resume` 把网关那侧 await 的 continuation 接起来。
struct ApprovalRequest: Identifiable {
    let id = UUID()
    let name: String
    let resume: (Bool) -> Void
}

struct RuntimeEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

enum GatewayKeychain {
    private static let service = "ai.phoneclaw.gateway.providers"

    static func loadAPIKey(providerID: UUID) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(providerID: providerID, returningData: true) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveAPIKey(_ apiKey: String, providerID: UUID) -> Bool {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return deleteAPIKey(providerID: providerID) }
        let data = Data(clean.utf8)
        let query = baseQuery(providerID: providerID, returningData: false)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteAPIKey(providerID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(providerID: providerID, returningData: false) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(providerID: UUID, returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

// MARK: - Model

@MainActor
@Observable
final class GatewayModel {
    let port: UInt16 = 18080
    let displayName = Host.current().localizedName ?? "Mac"
    let address = ProcessInfo.processInfo.hostName

    let macID: String = {
        let key = "PhoneClaw.gateway.macID"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    private(set) var running = false
    private(set) var gatewayStatus = "正在启动..."
    private(set) var providerConfigError: String?
    private(set) var providers: [ProviderStatus] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var runtimeEvents: [RuntimeEvent] = []
    private(set) var providerTestResults: [UUID: String] = [:]

    /// 可配置 provider 列表(持久化)。
    var providerConfigs: [ProviderConfig] = GatewayModel.loadConfigs()

    @ObservationIgnored private var gateway: MacGateway?

    private func buildProviders(from configs: [ProviderConfig]? = nil) -> [any GatewayProvider] {
        (configs ?? providerConfigs)
            .filter { $0.enabled && ($0.kind.isMainRuntimeSource || $0.kind == .echo) }
            .map { makeProvider(from: $0) }
    }

    private func makeProvider(from config: ProviderConfig) -> any GatewayProvider {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch config.kind {
        case .codexCLI:
            return LocalCLIProvider(
                id: name,
                command: baseURL,
                mode: .codex,
                advertisedModels: Self.configuredModels(from: config.modelsText)
            )
        case .antigravityCLI:
            let antigravityModels = Self.configuredModels(from: config.modelsText)
                .filter { $0 != "antigravity" }
            return LocalCLIProvider(
                id: name,
                command: baseURL,
                mode: .antigravity,
                advertisedModels: antigravityModels
            )
        case .echo:
            return EchoProvider(id: name)
        default:
            break
        }
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAICompatibleProvider(
            id: name,
            base: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            advertisedModels: Self.configuredModels(from: config.modelsText),
            extraHeaders: Self.providerExtraHeaders(for: config.kind),
            restrictToAdvertisedModels: config.kind == .ollama,
            supportsOllamaTags: config.kind == .ollama
        )
    }

    init() { start() }

    // MARK: 启停

    func start() {
        guard !running else { return }
        guard let normalized = validateAndNormalizeConfigs(providerConfigs) else {
            gatewayStatus = providerConfigError ?? "Provider 配置错误"
            providers = []
            recordEvent(gatewayStatus)
            return
        }
        providerConfigs = normalized
        GatewayModel.saveConfigs(normalized)
        let enabledConfigs = normalized.filter(\.enabled)
        gatewayStatus = "正在启动..."
        recordEvent(gatewayStatus)
        let gw = MacGateway(
            port: port, macID: macID, name: displayName,
            providers: buildProviders(from: normalized),
            defaultProviderID: enabledConfigs.first?.name ?? "ollama",
            onPairRequest: { [weak self] name in await self?.requestApproval(name) ?? false },
            onPairedChanged: { [weak self] in Task { @MainActor in self?.refreshPaired() } },
            onRuntimeEvent: { [weak self] message in
                Task { @MainActor in self?.handleRuntimeEvent(message) }
            }
        )
        do {
            try gw.start()
            gateway = gw
            running = true
        } catch {
            running = false
            gatewayStatus = "启动失败: \(error.localizedDescription)"
            recordEvent(gatewayStatus)
            NSLog("[PhoneClawGateway] start failed: \(error.localizedDescription)")
        }
        refreshPaired()
        Task { await refreshProviders() }
    }

    func stop() {
        gateway?.stop()
        gateway = nil
        running = false
        pendingApprovals.forEach { $0.resume(false) }   // 取消待审批,免得 continuation 悬空
        pendingApprovals.removeAll()
    }

    private func handleRuntimeEvent(_ message: String) {
        if message.hasPrefix("启动失败") {
            gatewayStatus = message
            recordEvent(message)
            running = false
            gateway?.stop()
            gateway = nil
            return
        }
        if message == "已停止" {
            return
        }
        gatewayStatus = message
        recordEvent(message)
    }

    private func recordEvent(_ message: String) {
        runtimeEvents.insert(RuntimeEvent(timestamp: Date(), message: message), at: 0)
        if runtimeEvents.count > 80 {
            runtimeEvents.removeLast(runtimeEvents.count - 80)
        }
    }

    // MARK: 配对审批 (网关后台 → 这里弹 UI → 用户点 → resume)

    func requestApproval(_ name: String) async -> Bool {
        // 弹醒目的系统提示 (不藏在菜单栏弹窗里),激活 app 到前台。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "允许「\(name)」连接?"
        alert.informativeText = "这台设备想通过本机网关使用 LLM 推理。"
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "拒绝")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func approve(_ req: ApprovalRequest) {
        req.resume(true)
        pendingApprovals.removeAll { $0.id == req.id }
    }

    func deny(_ req: ApprovalRequest) {
        req.resume(false)
        pendingApprovals.removeAll { $0.id == req.id }
    }

    // MARK: 设备 / provider

    func refreshPaired() { pairedDevices = gateway?.pairedDevicesSnapshot() ?? [] }
    func revoke(_ device: PairedDevice) { gateway?.revoke(token: device.token); refreshPaired() }

    func refreshAll() {
        refreshPaired()
        Task { await refreshProviders() }
    }

    func scanProvider(_ config: ProviderConfig) async {
        await testProvider(config)
        await refreshProviders()
    }

    func addProvider(kind: ProviderKind) {
        guard kind.canSelectAsRuntimeSource else { return }
        if providerConfigs.contains(where: { $0.kind == kind }) {
            selectRuntimeSource(kind)
            return
        }
        providerConfigs.append(ProviderConfig(
            name: uniqueProviderID(for: kind),
            baseURL: kind.defaultBaseURL,
            kind: kind,
            modelsText: kind.defaultModelsText,
            enabled: false
        ))
        selectRuntimeSource(kind)
    }

    func selectRuntimeSource(_ kind: ProviderKind, applyNow: Bool = true) {
        guard kind.canSelectAsRuntimeSource else { return }
        if !providerConfigs.contains(where: { $0.kind == kind }) {
            providerConfigs.append(ProviderConfig(
                name: uniqueProviderID(for: kind),
                baseURL: kind.defaultBaseURL,
                kind: kind,
                modelsText: kind.defaultModelsText,
                enabled: false
            ))
        }
        for index in providerConfigs.indices {
            providerConfigs[index].enabled = providerConfigs[index].kind == kind
        }
        if applyNow {
            applyConfigs()
        }
    }

    func removeProvider(id: UUID) {
        providerConfigs.removeAll { $0.uuid == id }
        providerTestResults.removeValue(forKey: id)
        GatewayKeychain.deleteAPIKey(providerID: id)
    }

    func applyProviderKind(_ kind: ProviderKind, to id: UUID) {
        guard kind.canSelectAsRuntimeSource || kind == .echo else { return }
        guard let index = providerConfigs.firstIndex(where: { $0.uuid == id }) else { return }
        providerConfigs[index].kind = kind
        if providerConfigs[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            providerConfigs[index].name.hasPrefix("provider") ||
            ProviderKind.allCases.map(\.defaultID).contains(providerConfigs[index].name) {
            providerConfigs[index].name = uniqueProviderID(for: kind, excluding: id)
        }
        providerConfigs[index].baseURL = kind.defaultBaseURL
        providerConfigs[index].modelsText = kind.defaultModelsText
        if !kind.commonlyUsesAPIKey {
            providerConfigs[index].apiKey = ""
            GatewayKeychain.deleteAPIKey(providerID: id)
        }
        if kind == .echo {
            providerConfigs[index].apiKey = ""
            GatewayKeychain.deleteAPIKey(providerID: id)
        }
    }

    func testProvider(_ config: ProviderConfig) async {
        let cleanName = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            providerTestResults[config.uuid] = "Provider id 不能为空"
            return
        }
        if config.kind.needsAPIKey, config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerTestResults[config.uuid] = "需要 API Key"
            return
        }
        if config.kind.usesCommand, config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerTestResults[config.uuid] = "需要 CLI 命令"
            return
        }
        providerTestResults[config.uuid] = "测试中..."
        let provider = makeProvider(from: config)
        let health = await provider.health()
        if health.reachable {
            let modelInfo = health.models.isEmpty ? "未返回模型" : "\(health.models.count) 个模型"
            providerTestResults[config.uuid] = "可用 · \(modelInfo)"
        } else {
            let detail = health.detail ?? "未知错误"
            if detail.contains("桥接待接入") {
                providerTestResults[config.uuid] = "待接入"
            } else if detail.contains("not found") || detail.contains("未找到") {
                providerTestResults[config.uuid] = "不可用 · 未找到命令"
            } else {
                providerTestResults[config.uuid] = "不可用"
            }
        }
    }

    func refreshProviders() async {
        var result: [ProviderStatus] = []
        for config in providerConfigs where config.kind.isMainRuntimeSource || config.kind == .echo {
            let p = makeProvider(from: config)
            let health = await p.health()
            result.append(ProviderStatus(
                id: p.id,
                reachable: health.reachable,
                modelCount: health.models.count,
                detail: health.detail
            ))
        }
        providers = result
    }

    /// 应用 provider 配置:持久化 + (运行中则) 重启网关。
    func applyConfigs() {
        guard let normalized = validateAndNormalizeConfigs(providerConfigs) else {
            gatewayStatus = providerConfigError ?? "Provider 配置错误"
            providers = []
            recordEvent(gatewayStatus)
            return
        }
        providerConfigs = normalized
        GatewayModel.saveConfigs(normalized)
        if running { stop() }
        start()
    }

    private func validateAndNormalizeConfigs(_ configs: [ProviderConfig]) -> [ProviderConfig]? {
        var normalized: [ProviderConfig] = []
        var seen = Set<String>()
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

        for original in configs {
            guard original.kind.isMainRuntimeSource || original.kind == .echo else { continue }
            var cfg = original
            cfg.name = cfg.name.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.baseURL = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.apiKey = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.modelsText = cfg.modelsText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cfg.name.isEmpty else {
                providerConfigError = "Provider id 不能为空"
                return nil
            }
            guard cfg.name.rangeOfCharacter(from: allowedID.inverted) == nil else {
                providerConfigError = "Provider id 只能包含字母、数字、点、下划线和短横线"
                return nil
            }
            let foldedName = cfg.name.lowercased()
            guard seen.insert(foldedName).inserted else {
                providerConfigError = "Provider id 不能重复: \(cfg.name)"
                return nil
            }
            if cfg.kind.usesCommand {
                guard !cfg.baseURL.isEmpty else {
                    providerConfigError = "\(cfg.name) 需要 CLI 命令"
                    return nil
                }
            } else if cfg.kind != .echo {
                guard let url = URL(string: cfg.baseURL),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      url.host?.isEmpty == false else {
                    providerConfigError = "\(cfg.name) 的 baseURL 必须是有效的 http/https 地址"
                    return nil
                }
                if cfg.kind.needsAPIKey, cfg.apiKey.isEmpty {
                    providerConfigError = "\(cfg.name) 需要 API Key"
                    return nil
                }
            }
            normalized.append(cfg)
        }

        guard normalized.contains(where: \.enabled) else {
            providerConfigError = "请选择一个运行源"
            return nil
        }
        providerConfigError = nil
        return normalized
    }

    private static func configuredModels(from text: String) -> [String] {
        text
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func providerExtraHeaders(for kind: ProviderKind) -> [String: String] {
        switch kind {
        case .openRouter:
            return [
                "HTTP-Referer": "https://phoneclaw.local",
                "X-Title": "PhoneClaw Gateway",
            ]
        default:
            return [:]
        }
    }

    private func uniqueProviderID(for kind: ProviderKind, excluding excludedID: UUID? = nil) -> String {
        let used = Set(providerConfigs.compactMap { cfg -> String? in
            guard cfg.uuid != excludedID else { return nil }
            return cfg.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let base = kind.defaultID
        if !used.contains(base) { return base }
        var suffix = 2
        while used.contains("\(base)\(suffix)") {
            suffix += 1
        }
        return "\(base)\(suffix)"
    }

    private static let configsKey = "PhoneClaw.gateway.providers"

    static func loadConfigs() -> [ProviderConfig] {
        if let data = UserDefaults.standard.data(forKey: configsKey),
           var list = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           !list.isEmpty {
            for index in list.indices {
                if let key = GatewayKeychain.loadAPIKey(providerID: list[index].uuid), !key.isEmpty {
                    list[index].apiKey = key
                } else if !list[index].apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GatewayKeychain.saveAPIKey(list[index].apiKey, providerID: list[index].uuid)
                }
            }
            return normalizedRuntimeConfigs(from: list)
        }
        return defaultRuntimeConfigs()
    }

    static func saveConfigs(_ list: [ProviderConfig]) {
        var persisted = normalizedRuntimeConfigs(from: list)
        for index in persisted.indices {
            let key = persisted[index].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                GatewayKeychain.deleteAPIKey(providerID: persisted[index].uuid)
            } else {
                GatewayKeychain.saveAPIKey(key, providerID: persisted[index].uuid)
            }
            persisted[index].apiKey = ""
        }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: configsKey)
        }
    }

    private static func defaultRuntimeConfigs() -> [ProviderConfig] {
        ProviderKind.catalogCases.map { kind in
            ProviderConfig(
                name: kind.defaultID,
                baseURL: kind.defaultBaseURL,
                kind: kind,
                modelsText: kind.defaultModelsText,
                enabled: kind == .ollama
            )
        }
    }

    private static func normalizedRuntimeConfigs(from list: [ProviderConfig]) -> [ProviderConfig] {
        var result = defaultRuntimeConfigs()
        for config in list where config.kind.isMainRuntimeSource {
            guard let index = result.firstIndex(where: { $0.kind == config.kind }) else { continue }
            result[index] = migratedRuntimeConfig(config)
        }
        if !result.contains(where: \.enabled) {
            if let index = result.firstIndex(where: { $0.kind == .ollama }) {
                result[index].enabled = true
            }
        } else {
            var didKeepFirstEnabled = false
            for index in result.indices {
                if result[index].enabled, !didKeepFirstEnabled {
                    didKeepFirstEnabled = true
                } else {
                    result[index].enabled = false
                }
            }
        }
        return result
    }

    private static func migratedRuntimeConfig(_ config: ProviderConfig) -> ProviderConfig {
        var migrated = config
        let models = configuredModels(from: migrated.modelsText)
        if migrated.kind == .codexCLI,
           models.isEmpty || models.contains(where: isStaleCodexDefaultModel) {
            migrated.modelsText = ""
        }
        if migrated.kind == .ollama,
           models.contains(where: isStaleOllamaDefaultModel) {
            migrated.modelsText = ""
        }
        if migrated.kind == .antigravityCLI {
            let command = migrated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty || command == "antigravity" {
                migrated.baseURL = ProviderKind.antigravityCLI.defaultBaseURL
            }
            if models.isEmpty || models.contains("antigravity") {
                migrated.modelsText = ""
            }
        }
        return migrated
    }

    private static func isStaleCodexDefaultModel(_ model: String) -> Bool {
        ["codex", "gpt-5-codex", "gpt-5", "o4-mini"].contains(model.lowercased())
    }

    private static func isStaleOllamaDefaultModel(_ model: String) -> Bool {
        ["gemma3:4b", "gpt-oss:20b", "qwen3:8b"].contains(model.lowercased())
    }
}

// MARK: - 主窗口 UI

private enum GatewayTheme {
    static let bg = Color(pcLight: "F8F5EF", dark: "15130F")
    static let bgElevated = Color(pcLight: "FFFFFF", dark: "211E19")
    static let bgHover = Color(pcLight: "EAE5DB", dark: "2D2821")
    static let textPrimary = Color(pcLight: "3A342E", dark: "EFE9DF")
    static let textSecondary = Color(pcLight: "70675E", dark: "B9AFA3")
    static let textTertiary = Color(pcLight: "B8ADA0", dark: "756D63")
    static let accent = Color(pcLight: "C77A3F", dark: "D59B63")
    static let accentSubtle = Color(pcLight: "C77A3F", dark: "D59B63").opacity(0.16)
    static let accentMuted = Color(pcLight: "C39660", dark: "C99B68")
    static let accentGreen = Color(pcLight: "7CB87C", dark: "8FD08F")
    static let accentBlue = Color(pcLight: "6F94B8", dark: "8CAFD1")
    static let accentPurple = Color(pcLight: "8D7AA8", dark: "A894C7")
    static let border = Color(pcLight: "E0DED7", dark: "39332A")
    static let borderSubtle = Color(pcLight: "F0EBE2", dark: "2B261F")
    static let danger = Color(pcLight: "9E554D", dark: "E08B80")
}

private extension Color {
    init(pcLight: String, dark: String) {
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(pcHex: isDark ? dark : pcLight)
        })
    }
}

private extension NSColor {
    convenience init(pcHex: String) {
        let hex = pcHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 8:
            a = int >> 24
            r = int >> 16 & 0xFF
            g = int >> 8 & 0xFF
            b = int & 0xFF
        default:
            a = 255
            r = int >> 16
            g = int >> 8 & 0xFF
            b = int & 0xFF
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

enum GatewaySection: String, CaseIterable, Identifiable {
    case providers
    case devices
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: return "运行源"
        case .devices: return "设备"
        case .logs: return "日志"
        }
    }

    var subtitle: String {
        switch self {
        case .providers: return "Local private runtime"
        case .devices: return "Paired iPhone clients"
        case .logs: return "Recent events"
        }
    }

    var systemImage: String {
        switch self {
        case .providers: return "point.topleft.down.curvedto.point.bottomright.up"
        case .devices: return "iphone"
        case .logs: return "list.bullet.rectangle"
        }
    }
}

struct GatewayDashboardView: View {
    @Bindable var model: GatewayModel
    @State private var selection: GatewaySection? = .providers

    var body: some View {
        dashboardCanvas
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GatewayTheme.bg.ignoresSafeArea())
        .background(GatewayWindowConfigurator())
    }

    private var dashboardCanvas: some View {
        HStack(spacing: 0) {
            sidebar
            mainArea
        }
        .background(GatewayTheme.bg)
        .tint(GatewayTheme.accentMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var selectedSection: GatewaySection { selection ?? .providers }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 14) {
                SoftIcon(systemName: "link", color: GatewayTheme.accent, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PhoneClaw")
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                    Text("Gateway")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }
            }
            .padding(.top, 38)
            .padding(.leading, 8)

            VStack(spacing: 12) {
                ForEach(GatewaySection.allCases) { item in
                    sidebarButton(item)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .frame(width: 230)
    }

    private func sidebarButton(_ item: GatewaySection) -> some View {
        let selected = selectedSection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 16) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? GatewayTheme.accent : GatewayTheme.textSecondary)
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? GatewayTheme.accentSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mainArea: some View {
        ScrollView {
            detailContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
                .padding(.vertical, 42)
                .padding(.trailing, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .providers:
            RuntimeSourceWorkspaceView(model: model)
        case .devices:
            LegacyWorkspacePanel(title: "设备", subtitle: "Paired iPhone clients") {
                pairedDevicesPanel
            }
        case .logs:
            LegacyWorkspacePanel(title: "日志", subtitle: "Recent events") {
                runtimePanel
            }
        }
    }

    private var statusColor: Color {
        if model.gatewayStatus.hasPrefix("启动失败") || model.providerConfigError != nil {
            return GatewayTheme.danger
        }
        return model.running ? GatewayTheme.accentGreen : GatewayTheme.textTertiary
    }

    private var approvalPanel: some View {
        GatewaySurface(title: "配对请求", systemImage: "iphone.badge.play") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.pendingApprovals) { req in
                    HStack(spacing: 10) {
                        Text(req.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Button("拒绝") { model.deny(req) }
                            .buttonStyle(GatewaySecondaryButtonStyle())
                        Button("允许") { model.approve(req) }
                            .buttonStyle(GatewayPrimaryButtonStyle())
                    }
                }
            }
        }
    }

    private var providersPanel: some View {
        GatewaySurface(title: "运行状态", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 0) {
                if model.providers.isEmpty {
                    EmptyStateLine(text: "暂无 provider 状态")
                } else {
                    ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
                        ProviderStatusRow(provider: provider)
                        if index < model.providers.count - 1 { Hairline() }
                    }
                }
            }
        }
    }

    private var pairedDevicesPanel: some View {
        GatewaySurface(title: "已配对设备", systemImage: "iphone") {
            VStack(alignment: .leading, spacing: 0) {
                if model.pairedDevices.isEmpty {
                    EmptyStateLine(text: "暂无设备")
                } else {
                    ForEach(Array(model.pairedDevices.enumerated()), id: \.element.id) { index, device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .foregroundStyle(GatewayTheme.textSecondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(GatewayTheme.textPrimary)
                                Text(deviceSubtitle(device))
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(GatewayTheme.textTertiary)
                            }
                            Spacer()
                            Button {
                                model.revoke(device)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(GatewayTheme.textSecondary)
                            .help("撤销")
                        }
                        .padding(.vertical, 12)
                        if index < model.pairedDevices.count - 1 { Hairline() }
                    }
                }
            }
        }
    }

    private var runtimePanel: some View {
        GatewaySurface(title: "运行事件", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 0) {
                if model.runtimeEvents.isEmpty {
                    EmptyStateLine(text: "暂无事件")
                } else {
                    ForEach(Array(model.runtimeEvents.prefix(16).enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(clockTime(event.timestamp))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(GatewayTheme.textTertiary)
                                .frame(width: 72, alignment: .leading)
                            Text(event.message)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(GatewayTheme.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        if index < min(model.runtimeEvents.count, 16) - 1 { Hairline() }
                    }
                }
            }
        }
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        if let lastSeenAt = device.lastSeenAt {
            return "最近使用 \(relativeTime(lastSeenAt))"
        }
        return "配对于 \(relativeTime(device.pairedAt))"
    }
}

struct RuntimeSourceWorkspaceView: View {
    @Bindable var model: GatewayModel
    @State private var focusedKind: ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                WorkspaceSourceListPanel(
                    model: model,
                    activeKind: activeConfig?.kind ?? .ollama,
                    focusedKind: currentConfig?.kind ?? activeConfig?.kind ?? .ollama
                ) { kind in
                    focusedKind = kind
                }
                if let binding = currentConfigBinding {
                    WorkspaceProviderConfigPanel(
                        config: binding,
                        providerStatus: selectedProviderStatus,
                        testResult: model.providerTestResults[binding.wrappedValue.uuid],
                        onScan: { Task { await model.scanProvider(binding.wrappedValue) } },
                        onApply: { model.selectRuntimeSource(binding.wrappedValue.kind) }
                    )
                } else {
                    EmptyStateLine(text: "请选择一个运行源")
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 20, x: 0, y: 12)
    }

    private var activeConfig: ProviderConfig? {
        model.providerConfigs.first(where: \.enabled)
    }

    private var currentConfig: ProviderConfig? {
        if let focusedKind,
           let focused = model.providerConfigs.first(where: { $0.kind == focusedKind }) {
            return focused
        }
        return activeConfig ??
            model.providerConfigs.first(where: { $0.kind == .ollama }) ??
            model.providerConfigs.first
    }

    private var currentConfigBinding: Binding<ProviderConfig>? {
        guard let config = currentConfig,
              let index = model.providerConfigs.firstIndex(where: { $0.uuid == config.uuid }) else {
            return nil
        }
        return Binding(
            get: { model.providerConfigs[index] },
            set: { model.providerConfigs[index] = $0 }
        )
    }

    private var selectedProviderStatus: ProviderStatus? {
        guard let config = currentConfig else { return nil }
        return model.providers.first { $0.id == config.name }
    }
}

struct WorkspaceSourceListPanel: View {
    @Bindable var model: GatewayModel
    let activeKind: ProviderKind
    let focusedKind: ProviderKind
    let onFocus: (ProviderKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("选择运行源")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text("选择要使用的运行时环境")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }

            VStack(spacing: 12) {
                ForEach(ProviderKind.catalogCases) { kind in
                    if let config = model.providerConfigs.first(where: { $0.kind == kind }) {
                        WorkspaceSourceRow(
                            config: config,
                            isCurrent: activeKind == kind,
                            isFocused: focusedKind == kind,
                            canApply: kind.canSelectAsRuntimeSource,
                            providerStatus: model.providers.first { $0.id == config.name },
                            testResult: model.providerTestResults[config.uuid]
                        ) {
                            onFocus(kind)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 294, height: 500, alignment: .topLeading)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }
}

struct WorkspaceSourceRow: View {
    let config: ProviderConfig
    let isCurrent: Bool
    let isFocused: Bool
    let canApply: Bool
    let providerStatus: ProviderStatus?
    let testResult: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                radio
                SoftIcon(systemName: config.kind.systemImage, color: isCurrent ? GatewayTheme.accent : iconColor, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(config.kind.title)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("当前使用")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(GatewayTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else if isFocused {
                    Text("查看中")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textSecondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 68)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(rowStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var radio: some View {
        ZStack {
            Circle()
                .stroke(isCurrent ? GatewayTheme.accent : GatewayTheme.textTertiary.opacity(0.7), lineWidth: 1)
                .frame(width: 14, height: 14)
            if isCurrent {
                Circle()
                    .fill(GatewayTheme.accent)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var rowBackground: Color {
        if isCurrent { return GatewayTheme.accentSubtle.opacity(0.56) }
        if isFocused { return GatewayTheme.bgHover.opacity(0.36) }
        return GatewayTheme.bgElevated
    }

    private var rowStroke: Color {
        if isCurrent { return GatewayTheme.accent.opacity(0.55) }
        if isFocused { return GatewayTheme.border }
        return GatewayTheme.borderSubtle
    }

    private var iconColor: Color {
        config.kind == .antigravityCLI ? GatewayTheme.accentGreen : GatewayTheme.textTertiary
    }

    private var subtitle: String {
        if let testResult, testResult.hasPrefix("不可用") { return testResult }
        if let providerStatus {
            if providerStatus.reachable {
                return providerStatus.modelCount > 0 ? "可用 · \(providerStatus.modelCount) 个模型" : "可用 · 等待模型"
            }
            return "需要安装或启动"
        }
        return config.kind.shortDescription
    }
}

struct WorkspaceProviderConfigPanel: View {
    @Binding var config: ProviderConfig
    let providerStatus: ProviderStatus?
    let testResult: String?
    let onScan: () -> Void
    let onApply: () -> Void
    @State private var localScan: LocalRuntimeScan?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(config.kind.title)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text("自动扫描本机安装和模型")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }

            runtimeReadiness
                .padding(.top, 34)

            if let setupGuide {
                RuntimeSetupGuideView(guide: setupGuide)
                    .padding(.top, 14)
            }

            Rectangle()
                .fill(GatewayTheme.borderSubtle)
                .frame(height: 1)
                .padding(.vertical, 24)

            if shouldShowModelSelector {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可用模型")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                    Text("勾选后会同步到 iPhone")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }

                WorkspaceModelSelector(config: $config)
                    .padding(.top, 14)
            }

            if let testResult {
                Text(testResult)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(testResult.hasPrefix("可用") ? GatewayTheme.accentGreen : GatewayTheme.danger)
                    .padding(.top, 10)
            }

            Spacer(minLength: 24)

            HStack {
                Spacer(minLength: 0)
                Button(action: onApply) {
                    Text("应用配置")
                        .frame(width: 88)
                }
                .buttonStyle(WorkspacePrimaryButtonStyle())
                .help("设为当前运行源并应用")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
        .task(id: config.kind.rawValue) {
            localScan = LocalRuntimeScanner.scan(kind: config.kind)
        }
    }

    private var runtimeReadiness: some View {
        HStack(spacing: 14) {
            SoftIcon(systemName: readinessIcon, color: readinessColor, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(readinessTitle)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text(readinessDetail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                localScan = LocalRuntimeScanner.scan(kind: config.kind)
                onScan()
            } label: {
                Label("扫描本机", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(WorkspaceSecondaryButtonStyle())
        }
        .padding(16)
        .background(GatewayTheme.bgHover.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var readinessIcon: String {
        if isScanning { return "arrow.triangle.2.circlepath" }
        if providerStatus?.reachable == true { return "checkmark.circle" }
        if localScan?.isInstalled == true { return "play.circle" }
        return "arrow.down.circle"
    }

    private var readinessTitle: String {
        if isScanning { return "正在扫描本机" }
        if providerStatus?.reachable == true {
            return visibleModelCount > 0 ? "已准备好" : "已安装，等待模型"
        }
        if localScan?.isInstalled == true {
            return config.kind == .ollama ? "已安装，等待启动" : "已安装，等待登录"
        }
        return "需要安装 \(config.kind.title)"
    }

    private var readinessDetail: String {
        if isScanning { return "正在检查本机命令和模型列表" }
        if providerStatus?.reachable == true {
            if config.kind == .antigravityCLI {
                return visibleModelCount > 0 ? "已读取 AGY 可选模型，可以直接在 iPhone 上选择。" : "已找到 agy 命令，完成登录后再扫描模型。"
            }
            return visibleModelCount > 0 ? "已找到 \(visibleModelCount) 个模型，可以直接在 iPhone 上选择。" : "没有读取到模型，按下面命令先添加一个模型。"
        }
        if localScan?.isInstalled == true {
            switch config.kind {
            case .ollama:
                return "打开 Ollama 后点扫描，本机模型会自动出现。"
            case .codexCLI:
                return "完成 Codex 登录后点扫描，模型会自动出现。"
            case .antigravityCLI:
                return "完成 Antigravity 登录后点扫描，模型会自动出现。"
            default:
                return "点扫描后刷新当前状态。"
            }
        }
        return "安装后回到这里点扫描，不需要手动填写网络地址。"
    }

    private var readinessColor: Color {
        if providerStatus?.reachable == true, visibleModelCount > 0 { return GatewayTheme.accentGreen }
        if localScan?.isInstalled == true || providerStatus?.reachable == true { return GatewayTheme.accent }
        return GatewayTheme.danger
    }

    private var isScanning: Bool {
        testResult == "测试中..."
    }

    private var visibleModelCount: Int {
        providerStatus?.modelCount ?? fallbackModelCount
    }

    private var fallbackModelCount: Int {
        config.modelsText
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private var shouldShowModelSelector: Bool {
        if providerStatus?.reachable == true { return true }
        return config.kind == .codexCLI && localScan?.isInstalled == true
    }

    private var setupGuide: RuntimeSetupGuide? {
        RuntimeSetupGuide.resolve(
            kind: config.kind,
            isReachable: providerStatus?.reachable == true,
            modelCount: visibleModelCount,
            localScan: localScan
        )
    }
}

private struct RuntimeSetupGuide: Equatable {
    let title: String
    let detail: String
    let primaryCommand: String?
    let secondaryCommand: String?
    let officialURL: URL?

    static func resolve(
        kind: ProviderKind,
        isReachable: Bool,
        modelCount: Int,
        localScan: LocalRuntimeScan?
    ) -> RuntimeSetupGuide? {
        switch kind {
        case .codexCLI:
            if localScan?.isInstalled != true && !isReachable {
                return RuntimeSetupGuide(
                    title: "安装 Codex CLI",
                    detail: "安装后打开终端运行 codex 完成登录，再回到这里点扫描。",
                    primaryCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                    secondaryCommand: "codex",
                    officialURL: URL(string: "https://developers.openai.com/codex/cli")
                )
            }
            if modelCount == 0 {
                return RuntimeSetupGuide(
                    title: "完成 Codex 登录",
                    detail: "已找到 Codex 命令，但还没有读取到模型。运行 Codex 完成登录后再扫描。",
                    primaryCommand: "codex",
                    secondaryCommand: nil,
                    officialURL: URL(string: "https://developers.openai.com/codex/cli")
                )
            }
            return nil
        case .antigravityCLI:
            if localScan?.isInstalled != true && !isReachable {
                return RuntimeSetupGuide(
                    title: "安装 Antigravity CLI",
                    detail: "安装后打开终端运行 agy 完成登录，再回到这里点扫描。",
                    primaryCommand: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                    secondaryCommand: "agy",
                    officialURL: URL(string: "https://antigravity.google/docs/cli-install")
                )
            }
            if modelCount == 0 {
                return RuntimeSetupGuide(
                    title: "完成 Antigravity 登录",
                    detail: "已找到 agy 命令，但还没有读取到模型。运行 agy 完成登录后再扫描。",
                    primaryCommand: "agy",
                    secondaryCommand: nil,
                    officialURL: URL(string: "https://antigravity.google/docs/cli-install")
                )
            }
            return nil
        case .ollama:
            if isReachable {
                guard modelCount == 0 else { return nil }
                return RuntimeSetupGuide(
                    title: "下载一个本地模型",
                    detail: "Ollama 已经启动，但还没有可用模型。下载完成后点扫描。",
                    primaryCommand: "ollama pull gemma3:4b",
                    secondaryCommand: nil,
                    officialURL: URL(string: "https://ollama.com/download")
                )
            }
            if localScan?.isInstalled == true {
                return RuntimeSetupGuide(
                    title: "启动 Ollama",
                    detail: "Ollama 已安装但当前没有运行。启动后点扫描，模型会自动出现。",
                    primaryCommand: "open -a Ollama",
                    secondaryCommand: nil,
                    officialURL: URL(string: "https://ollama.com/download")
                )
            }
            return RuntimeSetupGuide(
                title: "安装 Ollama",
                detail: "安装并启动 Ollama 后，下载一个模型即可在 iPhone 上使用。",
                primaryCommand: "curl -fsSL https://ollama.com/install.sh | sh",
                secondaryCommand: "ollama pull gemma3:4b",
                officialURL: URL(string: "https://ollama.com/download")
            )
        default:
            return nil
        }
    }
}

private struct RuntimeSetupGuideView: View {
    let guide: RuntimeSetupGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                SoftIcon(systemName: "terminal", color: GatewayTheme.accent, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.title)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                    Text(guide.detail)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                        .lineLimit(3)
                }
            }

            if let primaryCommand = guide.primaryCommand {
                RuntimeCommandRow(command: primaryCommand)
            }
            if let secondaryCommand = guide.secondaryCommand {
                RuntimeCommandRow(command: secondaryCommand)
            }

            if let officialURL = guide.officialURL {
                Button {
                    NSWorkspace.shared.open(officialURL)
                } label: {
                    Label("打开官网", systemImage: "safari")
                }
                .buttonStyle(GatewayQuietButtonStyle())
            }
        }
        .padding(16)
        .background(GatewayTheme.accentSubtle.opacity(0.40), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GatewayTheme.accent.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct RuntimeCommandRow: View {
    let command: String

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(GatewayTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(GatewayTheme.accent)
            .help("复制命令")
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(GatewayTheme.bgElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }
}

private struct LocalRuntimeScan: Equatable {
    let executablePath: String?
    let appPath: String?

    var isInstalled: Bool {
        executablePath != nil || appPath != nil
    }
}

private enum LocalRuntimeScanner {
    static func scan(kind: ProviderKind) -> LocalRuntimeScan {
        switch kind {
        case .codexCLI:
            return LocalRuntimeScan(
                executablePath: resolveExecutable("codex", extraPaths: codexExecutablePathsFromNVM()),
                appPath: nil
            )
        case .antigravityCLI:
            return LocalRuntimeScan(
                executablePath: resolveExecutable("agy", extraPaths: []),
                appPath: nil
            )
        case .ollama:
            return LocalRuntimeScan(
                executablePath: resolveExecutable("ollama", extraPaths: [
                    "/Applications/Ollama.app/Contents/Resources/ollama",
                ]),
                appPath: installedAppPath("Ollama.app")
            )
        default:
            return LocalRuntimeScan(executablePath: nil, appPath: nil)
        }
    }

    private static func resolveExecutable(_ command: String, extraPaths: [String] = []) -> String? {
        for candidate in commonExecutablePaths(for: command) + extraPaths {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if let shellPath = shellCommandPath(command),
           FileManager.default.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        return nil
    }

    private static func commonExecutablePaths(for command: String) -> [String] {
        [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(NSHomeDirectory())/.local/bin/\(command)",
        ]
    }

    private static func installedAppPath(_ appName: String) -> String? {
        let paths = [
            "/Applications/\(appName)",
            "\(NSHomeDirectory())/Applications/\(appName)",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func shellCommandPath(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init)
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
            .flatMap { versionURL in
                [
                    versionURL.appendingPathComponent("bin/codex").path,
                    versionURL.appendingPathComponent("lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex").path,
                ]
            }
    }
}

struct WorkspaceModelSelector: View {
    @Binding var config: ProviderConfig
    @State private var options: [RuntimeModelOption] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && options.isEmpty {
                WorkspaceModelLoadingRow()
            } else if options.isEmpty {
                Text(errorText ?? "未返回模型")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(errorText == nil ? GatewayTheme.textTertiary : GatewayTheme.danger)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
                    )
            } else {
                LazyVGrid(columns: modelGridColumns, alignment: .leading, spacing: 12) {
                    ForEach(options) { option in
                        WorkspaceModelRow(
                            option: option,
                            isSelected: isSelected(option.id),
                            isDisabled: isOnlyExplicitSelection(option.id)
                        ) {
                            toggle(option.id)
                        }
                    }
                }
            }
        }
        .task(id: reloadKey) {
            await reload()
        }
    }

    private var modelGridColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 420), spacing: 12, alignment: .top)
        ]
    }

    private var reloadKey: String {
        "\(config.kind.rawValue)|\(config.baseURL)"
    }

    private var selectedModels: [String] {
        parseModelText(config.modelsText)
    }

    private func isSelected(_ model: String) -> Bool {
        selectedModels.contains(model)
    }

    private func isOnlyExplicitSelection(_ model: String) -> Bool {
        selectedModels.count == 1 && selectedModels.first == model
    }

    private func toggle(_ model: String) {
        var selected = selectedModels
        if let index = selected.firstIndex(of: model) {
            guard selected.count > 1 else { return }
            selected.remove(at: index)
        } else {
            selected.append(model)
        }
        let selectedSet = Set(selected)
        let ordered = options.map(\.id).filter { selectedSet.contains($0) }
        config.modelsText = ordered.joined(separator: ", ")
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorText = nil
        do {
            switch config.kind {
            case .codexCLI:
                let loaded = CodexCLIModelListLoader.load().map {
                    RuntimeModelOption(id: $0.id, title: $0.title, subtitle: "Codex CLI", badge: nil, badgeColor: GatewayTheme.accentBlue, trailing: nil)
                }
                options = loaded
                errorText = loaded.isEmpty ? "未找到 Codex 模型缓存" : nil
                normalizeSelection(to: loaded.map(\.id))
            case .antigravityCLI:
                let loaded = AntigravityModelCatalog.models.map {
                    RuntimeModelOption(
                        id: $0.id,
                        title: $0.displayName ?? $0.id,
                        subtitle: "Antigravity CLI",
                        badge: nil,
                        badgeColor: GatewayTheme.accentGreen,
                        trailing: nil
                    )
                }
                options = loaded
                errorText = nil
                normalizeSelection(to: loaded.map(\.id))
            case .ollama:
                let loaded = try await OllamaModelListLoader.fetchOptions(baseURL: config.baseURL)
                options = loaded
                errorText = loaded.isEmpty ? "未返回模型" : nil
                normalizeSelection(to: loaded.map(\.id))
            default:
                options = []
                errorText = "该运行源不支持模型列表"
            }
        } catch {
            options = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func normalizeSelection(to models: [String]) {
        guard !models.isEmpty else { return }
        let selectedSet = Set(selectedModels)
        let kept = models.filter { selectedSet.contains($0) }
        if kept.isEmpty {
            config.modelsText = models.joined(separator: ", ")
        } else {
            config.modelsText = kept.joined(separator: ", ")
        }
    }

    private func parseModelText(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            result.append(model)
        }
        return result
    }
}

struct WorkspaceModelRow: View {
    let option: RuntimeModelOption
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isSelected ? GatewayTheme.accent : GatewayTheme.textTertiary.opacity(0.72))
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(GatewayTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let badge = option.badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundStyle(option.badgeColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(option.badgeColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    Text(option.subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let trailing = option.trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? GatewayTheme.accentSubtle.opacity(0.46) : GatewayTheme.bgHover.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? GatewayTheme.accent.opacity(0.48) : GatewayTheme.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
    }
}

struct WorkspaceModelLoadingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("读取模型")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(GatewayTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 12)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }
}

struct RuntimeModelOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let badge: String?
    let badgeColor: Color
    let trailing: String?
}

struct SoftIcon: View {
    let systemName: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.10))
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct LegacyWorkspacePanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }
            content
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 34)
        .frame(maxWidth: 1010, alignment: .leading)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }
}

struct ProviderConfigEditorView: View {
    @Bindable var model: GatewayModel

    var body: some View {
        GatewayPanel {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.providerConfigError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.danger)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ProviderKind.catalogCases) { kind in
                        if let cfg = binding(for: kind) {
                            RuntimeSourceCard(
                                config: cfg,
                                isSelected: cfg.wrappedValue.enabled,
                                testResult: model.providerTestResults[cfg.wrappedValue.uuid],
                                onSelect: { model.selectRuntimeSource(kind) },
                                onTest: { Task { await model.testProvider(cfg.wrappedValue) } }
                            )
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        model.applyConfigs()
                    } label: {
                        Label("应用", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(GatewayPrimaryButtonStyle())
                }
                .padding(.top, 2)
            }
        }
    }

    private func binding(for kind: ProviderKind) -> Binding<ProviderConfig>? {
        guard let index = model.providerConfigs.firstIndex(where: { $0.kind == kind }) else { return nil }
        return Binding(
            get: { model.providerConfigs[index] },
            set: { model.providerConfigs[index] = $0 }
        )
    }
}

struct RuntimeSourceCard: View {
    @Binding var config: ProviderConfig
    let isSelected: Bool
    let testResult: String?
    let onSelect: () -> Void
    let onTest: () -> Void
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: isSelected ? 10 : 0) {
            Button(action: onSelect) {
                HStack(spacing: 15) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? GatewayTheme.accentSubtle : GatewayTheme.bgHover.opacity(0.30))
                        Image(systemName: config.kind.systemImage)
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(isSelected ? GatewayTheme.accent : GatewayTheme.accentMuted)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(config.kind.title)
                            .font(.system(size: 15, weight: .light, design: .rounded))
                            .foregroundStyle(GatewayTheme.textPrimary)
                        Text(statusText)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(GatewayTheme.accent)
                    } else if !config.kind.canSelectAsRuntimeSource {
                        Text("待接入")
                            .font(.system(size: 12, weight: .light, design: .rounded))
                            .foregroundStyle(GatewayTheme.textTertiary)
                    } else {
                        Text("使用")
                            .font(.system(size: 12, weight: .light, design: .rounded))
                            .foregroundStyle(GatewayTheme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!config.kind.canSelectAsRuntimeSource)

            if isSelected {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(summaryText)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(GatewayTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            onTest()
                        } label: {
                            Label("测试", systemImage: "bolt.horizontal.circle")
                        }
                        .buttonStyle(GatewayQuietButtonStyle())
                        Button {
                            showingSettings = true
                        } label: {
                            Label(config.kind.usesCommand ? "命令" : "地址", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(GatewayQuietButtonStyle())
                        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                            RuntimeSourceSettingsPopover(config: $config)
                        }
                    }

                    if config.kind.supportsInlineModelSelection {
                        RuntimeInlineModelSelector(config: $config)
                    }
                }
                .padding(.leading, 53)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isSelected ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? GatewayTheme.bgElevated : GatewayTheme.bgHover.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? GatewayTheme.border : GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var statusText: String {
        if let testResult { return testResult }
        if isSelected { return "当前运行源" }
        if !config.kind.canSelectAsRuntimeSource { return "CLI 桥接待接入" }
        return config.kind.shortDescription
    }

    private var statusColor: Color {
        guard let testResult else {
            return isSelected ? GatewayTheme.accent : GatewayTheme.textTertiary
        }
        if testResult.hasPrefix("待接入") || testResult.contains("桥接待接入") {
            return GatewayTheme.textTertiary
        }
        return testResult.hasPrefix("可用") ? GatewayTheme.accentGreen : GatewayTheme.danger
    }

    private var summaryText: String {
        let models = configuredModelNames
        if let first = models.first {
            if config.kind == .ollama || config.kind == .codexCLI {
                return models.count > 1 ? "已选 \(first) 等 \(models.count) 个模型" : "已选 \(first)"
            }
            return models.count > 1 ? "默认 \(first) 等 \(models.count) 个模型" : "默认 \(first)"
        }
        if config.kind == .ollama {
            return "自动读取 Ollama 模型"
        }
        if config.kind == .codexCLI {
            return "自动读取 Codex 模型"
        }
        if config.kind.usesCommand {
            return "本机命令"
        }
        return "本机服务"
    }

    private var configuredModelNames: [String] {
        config.modelsText
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension ProviderKind {
    var supportsInlineModelSelection: Bool {
        switch self {
        case .codexCLI, .ollama:
            return true
        default:
            return false
        }
    }
}

struct RuntimeSourceSettingsPopover: View {
    @Binding var config: ProviderConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(config.kind.title)
                .font(.system(size: 15, weight: .light, design: .rounded))
                .foregroundStyle(GatewayTheme.textPrimary)
            runtimeField(config.kind.usesCommand ? "命令" : "地址") {
                TextField(config.kind.usesCommand ? "codex" : "http://127.0.0.1:11434", text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(GatewayTheme.bg)
    }

    private func runtimeField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(GatewayTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RuntimeInlineModelSelector: View {
    @Binding var config: ProviderConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("模型")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(GatewayTheme.textTertiary)

            switch config.kind {
            case .codexCLI:
                CodexCLIModelSelector(modelsText: $config.modelsText)
            case .ollama:
                OllamaModelSelector(baseURL: config.baseURL, modelsText: $config.modelsText)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodexCLIModelSelector: View {
    @Binding var modelsText: String
    @State private var availableModels: [CodexCLIModelOption] = []
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selectionSummary)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                Spacer(minLength: 0)
                Button {
                    modelsText = ""
                } label: {
                    Image(systemName: "checklist.checked")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GatewayTheme.accentMuted)
                .help("使用全部模型")
                .disabled(availableModels.isEmpty || isUsingAllModels)
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GatewayTheme.accentMuted)
                .help("刷新模型")
            }

            if availableModels.isEmpty {
                Text(errorText ?? "未读取到 Codex 模型")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(errorText == nil ? GatewayTheme.textTertiary : GatewayTheme.danger)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(GatewayTheme.bgHover.opacity(0.30), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(availableModels) { model in
                            Button {
                                toggle(model.id)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.title)
                                            .font(.system(size: 12, weight: .regular, design: .rounded))
                                            .foregroundStyle(GatewayTheme.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if model.title != model.id {
                                            Text(model.id)
                                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                                .foregroundStyle(GatewayTheme.textTertiary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if isSelected(model.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 13, weight: .light))
                                            .foregroundStyle(GatewayTheme.accent)
                                    } else {
                                        Image(systemName: "circle")
                                            .font(.system(size: 13, weight: .light))
                                            .foregroundStyle(GatewayTheme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected(model.id) ? GatewayTheme.accentSubtle : GatewayTheme.bgHover.opacity(0.18))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isOnlyExplicitSelection(model.id))
                        }
                    }
                }
                .frame(maxHeight: 178)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            reload()
        }
    }

    private var selectedModels: [String] {
        parseModelText(modelsText)
    }

    private var isUsingAllModels: Bool {
        selectedModels.isEmpty
    }

    private var selectionSummary: String {
        if availableModels.isEmpty {
            return selectedModels.isEmpty ? "自动读取" : "已选 \(selectedModels.count) 个模型"
        }
        return isUsingAllModels ? "全部 \(availableModels.count) 个模型" : "已选 \(selectedModels.count) / \(availableModels.count)"
    }

    private func isSelected(_ model: String) -> Bool {
        isUsingAllModels || selectedModels.contains(model)
    }

    private func isOnlyExplicitSelection(_ model: String) -> Bool {
        !isUsingAllModels && selectedModels.count == 1 && selectedModels.first == model
    }

    private func toggle(_ model: String) {
        var selected = isUsingAllModels ? availableModels.map(\.id) : selectedModels
        if let index = selected.firstIndex(of: model) {
            guard selected.count > 1 else { return }
            selected.remove(at: index)
        } else {
            selected.append(model)
        }
        let selectedSet = Set(selected)
        let ordered = availableModels.map(\.id).filter { selectedSet.contains($0) }
        if ordered.count == availableModels.count {
            modelsText = ""
        } else {
            modelsText = ordered.joined(separator: ", ")
        }
    }

    private func reload() {
        let loaded = CodexCLIModelListLoader.load()
        availableModels = loaded
        errorText = loaded.isEmpty ? "未找到 Codex 模型缓存" : nil
        trimSelection(to: loaded.map(\.id))
    }

    private func trimSelection(to models: [String]) {
        guard !isUsingAllModels else { return }
        let selected = Set(selectedModels)
        let kept = models.filter { selected.contains($0) }
        if kept.isEmpty || kept.count == models.count {
            modelsText = ""
        } else {
            modelsText = kept.joined(separator: ", ")
        }
    }

    private func parseModelText(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            result.append(model)
        }
        return result
    }
}

private struct CodexCLIModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    let priority: Int
}

private enum CodexCLIModelListLoader {
    private struct ModelsCache: Decodable {
        let models: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
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

    static func load() -> [CodexCLIModelOption] {
        let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/models_cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(ModelsCache.self, from: data) {
            let models = cache.models
                .filter { ($0.visibility ?? "list") == "list" }
                .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
                .compactMap { entry -> CodexCLIModelOption? in
                    let id = entry.slug.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return nil }
                    let title = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedTitle: String
                    if let title, !title.isEmpty {
                        resolvedTitle = title
                    } else {
                        resolvedTitle = id
                    }
                    return CodexCLIModelOption(
                        id: id,
                        title: resolvedTitle,
                        priority: entry.priority ?? Int.max
                    )
                }
            if !models.isEmpty { return models }
        }

        if let configured = configuredModelName() {
            return [CodexCLIModelOption(id: configured, title: configured, priority: 0)]
        }
        return []
    }

    private static func configuredModelName() -> String? {
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
}

struct OllamaModelSelector: View {
    let baseURL: String
    @Binding var modelsText: String
    @State private var availableModels: [String] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selectionSummary)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                Spacer(minLength: 0)
                Button {
                    modelsText = ""
                } label: {
                    Image(systemName: "checklist.checked")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GatewayTheme.accentMuted)
                .help("使用全部模型")
                .disabled(availableModels.isEmpty || isUsingAllModels)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GatewayTheme.accentMuted)
                .help("刷新模型")
                .disabled(isLoading)
            }

            modelList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: normalizedBaseURL) {
            await reload()
        }
    }

    @ViewBuilder
    private var modelList: some View {
        if isLoading && availableModels.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("读取中")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .background(GatewayTheme.bgHover.opacity(0.30), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else if availableModels.isEmpty {
            Text(errorText ?? "未返回模型")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(errorText == nil ? GatewayTheme.textTertiary : GatewayTheme.danger)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10)
                .background(GatewayTheme.bgHover.opacity(0.30), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(availableModels, id: \.self) { model in
                        Button {
                            toggle(model)
                        } label: {
                            HStack(spacing: 10) {
                                Text(model)
                                    .font(.system(size: 12, weight: .regular, design: .rounded))
                                    .foregroundStyle(GatewayTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                if isSelected(model) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundStyle(GatewayTheme.accent)
                                } else {
                                    Image(systemName: "circle")
                                        .font(.system(size: 13, weight: .light))
                                        .foregroundStyle(GatewayTheme.textTertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected(model) ? GatewayTheme.accentSubtle : GatewayTheme.bgHover.opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isOnlyExplicitSelection(model))
                    }
                }
            }
            .frame(maxHeight: 178)
        }
    }

    private var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedModels: [String] {
        parseModelText(modelsText)
    }

    private var isUsingAllModels: Bool {
        selectedModels.isEmpty
    }

    private var selectionSummary: String {
        if availableModels.isEmpty {
            return selectedModels.isEmpty ? "自动读取" : "已选 \(selectedModels.count) 个模型"
        }
        return isUsingAllModels ? "全部 \(availableModels.count) 个模型" : "已选 \(selectedModels.count) / \(availableModels.count)"
    }

    private func isSelected(_ model: String) -> Bool {
        isUsingAllModels || selectedModels.contains(model)
    }

    private func isOnlyExplicitSelection(_ model: String) -> Bool {
        !isUsingAllModels && selectedModels.count == 1 && selectedModels.first == model
    }

    private func toggle(_ model: String) {
        var selected = isUsingAllModels ? availableModels : selectedModels
        if let index = selected.firstIndex(of: model) {
            guard selected.count > 1 else { return }
            selected.remove(at: index)
        } else {
            selected.append(model)
        }
        let selectedSet = Set(selected)
        let ordered = availableModels.filter { selectedSet.contains($0) }
        if ordered.count == availableModels.count {
            modelsText = ""
        } else {
            modelsText = ordered.joined(separator: ", ")
        }
    }

    @MainActor
    private func reload() async {
        guard !normalizedBaseURL.isEmpty else {
            availableModels = []
            errorText = "地址为空"
            return
        }
        isLoading = true
        errorText = nil
        let base = normalizedBaseURL
        do {
            let models = try await OllamaModelListLoader.fetch(baseURL: base)
            guard base == normalizedBaseURL else { return }
            availableModels = models
            errorText = models.isEmpty ? "未返回模型" : nil
            trimSelection(to: models)
        } catch {
            guard base == normalizedBaseURL else { return }
            availableModels = []
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func trimSelection(to models: [String]) {
        guard !isUsingAllModels else { return }
        let availableSet = Set(models)
        let kept = models.filter { availableSet.contains($0) && selectedModels.contains($0) }
        if kept.isEmpty || kept.count == models.count {
            modelsText = ""
        } else {
            modelsText = kept.joined(separator: ", ")
        }
    }

    private func parseModelText(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            result.append(model)
        }
        return result
    }
}

private enum OllamaModelListLoader {
    static func fetch(baseURL: String) async throws -> [String] {
        try await fetchOptions(baseURL: baseURL).map(\.id)
    }

    static func fetchOptions(baseURL: String) async throws -> [RuntimeModelOption] {
        do {
            return try await fetchNativeTagOptions(baseURL: baseURL)
        } catch {
            return try await fetchOpenAICompatibleModels(baseURL: baseURL).map {
                RuntimeModelOption(
                    id: $0,
                    title: $0,
                    subtitle: "Ollama 模型",
                    badge: nil,
                    badgeColor: GatewayTheme.accentGreen,
                    trailing: nil
                )
            }
        }
    }

    private static func fetchOpenAICompatibleModels(baseURL: String) async throws -> [String] {
        guard let url = openAIEndpointURL(baseURL: baseURL, endpoint: "models") else {
            throw GatewayProviderError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw GatewayProviderError.invalidResponse
        }
        return cleanModels(arr.compactMap { $0["id"] as? String })
    }

    private static func fetchNativeTags(baseURL: String) async throws -> [String] {
        try await fetchNativeTagOptions(baseURL: baseURL).map(\.id)
    }

    private static func fetchNativeTagOptions(baseURL: String) async throws -> [RuntimeModelOption] {
        guard let url = rootEndpointURL(baseURL: baseURL, endpoint: "api/tags") else {
            throw GatewayProviderError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["models"] as? [[String: Any]] else {
            throw GatewayProviderError.invalidResponse
        }
        var seen = Set<String>()
        return arr.compactMap { item -> RuntimeModelOption? in
            let rawID = (item["name"] as? String) ?? (item["model"] as? String)
            guard let rawID else { return nil }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let details = item["details"] as? [String: Any]
            let parameterSize = (details?["parameter_size"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCloud = item["remote_host"] != nil || item["remote_model"] != nil || id.lowercased().contains("-cloud")
            let subtitleParts = [
                parameterSize?.isEmpty == false ? "\(parameterSize!) 参数" : nil,
                isCloud ? "云端模型" : "本地模型",
            ].compactMap { $0 }
            let capabilities = item["capabilities"] as? [String] ?? []
            let badge: String?
            let badgeColor: Color
            if !isCloud, capabilities.contains(where: { $0.lowercased() == "tools" }) {
                badge = "推荐"
                badgeColor = GatewayTheme.accentGreen
            } else if isCloud {
                badge = "云端"
                badgeColor = GatewayTheme.accentPurple
            } else {
                badge = nil
                badgeColor = GatewayTheme.accentGreen
            }
            return RuntimeModelOption(
                id: id,
                title: id,
                subtitle: subtitleParts.joined(separator: " · "),
                badge: badge,
                badgeColor: badgeColor,
                trailing: formattedSize(item["size"] as? NSNumber)
            )
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GatewayProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayProviderError.httpStatus(http.statusCode)
        }
    }

    private static func openAIEndpointURL(baseURL: String, endpoint: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

    private static func rootEndpointURL(baseURL: String, endpoint: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

    private static func cleanModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models {
            let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    private static func formattedSize(_ number: NSNumber?) -> String? {
        guard let number else { return nil }
        let bytes = number.doubleValue
        guard bytes >= 1_000_000 else { return nil }
        let gb = bytes / 1_000_000_000
        if gb >= 10 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.1f GB", gb)
    }
}

struct ProviderCatalogView: View {
    let onAdd: (ProviderKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProviderCategory.allCases) { category in
                ProviderCatalogSection(category: category, selected: nil, onTap: onAdd)
            }
        }
    }
}

struct ProviderCatalogSection: View {
    let category: ProviderCategory
    let selected: ProviderKind?
    let onTap: (ProviderKind) -> Void
    private let columns = [
        GridItem(.adaptive(minimum: 128, maximum: 164), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GatewayTheme.accentMuted)
                    .frame(width: 16)
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text(category.subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(ProviderKind.catalogCases(in: category)) { kind in
                    ProviderKindTile(kind: kind, isSelected: selected == kind) {
                        onTap(kind)
                    }
                }
            }
        }
    }
}

struct ProviderKindTile: View {
    let kind: ProviderKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? GatewayTheme.accent : GatewayTheme.accentSubtle)
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? GatewayTheme.bg : GatewayTheme.accent)
                    }
                    .frame(width: 34, height: 34)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GatewayTheme.accent)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(GatewayTheme.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                        .lineLimit(1)
                    Text(kind.shortDescription)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .frame(minHeight: 94, maxHeight: 102, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? GatewayTheme.accentSubtle : GatewayTheme.bgHover.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? GatewayTheme.accent.opacity(0.68) : GatewayTheme.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ProviderKindSelectorButton: View {
    let kind: ProviderKind
    let onSelect: (ProviderKind) -> Void
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(GatewayTheme.accentSubtle)
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(GatewayTheme.accent)
                }
                .frame(width: 31, height: 31)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                        .lineLimit(1)
                    Text(kind.category.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(width: 176, alignment: .leading)
            .background(GatewayTheme.bgHover.opacity(0.42), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            ProviderKindPickerPopover(selected: kind) { newKind in
                onSelect(newKind)
                showingPicker = false
            }
        }
    }
}

struct ProviderKindPickerPopover: View {
    let selected: ProviderKind
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GatewayTheme.accentMuted)
                Text("选择供应商")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Spacer(minLength: 0)
            }

            ForEach(ProviderCategory.allCases) { category in
                ProviderCatalogSection(category: category, selected: selected, onTap: onSelect)
            }
        }
        .padding(16)
        .frame(width: 540)
        .background(GatewayTheme.bg)
    }
}

struct ProviderConfigCard: View {
    @Binding var config: ProviderConfig
    let testResult: String?
    let onKindChanged: (ProviderKind) -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: $config.enabled)
                    .labelsHidden()
                    .tint(GatewayTheme.accentMuted)
                    .frame(width: 24)
                ProviderKindSelectorButton(kind: config.kind) { newKind in
                    kindBinding.wrappedValue = newKind
                }
                TextField("Provider ID", text: $config.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .frame(width: 128)
                Spacer()
                Button {
                    onTest()
                } label: {
                    Label("测试", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(GatewaySecondaryButtonStyle())
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }

            if config.kind != .echo {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        providerField("API 地址") {
                            TextField("https://api.example.com 或 http://127.0.0.1:11434", text: $config.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                        }
                        providerField("API Key") {
                            SecureField(apiKeyPlaceholder, text: $config.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                        }
                    }
                    providerField("模型") {
                        if config.kind == .codexCLI {
                            CodexCLIModelSelector(modelsText: $config.modelsText)
                        } else if config.kind == .ollama {
                            OllamaModelSelector(baseURL: config.baseURL, modelsText: $config.modelsText)
                        } else {
                            TextField("可选: gpt-5.1, qwen2.5:7b, mistral-small", text: $config.modelsText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                        }
                    }
                }
            } else {
                Text("本地诊断 provider，不调用外部模型。")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }

            if let testResult {
                Label(testResult, systemImage: testResult.hasPrefix("可用") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(testResult.hasPrefix("可用") ? GatewayTheme.accentGreen : GatewayTheme.accent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GatewayTheme.bgHover.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }

    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { config.kind },
            set: { newValue in
                config.kind = newValue
                onKindChanged(newValue)
            }
        )
    }

    private var apiKeyPlaceholder: String {
        if config.kind.needsAPIKey { return "必填" }
        return config.kind.commonlyUsesAPIKey ? "按供应商要求填写" : "可选"
    }

    private func providerField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(GatewayTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProviderSettingsView: View {
    @Bindable var model: GatewayModel

    var body: some View {
        ZStack {
            GatewayTheme.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                SoftIcon(systemName: "link", color: GatewayTheme.accent, size: 44)
                Text("运行源设置")
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Text("请在主窗口中扫描 Codex CLI 或 Ollama，并选择要同步到 iPhone 的模型。")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(28)
        }
        .frame(width: 420, height: 260)
    }
}

struct GatewayPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(GatewayTheme.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 7)
    }
}

struct GatewaySurface<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GatewayTheme.accentMuted)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(GatewayTheme.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

struct GatewayMetricPill: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GatewayTheme.accentMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(GatewayTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
        )
    }
}

struct WorkspacePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(GatewayTheme.accent)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
    }
}

struct WorkspaceSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(GatewayTheme.textSecondary)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(GatewayTheme.bgElevated.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
            )
    }
}

struct WorkspaceDestructiveButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(isActive ? GatewayTheme.danger : GatewayTheme.accentGreen)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(GatewayTheme.bgElevated.opacity(configuration.isPressed ? 0.72 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke((isActive ? GatewayTheme.danger : GatewayTheme.accentGreen).opacity(0.22), lineWidth: 1)
            )
    }
}

struct GatewayPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(GatewayTheme.bg)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(GatewayTheme.accent)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
    }
}

struct GatewaySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(GatewayTheme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(GatewayTheme.bgHover.opacity(configuration.isPressed ? 0.9 : 0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
            )
    }
}

struct GatewayQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(GatewayTheme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(GatewayTheme.bgHover.opacity(configuration.isPressed ? 0.7 : 0.38))
            )
    }
}

struct GatewayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(GatewayTheme.textSecondary)
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(GatewayTheme.bgHover.opacity(configuration.isPressed ? 0.9 : 0.62))
            )
    }
}

struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }
}

struct ProviderStatusRow: View {
    let provider: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider.reachable ? GatewayTheme.accentGreen : GatewayTheme.danger)
                    .frame(width: 8, height: 8)
                Text(provider.id)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(GatewayTheme.textPrimary)
                Spacer()
                Text(provider.reachable ? "\(provider.modelCount) 模型" : "不可用")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
            }
            if let detail = provider.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 11)
    }
}

struct EmptyStateLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(GatewayTheme.textTertiary)
            .padding(.vertical, 10)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(GatewayTheme.borderSubtle)
            .frame(height: 1)
    }
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func clockTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    formatter.dateStyle = .none
    return formatter.string(from: date)
}

// MARK: - 弹窗 UI

struct GatewayPopover: View {
    @Environment(\.openWindow) private var openWindow
    let model: GatewayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.pendingApprovals.isEmpty {
                approvals
            }

            runtimeSource

            if !model.pairedDevices.isEmpty {
                pairedDevices
            }

            footer
        }
        .padding(12)
        .frame(width: 306)
        .background(GatewayTheme.bg)
    }

    private var header: some View {
        popoverSurface {
            HStack(spacing: 12) {
                SoftIcon(systemName: "link", color: GatewayTheme.accent, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PhoneClaw")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textPrimary)
                    Text("Gateway")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }
                Spacer(minLength: 0)
                StatusBadge(title: statusTitle, color: statusColor)
            }
        }
    }

    private var runtimeSource: some View {
        popoverSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("当前运行源")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)

                HStack(spacing: 11) {
                    SoftIcon(systemName: activeProviderIcon, color: activeProviderColor, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeProviderTitle)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(GatewayTheme.textPrimary)
                            .lineLimit(1)
                        Text(activeProviderSubtitle)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(GatewayTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(activeProviderSummary)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(activeProviderSummaryColor)
                        .lineLimit(1)
                }
            }
        }
    }

    private var pairedDevices: some View {
        popoverSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("已配对设备")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)

                ForEach(Array(model.pairedDevices.prefix(2))) { device in
                    HStack(spacing: 10) {
                        SoftIcon(systemName: "iphone", color: GatewayTheme.textSecondary, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(GatewayTheme.textPrimary)
                                .lineLimit(1)
                            Text(deviceSubtitle(device))
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundStyle(GatewayTheme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.revoke(device)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(GatewayIconButtonStyle())
                        .help("撤销配对")
                    }
                }

                if model.pairedDevices.count > 2 {
                    Text("+ \(model.pairedDevices.count - 2) 台设备")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(GatewayTheme.textTertiary)
                }
            }
        }
    }

    private var approvals: some View {
        popoverSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("配对请求")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(GatewayTheme.textTertiary)

                ForEach(model.pendingApprovals) { req in
                    HStack(spacing: 8) {
                        SoftIcon(systemName: "iphone.badge.play", color: GatewayTheme.accent, size: 32)
                        Text(req.name)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(GatewayTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("拒绝") { model.deny(req) }
                            .buttonStyle(GatewaySecondaryButtonStyle())
                        Button("允许") { model.approve(req) }
                            .buttonStyle(GatewayPrimaryButtonStyle())
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("打开", systemImage: "macwindow")
            }
            .buttonStyle(GatewaySecondaryButtonStyle())
            .help("打开主窗口")

            Spacer(minLength: 0)

            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GatewayIconButtonStyle())
            .help("刷新")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(GatewayIconButtonStyle())
            .help("退出")
        }
        .padding(.top, 2)
    }

    private var failed: Bool {
        model.gatewayStatus.hasPrefix("启动失败") || model.providerConfigError != nil
    }

    private var statusTitle: String {
        failed ? "异常" : "运行中"
    }

    private var statusColor: Color {
        failed ? GatewayTheme.danger : GatewayTheme.accentGreen
    }

    private var activeConfig: ProviderConfig? {
        model.providerConfigs.first { $0.enabled }
            ?? model.providerConfigs.first { $0.kind == .ollama }
            ?? model.providerConfigs.first
    }

    private var activeProvider: ProviderStatus? {
        guard let config = activeConfig else {
            return model.providers.first
        }
        return model.providers.first { $0.id == config.name }
            ?? model.providers.first { $0.id == config.kind.defaultID }
            ?? model.providers.first
    }

    private var activeProviderTitle: String {
        activeConfig?.kind.title ?? activeProvider?.id ?? "运行源"
    }

    private var activeProviderSubtitle: String {
        activeConfig?.kind.shortDescription ?? "本地运行环境"
    }

    private var activeProviderIcon: String {
        activeConfig?.kind.systemImage ?? "point.3.connected.trianglepath.dotted"
    }

    private var activeProviderColor: Color {
        if activeProvider?.reachable == false || failed {
            return GatewayTheme.danger
        }
        return activeConfig?.kind == .ollama ? GatewayTheme.accent : GatewayTheme.accentPurple
    }

    private var activeProviderSummary: String {
        if activeProvider?.reachable == false || failed {
            return "不可用"
        }
        let count = activeProvider?.modelCount ?? configuredModelCount
        return count > 0 ? "\(count) 模型" : "读取中"
    }

    private var activeProviderSummaryColor: Color {
        if activeProvider?.reachable == false || failed {
            return GatewayTheme.danger
        }
        return GatewayTheme.textTertiary
    }

    private var configuredModelCount: Int {
        guard let text = activeConfig?.modelsText else { return 0 }
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        if let lastSeenAt = device.lastSeenAt {
            return "最近使用 \(relativeTime(lastSeenAt))"
        }
        return "配对于 \(relativeTime(device.pairedAt))"
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func popoverSurface(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(GatewayTheme.bgElevated.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GatewayTheme.borderSubtle, lineWidth: 1)
            )
    }
}
