import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Remote Mac 设置 (D · iOS 傻瓜化配对 UI)
//
// 傻瓜化流程:进来自动搜局域网内的 Mac → 点一台 → 配对(Mac 端点「允许」)→
// 那台 Mac 上的模型自动出现在下方,点选即切到远程推理。
//
// 用 engine.lan(发现/绑定)+ engine.refreshRemoteModels + config.selectedModelID,
// 全部走 AgentEngine 现有路径(远程后端只是第 4 个 InferenceService)。
//
// 视觉:严格对齐主界面的 ModelSwitcherSheet —— Theme.bg 底、自带居中标题、
// **纯平列表 + 发丝分隔线**(无卡片/描边/填充),品牌色只用一次(选中模型的勾 = accentMuted),
// 状态/已配对都走静默(textSecondary/Tertiary),不上绿条橙底。远程模型行剥掉机器名前缀。
//
// ⚠️ 这是 iOS UI,本机(无模拟器)没法编译验证 —— 改完务必 Xcode ⌘R 真机跑。

struct RemoteMacSettingsView: View {
    @Bindable var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pairingKey: String?
    @State private var status: String?
    @State private var statusOK = false

    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private var discoveredMacs: [DiscoveredMac] {
        engine.lan.discovery.discovered
    }

    private var remoteModels: [ModelDescriptor] {
        engine.availableModels.filter { $0.id.hasPrefix("remote::") }
    }

    /// 绑定/配对统一用的 key:优先 TXT 稳定 macID,读不到就用 Bonjour 服务名(始终有)。
    private func key(_ mac: DiscoveredMac) -> String { mac.macID ?? mac.id }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let status {
                            statusLine(status)
                        }
                        macSection
                        if !remoteModels.isEmpty {
                            remoteModelsSection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear {
            engine.lan.startDiscovery()
            Task { await engine.refreshRemoteModels() }
        }
        .onDisappear { engine.lan.stopDiscovery() }
    }

    // MARK: 头(居中标题 + 右上 ✕,跟 ModelSwitcherSheet 的标题同款静默)

    private var header: some View {
        ZStack {
            Text(tr("Mac 远程推理", "Mac Remote", "Mac リモート推論"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .opacity(0.72)

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(0.7)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: 状态(静默单行,不上卡片/绿底)

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: statusOK ? "checkmark.circle" : "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 局域网 Mac 列表(纯平 + 发丝线)

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(tr("局域网内的 Mac", "Macs on your LAN", "LAN内のMac"))

            if discoveredMacs.isEmpty {
                searchingRow
            } else {
                ForEach(Array(discoveredMacs.enumerated()), id: \.element.id) { idx, mac in
                    macEntry(mac)
                    if idx < discoveredMacs.count - 1 { separator }
                }
            }

            // 脚注只在空闲时给(教一遍流程);有状态后由状态条接管,避免「点允许」重复。
            if status == nil {
                Text(tr(
                    "点一台配对,在 Mac 上点「允许」。",
                    "Tap to pair; approve on the Mac.",
                    "タップしてペアリング、Mac側で「許可」。"
                ))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 10)
            }
        }
    }

    private var searchingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textTertiary)
            Text(tr("正在搜索局域网内的 Mac…", "Searching your LAN…", "LAN内のMacを検索中…"))
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    // 未配对 → 整行可点去配对;已配对 → 行不再触发配对, 末尾给「解除」按钮。
    @ViewBuilder
    private func macEntry(_ mac: DiscoveredMac) -> some View {
        if isPaired(mac) {
            pairedMacRow(mac)
        } else {
            Button { pair(mac) } label: { unpairedMacRow(mac) }
                .buttonStyle(.plain)
                .disabled(pairingKey != nil)
                .opacity(pairingKey != nil && pairingKey != key(mac) ? 0.45 : 1)
        }
    }

    private func unpairedMacRow(_ mac: DiscoveredMac) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
            Text(mac.name)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if pairingKey == key(mac) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textTertiary)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func pairedMacRow(_ mac: DiscoveredMac) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
            Text(mac.name)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(tr("已配对", "Paired", "ペアリング済み"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 12)
            Button { unpair(mac) } label: {
                Text(tr("解除", "Unpair", "解除"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pairingKey != nil)
        }
        .padding(.vertical, 14)
    }

    // MARK: Mac 上的模型(剥机器名前缀,选中=accentMuted 勾,跟 ModelSwitcherSheet 一致)

    private var remoteModelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(tr("Mac 上的模型", "Models on the Mac", "Mac上のモデル"))
            ForEach(Array(remoteModels.enumerated()), id: \.element.id) { idx, model in
                Button { select(model) } label: { modelRow(model) }
                    .buttonStyle(.plain)
                if idx < remoteModels.count - 1 { separator }
            }
        }
    }

    private func modelRow(_ model: ModelDescriptor) -> some View {
        let selected = engine.config.selectedModelID == model.id
        let subtitle = rowSubtitle(model)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle(model))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentMuted)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// 远程行只显示模型名 (从 id "remote::<macID>::<model>" 取 model,去掉机器名);本地用 displayName。
    private func rowTitle(_ model: ModelDescriptor) -> String {
        if model.id.hasPrefix("remote::") {
            return LANConnectionManager.remoteDisplayParts(for: model).title
        }
        return model.displayName
    }

    private func rowSubtitle(_ model: ModelDescriptor) -> String? {
        guard model.id.hasPrefix("remote::") else { return nil }
        return LANConnectionManager.remoteDisplayParts(for: model).subtitle
    }

    // MARK: 通用碎件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.borderSubtle)
            .frame(height: 1)
            .opacity(0.9)
    }

    // MARK: 逻辑(走 engine 现有路径,未改)

    private func isPaired(_ mac: DiscoveredMac) -> Bool {
        engine.lan.bindings.binding(macID: key(mac)) != nil
    }

    private func pair(_ mac: DiscoveredMac) {
        let k = key(mac)
        pairingKey = k
        // Mac 名 + 转圈已在列表行里;状态条只说「现在去 Mac 上点允许」这件事。
        status = tr(
            "请在 Mac 上点「允许」完成配对",
            "Approve the request on your Mac",
            "Mac側で「許可」を押してください"
        )
        statusOK = false
        Task {
            let binding = await engine.lan.pair(mac, deviceName: deviceName)
            await engine.refreshRemoteModels()
            pairingKey = nil
            if binding != nil {
                status = tr(
                    "已连接,选择下方模型即可",
                    "Connected — pick a model below",
                    "接続済み。下のモデルを選択してください"
                )
                statusOK = true
            } else {
                let reason = engine.lan.lastPairError ?? tr("Mac 没响应", "no response", "応答なし")
                status = tr(
                    "配对失败:\(reason)",
                    "Pairing failed: \(reason)",
                    "ペアリング失敗:\(reason)"
                )
                statusOK = false
            }
        }
    }

    private func unpair(_ mac: DiscoveredMac) {
        let k = key(mac)
        // 解除的若正是当前在用的 Mac, 它的远程模型随即失效 → 记下, 稍后回退。
        let wasActive = engine.config.selectedModelID.hasPrefix("remote::\(k)::")
        engine.lan.bindings.remove(macID: k)
        Task {
            await engine.refreshRemoteModels()
            if wasActive {
                // 回退到已装本地模型;一个都没有就落到默认(自然触发顶栏「请先下载模型」)。
                engine.config.selectedModelID = engine.installedModelID(preferredIDs: []) ?? ModelDescriptor.gemma4E2B.id
                engine.reloadModel()
            }
            // 设 status(@State)顺带触发重渲染:BindingStore 非 @Observable,
            // 否则解除后该行不会翻回「未配对」态。
            status = tr("已解除配对", "Unpaired", "ペアリングを解除しました")
            statusOK = false
        }
    }

    private func select(_ model: ModelDescriptor) {
        print("[RemoteMac] 用户选择远程模型 → \(model.id)")
        engine.config.selectedModelID = model.id
        // 真正切换:reloadModel 会持久化 + reconcile + coordinator.load(选中模型)。
        // 光 applyModelSelection 只设选择不加载 → 运行中的模型不会变 (之前的 bug)。
        engine.reloadModel()
        // 选中哪个模型由行尾的勾表示;状态条只确认「切好了、回聊天用」。
        status = tr(
            "已切换,回聊天即可用",
            "Switched — ready in chat",
            "切替完了。チャットで利用可能"
        )
        statusOK = true
    }
}
