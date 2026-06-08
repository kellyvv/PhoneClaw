import Foundation
import Network

// MARK: - LAN Discovery + Advertise (连接链路 · 第一层)
//
// 连接链路 = 局域网发现 + 绑定。本文件只管「发现」这一层:
//   - 手机侧 (real): LANDiscoveryService — NWBrowser 浏览, 自动列出局域网内的 Mac 网关。
//   - Mac 网关侧:      LANAdvertiser — NWListener 发布服务 + TXT (Mac 稳定 id)。
//     (测试期最小实现, 用来对测;以后菜单栏网关复用同一套 Network 框架代码。)
//
// 服务类型 _phoneclaw-llm._tcp;TXT 带 id (Mac 稳定身份, 供绑定层) + v (协议版本)。
// 绑定 / 配对 / 重连在下一步 (LANBinding.swift)。
//
// 设计: 发现只拿 (名字 + 稳定 id + endpoint);真要连时再 resolve 成 host:port
// 喂给 URLSession (RemoteInferenceService)。IP 不进 TXT —— 换网/换 IP 由 Bonjour
// 名字解析兜住, 绑定只认稳定 id。

enum LANService {
    static let type = "_phoneclaw-llm._tcp"
    static let txtKeyID = "id"
    static let txtKeyVersion = "v"
    static let version = "1"

    /// DNS-SD TXT (length-prefixed key=value)。广播器和网关共用,绕开 NWTXTRecord→Data 的 API 差异。
    static func txtData(macID: String) -> Data {
        var data = Data()
        for (k, v) in [(txtKeyID, macID), (txtKeyVersion, version)] {
            let bytes = Array("\(k)=\(v)".utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }
}

/// 发现到的一台 Mac 网关。
struct DiscoveredMac: Identifiable, Hashable, Sendable {
    let id: String            // 服务实例名 (Bonjour name) — 列表稳定 key
    let name: String          // 友好名 (= 服务名)
    let macID: String?        // TXT 里的稳定 id, 给绑定用 (TXT 未就绪时可能 nil)
    let endpoint: NWEndpoint  // 连接 / 解析用

    static func == (l: DiscoveredMac, r: DiscoveredMac) -> Bool { l.id == r.id && l.macID == r.macID }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Discovery (手机侧)

@Observable
final class LANDiscoveryService {
    private(set) var discovered: [DiscoveredMac] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        // .bonjourWithTXTRecord (不是 .bonjour) 才会把 TXT 带进 result.metadata —— 绑定层要 TXT 里的 macID。
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LANService.type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let macs: [DiscoveredMac] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var macID: String?
                if case let .bonjour(txt) = result.metadata {
                    macID = txt[LANService.txtKeyID]
                }
                return DiscoveredMac(id: name, name: name, macID: macID, endpoint: result.endpoint)
            }
            self.discovered = macs.sorted { $0.name < $1.name }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        discovered = []
    }

    /// 把一个 Bonjour endpoint 解析成 host:port (给 URLSession)。短连一次拿 remoteEndpoint。
    func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 6) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: UInt16)?, Never>) in
            // 强制 IPv4:手机 Bonjour 常把 Mac resolve 成 IPv6 link-local (fe80::%en0),
            // 那种地址塞进 URL 极易废(要方括号 + %scope 编码),URLSession 也难连。
            // LAN 上 Mac 一定有 IPv4 (192.168.x.x),直接用它最稳。
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let conn = NWConnection(to: endpoint, using: params)
            let once = LANOnceFlag()
            @Sendable func finish(_ value: (host: String, port: UInt16)?) {
                guard once.fire() else { return }
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        finish((LANDiscoveryService.hostString(host), port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let n, _): return n
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        @unknown default: return ""
        }
    }
}

// MARK: - Advertiser (Mac 网关侧;测试期最小实现)

final class LANAdvertiser {
    private var listener: NWListener?

    /// 发布 _phoneclaw-llm._tcp + TXT(id, v)。port=nil 让系统选。
    func start(name: String, macID: String, port: UInt16? = nil) throws {
        guard listener == nil else { return }
        let nwListener: NWListener
        if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            nwListener = try NWListener(using: .tcp, on: nwPort)
        } else {
            nwListener = try NWListener(using: .tcp)
        }
        nwListener.service = NWListener.Service(
            name: name, type: LANService.type, domain: nil, txtRecord: LANService.txtData(macID: macID)
        )
        nwListener.newConnectionHandler = { conn in
            // 测试期不真正 serve —— resolve 探测连进来, ready 后立即关。
            conn.stateUpdateHandler = { if case .ready = $0 { conn.cancel() } }
            conn.start(queue: .global())
        }
        nwListener.start(queue: .main)
        self.listener = nwListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// 单次触发保护 (resolve 的 continuation 防双 resume)。
final class LANOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}
