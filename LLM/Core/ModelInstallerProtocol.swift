import Foundation

// MARK: - Model Installer Protocol
//
// 模型资产的下载、安装、路径管理。独立于推理。
//
// 设计:
//   - 不 import 任何推理框架
//   - 下载进度通过 @Observable 属性暴露给 UI
//   - 路径解析支持 bundle / sandbox / symlink

/// 下载进度
public struct DownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double?
    public let currentFile: String?

    public init(
        bytesReceived: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil,
        currentFile: String? = nil
    ) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.currentFile = currentFile
    }

    /// 0.0 ~ 1.0，totalBytes 未知时返回 nil
    public var fractionCompleted: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(bytesReceived) / Double(total)
    }
}

public protocol ModelInstaller: AnyObject {

    /// 下载并安装模型
    func install(model: ModelDescriptor) async throws

    /// 删除已安装的模型
    func remove(model: ModelDescriptor) throws

    /// 取消正在进行的下载
    func cancelInstall(modelID: String)

    /// 查询安装状态
    func installState(for modelID: String) -> ModelInstallState

    /// 获取模型文件的本地路径 (nil = 未安装)
    func artifactPath(for model: ModelDescriptor) -> URL?

    /// 刷新安装状态 (检查磁盘)
    func refreshInstallStates()

    /// 各模型的下载进度 (可观察)
    var downloadProgress: [String: DownloadProgress] { get }

    /// 各模型的安装状态 (可观察)
    var installStates: [String: ModelInstallState] { get }
}
