import Foundation

// MARK: - InstallState (v2 type — not yet wired)
//
// Per-model 安装状态。每个模型独立状态,互不干扰。
//
// 与现有 ModelInstallState 的关系 (v1.3 现状):
//   - LiteRTModelStore 仍用 legacy `ModelInstallState`(见 LLM/MLX/Installation/)
//   - UI 直接读 `installer.installStates: [String: ModelInstallState]`
//   - 本 enum 是 plan §3.2 设计的演化目标,定义先行,接入待 v2
//
// v2 触发条件:
//   - ModelDescriptor 加 SHA256 字段 → `verifying` 状态有真实工作量
//   - 否则当前 `failed(reason)` 已经能覆盖 corrupt 语义
//
// 演化时切换路径:
//   1. ModelInstaller protocol 改返回 InstallState
//   2. LiteRTModelStore 内部存储改 InstallState
//   3. UI ConfigurationsView/ContentView switch case 改 case 名
//   4. 删除 LLM/MLX/Installation/ModelInstallState.swift 里的旧 enum

/// Per-model 安装状态。
public enum InstallState: Equatable, Sendable {
    /// 未安装 — 磁盘上无模型文件
    case notInstalled
    /// 下载中 — 带结构化进度
    case downloading(progress: DownloadProgress)
    /// 下载完成，正在校验完整性（SHA256 / 文件大小）
    case verifying
    /// 已安装 — 模型文件就绪
    case installed(info: InstalledModelInfo)
    /// 文件损坏 — 存在但不可用（区别于 notInstalled）
    case corrupt(reason: String)
}

// MARK: - InstallState Queries

public extension InstallState {

    /// 是否已安装且可用
    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// 是否正在下载
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// 下载进度（仅 downloading 有值，0.0~1.0）
    var downloadFraction: Double? {
        if case .downloading(let p) = self { return p.fractionCompleted }
        return nil
    }

    /// 已安装的文件信息（仅 installed 有值）
    var installedInfo: InstalledModelInfo? {
        if case .installed(let info) = self { return info }
        return nil
    }
}

// MARK: - InstallState Transition Validation

public extension InstallState {

    /// 验证从 self 到 target 的转移是否合法。
    func canTransition(to target: InstallState) -> Bool {
        switch (self, target) {
        // notInstalled → downloading (开始安装)
        case (.notInstalled, .downloading): return true

        // downloading → downloading (进度更新)
        case (.downloading, .downloading): return true

        // downloading → verifying (下载完成)
        case (.downloading, .verifying): return true

        // downloading → notInstalled (取消下载)
        case (.downloading, .notInstalled): return true

        // verifying → installed (校验通过)
        case (.verifying, .installed): return true

        // verifying → corrupt (校验失败)
        case (.verifying, .corrupt): return true

        // installed → notInstalled (用户主动删除)
        case (.installed, .notInstalled): return true

        // corrupt → notInstalled (清理损坏文件)
        case (.corrupt, .notInstalled): return true

        // corrupt → downloading (重新下载)
        case (.corrupt, .downloading): return true

        // 任何状态都可以刷新到 installed（磁盘扫描发现文件就绪）
        case (_, .installed): return true

        // 任何状态都可以刷新到 notInstalled（磁盘扫描发现文件消失）
        case (_, .notInstalled): return true

        default: return false
        }
    }
}

// MARK: - Supporting Types
//
// DownloadProgress is defined in ModelInstallerProtocol.swift — reuse it.
// InstallState.downloading uses the existing DownloadProgress type directly.

/// 已安装模型的文件元信息。
public struct InstalledModelInfo: Equatable, Sendable {
    /// 磁盘上的文件大小 (bytes)
    public let fileSize: Int64
    /// 安装来源 (download / bundled / sideloaded)
    public let source: InstallSource
    /// 安装/验证时间
    public let verifiedAt: Date

    public init(fileSize: Int64, source: InstallSource = .downloaded, verifiedAt: Date = .now) {
        self.fileSize = fileSize
        self.source = source
        self.verifiedAt = verifiedAt
    }
}

/// 模型安装来源
public enum InstallSource: Equatable, Sendable {
    /// 用户下载
    case downloaded
    /// 应用内置
    case bundled
    /// 用户手动放入（Sideload / AirDrop 等）
    case sideloaded
}
