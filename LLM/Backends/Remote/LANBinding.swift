import Foundation
import Network

// MARK: - LAN Binding (连接链路 · 第二层)
//
// 绑定 = 手机和某台 Mac 的持久关系。傻瓜化"选一次 → 以后静默自动重连"靠它。
//
// 关键设计:
//   - 绑定只认 Mac 的稳定 id (TXT 里的 macID), **不存 IP** —— 换网/换 IP 由发现层
//     重新 resolve 兜住, 绑定不失效。
//   - 传输无关:现在在同一局域网 → 发现层 resolve 直连;未来不在同网 → 云 relay
//     复用同一条 binding (secret 做鉴权)。所以 binding 里不绑死任何 transport。
//
// secret:配对握手时跟 Mac 换得。握手要 Mac 网关的 /pair 端点 (待 Mac 端做出来),
// 现阶段先占位, 把"持久化 + 按 macID 自动重连"这条核心能力跑通。

struct MacBinding: Codable, Equatable, Sendable {
    let macID: String
    var name: String
    var secret: String        // 配对握手得来 (现阶段占位 pending-handshake)
    var boundAt: Date
    var endpoint: String? = nil   // 配对时 resolve 到的直连根 http://ip:port;之后不靠发现层也能连
}

/// 绑定持久化。P1: UserDefaults JSON;secret 将来挪 Keychain。
final class BindingStore {
    static let defaultsKey = "PhoneClaw.remote.bindings"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [MacBinding] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([MacBinding].self, from: data) else { return [] }
        return list
    }
    func binding(macID: String) -> MacBinding? { all().first { $0.macID == macID } }
    func save(_ binding: MacBinding) {
        var list = all().filter { $0.macID != binding.macID }
        list.append(binding)
        persist(list)
    }
    func remove(macID: String) { persist(all().filter { $0.macID != macID }) }
    private func persist(_ list: [MacBinding]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Connection Manager (发现 + 绑定 + 重连)

/// 把发现层和绑定层拼起来:手机侧"列出 Mac → 绑定 → 按 macID 自动重连出 endpoint"。
@Observable
final class LANConnectionManager {
    let discovery = LANDiscoveryService()
    @ObservationIgnored let bindings: BindingStore
    @ObservationIgnored var lastPairError: String?   // 诊断:配对失败卡在哪一步(UI 显示)

    init(bindings: BindingStore = BindingStore()) {
        self.bindings = bindings
    }

    func startDiscovery() { discovery.start() }
    func stopDiscovery() { discovery.stop() }

    /// 配对绑定一台发现到的 Mac (现阶段 secret 占位;真握手待 Mac 网关 /pair)。
    @discardableResult
    func bind(_ mac: DiscoveredMac) -> MacBinding? {
        guard let macID = mac.macID else { return nil }   // 没 TXT id 不能绑 (没稳定身份)
        let binding = MacBinding(
            macID: macID,
            name: mac.name,
            secret: "(pending-handshake)",
            boundAt: Date()
        )
        bindings.save(binding)
        return binding
    }

    /// 按绑定自动重连:当前发现结果里按 macID 找回那台 Mac → resolve → 出 RemoteInferenceService base URL。
    /// 发现结果里没有 (Mac 离线/不在同网) → nil (未来这里接 relay)。
    func resolveEndpoint(for binding: MacBinding) async -> URL? {
        // 1) 绑定里存了直连地址 (配对时 resolve 到的) → 直接用, 不需要发现层在跑 (聊天页 discovery 已停)。
        if let ep = binding.endpoint, let url = URL(string: ep) {
            return url.appendingPathComponent("v1")
        }
        // 2) 旧绑定没存 → 靠发现层重新 resolve, 并把结果回写绑定 (自愈, 下次直连)。
        guard let mac = discovery.discovered.first(where: { $0.macID == binding.macID || $0.id == binding.macID }),
              let root = await resolveRoot(mac.endpoint) else { return nil }
        var healed = binding
        healed.endpoint = root.absoluteString
        bindings.save(healed)
        return root.appendingPathComponent("v1")
    }

    // MARK: 远程模型 ↔ 绑定

    /// modelID "remote::<macID>::<modelName>" → (endpoint /v1, token, 模型名)。给 RemoteInferenceService 的 resolver。
    func resolveRemoteModel(_ modelID: String) async -> (url: URL, token: String?, modelName: String)? {
        let parts = modelID.components(separatedBy: "::")
        guard parts.count == 3, parts[0] == "remote" else { return nil }
        guard let binding = bindings.binding(macID: parts[1]),
              let base = await resolveEndpoint(for: binding) else { return nil }
        return (base, binding.secret, parts[2])
    }

    /// 拉一台已绑定 Mac 的 /v1/models, 转成远程 ModelDescriptor (给 catalog 列进选择器)。
    func remoteModels(for binding: MacBinding) async -> [ModelDescriptor] {
        guard let base = await resolveEndpoint(for: binding) else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        req.setValue("Bearer \(binding.secret)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> ModelDescriptor? in
            guard let id = item["id"] as? String else { return nil }
            return Self.remoteModelDescriptor(
                macID: binding.macID,
                macName: binding.name,
                modelName: id,
                displayName: item["display_name"] as? String
            )
        }
    }

    /// 远程模型描述符:artifactKind=.remoteEndpoint → BackendDispatcher 路由到 RemoteInferenceService。
    static func remoteModelDescriptor(
        macID: String,
        macName: String,
        modelName: String,
        displayName: String? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: "remote::\(macID)::\(modelName)",
            displayName: "\(macName) · \(remoteDisplayTitle(for: modelName, displayName: displayName))",
            family: .gemma4,                 // 走 <|turn> 模板, RemoteInferenceService 反解析成 messages
            artifactKind: .remoteEndpoint,
            downloadURLs: [],
            fileName: "",
            expectedFileSize: 0,
            capabilities: ModelCapabilities(
                supportsVision: false, supportsAudio: false, supportsLive: false,
                supportsStructuredPlanning: false, supportsThinking: false,
                supportsPersistentSession: false, supportsSessionSnapshot: false,
                safeContextBudgetTokens: 3500, defaultReservedOutputTokens: 700
            ),
            runtimeProfile: MLXModelProfiles.gemma4_e2b
        )
    }

    static func remoteDisplayTitle(for modelName: String, displayName: String? = nil) -> String {
        let parts = remoteDisplayParts(for: modelName, displayName: displayName)
        if let subtitle = parts.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(parts.title)"
        }
        return parts.title
    }

    static func remoteDisplayParts(for model: ModelDescriptor) -> (title: String, subtitle: String?) {
        let displayParts = model.displayName
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if displayParts.count >= 3 {
            return (displayParts.dropFirst(2).joined(separator: " · "), displayParts[1])
        }
        let idParts = model.id.components(separatedBy: "::")
        guard idParts.count >= 3 else { return (model.displayName, nil) }
        return remoteDisplayParts(for: idParts[2])
    }

    static func remoteDisplayParts(for modelName: String, displayName: String? = nil) -> (title: String, subtitle: String?) {
        let parts = modelName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (displayName ?? modelName, nil) }
        let provider = parts[0]
        let model = parts[1]
        switch provider.lowercased() {
        case "codex":
            return (displayName ?? model, "Codex CLI")
        case "antigravity":
            return (displayName ?? model, "Antigravity CLI")
        case "ollama":
            return (displayName ?? model, "Ollama")
        default:
            return (displayName ?? model, provider)
        }
    }

    /// 解析一台发现到的 Mac 的网关根地址 http://host:port (去掉 IPv4 的 %scope)。
    func resolveRoot(_ endpoint: NWEndpoint) async -> URL? {
        guard let hp = await discovery.resolve(endpoint) else { return nil }
        return URL(string: "http://\(Self.urlHost(hp.host)):\(hp.port)")
    }

    /// resolve 出来的 host 整成能塞进 URL 的形式:IPv6 加方括号(%scope→%25),IPv4 去掉 %scope。
    static func urlHost(_ raw: String) -> String {
        if raw.contains(":") {   // IPv6
            return "[\(raw.replacingOccurrences(of: "%", with: "%25"))]"
        }
        return raw.contains("%") ? String(raw.prefix { $0 != "%" }) : raw
    }

    /// 配对握手:resolve → POST /pair 拿 token → 存绑定 (secret=token)。需要 Mac 网关在跑。
    static let defaultDeviceName = ProcessInfo.processInfo.hostName   // 跨平台 (iOS 无 Host/NSHost);UI 会传真实 UIDevice.current.name 覆盖

    @discardableResult
    func pair(_ mac: DiscoveredMac, deviceName: String = LANConnectionManager.defaultDeviceName) async -> MacBinding? {
        let key = mac.macID ?? mac.id   // 优先 TXT 稳定 id;没读到就用 Bonjour 服务名 (始终有)
        guard let root = await resolveRoot(mac.endpoint) else {
            lastPairError = "解析 Mac 地址失败(resolve 不到 host)"
            return nil
        }
        guard let token = await requestPairToken(root, deviceName: deviceName) else {
            lastPairError = "握手失败:\(root.absoluteString)/pair 没返回 token(Mac 没弹窗/未允许/连不上)"
            return nil
        }
        lastPairError = nil
        let binding = MacBinding(macID: key, name: mac.name, secret: token, boundAt: Date(), endpoint: root.absoluteString)
        bindings.save(binding)
        return binding
    }

    private func requestPairToken(_ root: URL, deviceName: String) async -> String? {
        var req = URLRequest(url: root.appendingPathComponent("pair"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // 给 Mac 端点「允许」留足时间
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": deviceName])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String else { return nil }
            return token
        } catch { return nil }
    }
}
