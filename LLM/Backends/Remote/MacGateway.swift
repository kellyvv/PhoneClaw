import Foundation
import Network

// MARK: - Mac Gateway (② 连接链路服务端 · CLI 可跑版)
//
// 局域网 Mac 网关:广播自己 + OpenAI 兼容反向代理转发本机 Ollama。
//   - NWListener 收手机的 HTTP (原生, 无依赖, 跟发现层同一套 Network 框架)
//   - /v1/* 转发给 upstream (默认 localhost:11434 Ollama), 流式 SSE 原样透传回手机
//   - LANAdvertiser 广播 _phoneclaw-llm._tcp + macID (复用发现层)
//
// 现放 CLI 测全链路;以后移进菜单栏 app。/pair 握手 + 鉴权下一步加。
// 简化前提 (受控客户端 RemoteInferenceService): 请求带 Content-Length (非 chunked);
// 响应一律 Connection: close (每请求一连接), 流式 body 靠关连接收尾。

// MARK: - 极简 HTTP 请求解析

struct GatewayHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// 从累积 buffer 解析;不完整 (header 没收全 / body 没收全) 返回 nil 让调用方继续收。
    static func parse(_ buffer: Data) -> GatewayHTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: sep) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }   // body 还没收全
        let body = contentLength > 0
            ? buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
            : Data()
        return GatewayHTTPRequest(
            method: String(parts[0]), path: String(parts[1]),
            headers: headers, body: body
        )
    }
}

// MARK: - 已配对设备

/// 已配对的手机设备 (给 UI 列表)。
struct PairedDevice: Identifiable, Sendable, Hashable, Codable {
    let id: String        // = token
    let name: String
    let pairedAt: Date
    var lastSeenAt: Date? = nil
    var token: String { id }
}

// MARK: - 网关

final class MacGateway {
    let port: UInt16
    private let macID: String
    private let name: String
    private let providers: [GatewayProvider]
    private let defaultProviderID: String
    /// 配对审批: 手机请求配对时调用 (传设备名, 返回是否允许)。nil = 自动允许 (CLI / 无 UI)。
    private let onPairRequest: (@Sendable (String) async -> Bool)?
    /// 配对设备列表变化时通知 (给 UI 刷新)。
    private let onPairedChanged: (@Sendable () -> Void)?
    /// listener 状态变化时通知 (给 UI 展示 ready / failed / stopped)。
    private let onRuntimeEvent: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private let lock = NSLock()
    private var paired: [PairedDevice]

    init(
        port: UInt16, macID: String, name: String,
        providers: [GatewayProvider], defaultProviderID: String,
        onPairRequest: (@Sendable (String) async -> Bool)? = nil,
        onPairedChanged: (@Sendable () -> Void)? = nil,
        onRuntimeEvent: (@Sendable (String) -> Void)? = nil
    ) {
        self.port = port; self.macID = macID; self.name = name
        self.providers = providers; self.defaultProviderID = defaultProviderID
        self.onPairRequest = onPairRequest
        self.onPairedChanged = onPairedChanged
        self.onRuntimeEvent = onRuntimeEvent
        self.paired = Self.loadPaired(macID: macID)
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MacGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        // 同一个 listener 既 serve HTTP 又广播 Bonjour —— 不能再开第二个 listener 抢同端口。
        listener.service = NWListener.Service(
            name: name, type: LANService.type, domain: nil,
            txtRecord: LANService.txtData(macID: macID)
        )
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let runtimeEvent = onRuntimeEvent
        let port = port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                runtimeEvent?("运行中 · 端口 \(port)")
            case .failed(let e):
                print("[gateway] listener failed: \(e)")
                runtimeEvent?("启动失败: \(e.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.start(queue: .global())
        self.listener = listener
        print("[gateway] serving :\(port) · providers=[\(providers.map { $0.id }.joined(separator: ","))] · 广播 \(LANService.type) id=\(macID)")
    }

    func stop() {
        listener?.cancel(); listener = nil
    }

    // MARK: - 每连接: 收完整请求 → 代理 → 流式回 → 关

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global())
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if let req = GatewayHTTPRequest.parse(buf) {
                Task { await self.proxy(req, to: conn) }
            } else if isComplete || error != nil || buf.count > 8_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)   // 还要更多
            }
        }
    }

    private func proxy(_ req: GatewayHTTPRequest, to conn: NWConnection) async {
        // 配对端点: 经审批 (onPairRequest; nil 则自动允许) → 记录设备 + 签发 token。
        if req.method == "POST", req.path == "/pair" {
            let deviceName = GatewayBody.deviceName(req.body) ?? "未知设备"
            let approved = await (onPairRequest?(deviceName) ?? true)
            guard approved else { sendStatus(conn, 403, "Pairing denied"); return }
            let token = UUID().uuidString
            recordPairedDevice(name: deviceName, token: token)
            onPairedChanged?()
            sendJSON(conn, 200, "{\"token\":\"\(token)\"}")
            return
        }
        // /v1/* 要 Bearer 鉴权
        guard isAuthorized(req) else { sendStatus(conn, 401, "Unauthorized"); return }
        switch (req.method, req.path) {
        case ("GET", "/v1/models"):
            await handleModels(conn)
        case ("POST", "/v1/model/prepare"):
            await handlePrepare(req, conn)
        case ("POST", "/v1/chat/completions"):
            await handleChat(req, conn)
        default:
            sendStatus(conn, 404, "Not Found")
        }
    }

    /// 聚合各 provider 的模型, id 加 "provider/" 前缀去歧义。
    private func handleModels(_ conn: NWConnection) async {
        var data: [[String: Any]] = []
        for p in providers {
            for model in await p.listModelInfo() {
                var item: [String: Any] = [
                    "id": "\(p.id)/\(model.id)",
                    "object": "model",
                    "owned_by": p.id,
                ]
                if let displayName = model.displayName, !displayName.isEmpty {
                    item["display_name"] = displayName
                }
                data.append(item)
            }
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["object": "list", "data": data]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"object\":\"list\",\"data\":[]}"
        sendJSON(conn, 200, body)
    }

    /// 选择模型时由 iOS 调用。Ollama 本地模型会在 provider 层触发真实加载;其它 provider no-op。
    private func handlePrepare(_ req: GatewayHTTPRequest, _ conn: NWConnection) async {
        let requested = GatewayBody.model(req.body) ?? ""
        let (providerID, bareModel) = routeModel(requested)
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            sendStatus(conn, 404, "Unknown provider"); return
        }
        guard !bareModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendStatus(conn, 400, "Missing model")
            return
        }
        do {
            let result = try await provider.prepare(model: bareModel)
            let payload: [String: Any] = [
                "ok": true,
                "provider": providerID,
                "model": bareModel,
                "status": result.status,
                "loaded": result.loaded,
                "detail": result.detail ?? "",
            ]
            sendJSON(conn, 200, gatewayJSONString(payload))
        } catch {
            print("[gateway] provider \(providerID) prepare error: \(error.localizedDescription)")
            sendStatus(conn, 502, "Provider \(providerID) prepare error: \(error.localizedDescription)")
        }
    }

    /// 按 model 前缀路由到对应 provider;无前缀走默认 provider。
    private func handleChat(_ req: GatewayHTTPRequest, _ conn: NWConnection) async {
        let requested = GatewayBody.model(req.body) ?? ""
        let (providerID, bareModel) = routeModel(requested)
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            sendStatus(conn, 404, "Unknown provider"); return
        }
        guard !bareModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendStatus(conn, 400, "Missing model")
            return
        }
        let health = await provider.health()
        guard health.reachable else {
            sendStatus(conn, 502, "Provider \(providerID) unavailable: \(health.detail ?? "unknown error")")
            return
        }
        if !health.models.isEmpty, !health.models.contains(bareModel) {
            sendStatus(conn, 404, "Model \(bareModel) not found on provider \(providerID)")
            return
        }
        let body = GatewayBody.rewriteModel(req.body, to: bareModel)
        sendChunk(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        do {
            try await provider.chat(model: bareModel, body: body, yield: { [weak self] line in self?.sendChunk(conn, line) })
            finish(conn)
        } catch {
            print("[gateway] provider \(providerID) error: \(error.localizedDescription)")
            sendSSEContent(conn, "Provider \(providerID) error: \(error.localizedDescription)")
            finish(conn)
        }
    }

    private func routeModel(_ requested: String) -> (providerID: String, bareModel: String) {
        if let slash = requested.firstIndex(of: "/") {
            return (
                String(requested[..<slash]),
                String(requested[requested.index(after: slash)...])
            )
        }
        return (defaultProviderID, requested)
    }

    // MARK: - 发送 helpers

    private func sendChunk(_ conn: NWConnection, _ s: String) {
        conn.send(content: Data(s.utf8), isComplete: false, completion: .contentProcessed { _ in })
    }

    private func finish(_ conn: NWConnection) {
        conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendStatus(_ conn: NWConnection, _ code: Int, _ text: String) {
        let body = gatewayJSONString(["error": text])
        sendJSON(conn, code, body, reason: HTTPReason.phrase(for: code))
    }

    private func sendJSON(_ conn: NWConnection, _ code: Int, _ body: String, reason: String = "OK") {
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendSSEContent(_ conn: NWConnection, _ text: String) {
        let payload: [String: Any] = ["choices": [["delta": ["content": "\n\(text)"]]]]
        sendChunk(conn, "data: \(gatewayJSONString(payload))\n\n")
    }

    private func isAuthorized(_ req: GatewayHTTPRequest) -> Bool {
        guard let auth = req.headers["authorization"], auth.hasPrefix("Bearer ") else { return false }
        let token = String(auth.dropFirst(7))
        return markDeviceSeenIfAuthorized(token: token)
    }

    private func markDeviceSeenIfAuthorized(token: String) -> Bool {
        let now = Date()
        var changed = false
        lock.lock()
        guard let idx = paired.firstIndex(where: { $0.token == token }) else {
            lock.unlock()
            return false
        }
        if paired[idx].lastSeenAt.map({ now.timeIntervalSince($0) > 30 }) ?? true {
            paired[idx].lastSeenAt = now
            persistPairedLocked()
            changed = true
        }
        lock.unlock()
        if changed { onPairedChanged?() }
        return true
    }

    /// 当前已配对设备 (给 UI)。
    func pairedDevicesSnapshot() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return paired.sorted { ($0.lastSeenAt ?? $0.pairedAt) > ($1.lastSeenAt ?? $1.pairedAt) }
    }

    /// 撤销一台设备的配对 (其 token 立即失效)。
    func revoke(token: String) {
        lock.lock()
        paired.removeAll { $0.token == token }
        persistPairedLocked()
        lock.unlock()
        onPairedChanged?()
    }

    private func recordPairedDevice(name: String, token: String) {
        let now = Date()
        lock.lock()
        paired.removeAll { $0.name == name }
        paired.append(PairedDevice(id: token, name: name, pairedAt: now, lastSeenAt: now))
        persistPairedLocked()
        lock.unlock()
    }

    private func persistPairedLocked() {
        Self.savePaired(paired, macID: macID)
    }

    private static func pairedDefaultsKey(macID: String) -> String {
        "PhoneClaw.gateway.pairedDevices.\(macID)"
    }

    private static func loadPaired(macID: String) -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: pairedDefaultsKey(macID: macID)),
              let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return list
    }

    private static func savePaired(_ list: [PairedDevice], macID: String) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: pairedDefaultsKey(macID: macID))
        }
    }
}

private enum HTTPReason {
    static func phrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}

private func gatewayJSONString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"JSON encoding failed\"}"
    }
    return string
}
