import Foundation

// MARK: - InstallState
//
// Per-model 安装状态。每个模型独立状态，互不干扰。
// 用户可以一边用 E2B 聊天一边下载 E4B。
//
// 与现有 ModelInstallState 的关系:
//   这是 ModelInstallState 的演化版本，增加了:
//   1. verifying 状态（下载完做完整性检查）
//   2. corrupt 状态（区别于 notInstalled — 文件存在但损坏）
//   3. 结构化的 DownloadProgress（替代 completedFiles/totalFiles 元组）
//   4. installed 带 fileSize（方便 UI 显示）
//
// 迁移策略:
//   - 现有 LiteRTModelStore 内部先用 InstallState，对外还暴露 ModelInstallState
//   - 消费端逐步从 ModelInstallState 迁移到 InstallState
//   - 完成后删除旧 ModelInstallState enum

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
