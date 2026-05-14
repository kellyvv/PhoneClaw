import Foundation
import os

// MARK: - PhoneClaw Structured Logging
//
// Four categories, sorted by signal value:
//
//   [Model]  — Load/unload lifecycle, one line per event
//   [Turn]   — Per-turn routing summary, one line per turn
//   [Perf]   — Inference benchmark, one line per generation
//   [Warn]   — Actionable warnings/errors only
//
// Design:
//   - Each category emits at most ONE line per event
//   - Key-value format for machine parseability
//   - No user content in default output (privacy)
//   - Single output channel: os.Logger only (Xcode console shows it)

enum PCLog {

    private static let logger = Logger(subsystem: "PhoneClaw", category: "App")
    private static let debugLogger = Logger(subsystem: "PhoneClaw", category: "Debug")

    // MARK: - [Debug] Free-form (Agent layer free text)
    //
    // 替代 AgentEngine 里到处的 `func log(_ message)` → print()。走 os.Logger,
    // 自动带时间戳, 可在 Console.app 按 subsystem 过滤, 不污染 stdout。
    // 调用方一般直接走顶层 `func log(...)` (AgentEngine.swift),内部转发到这里。

    static func debug(_ message: String) {
        debugLogger.debug("\(message, privacy: .public)")
    }

    // MARK: - [Model] Load / Unload

    static func modelLoaded(
        modelID: String,
        backend: String = "litert-gpu",
        loadMs: Double
    ) {
        logger.info("[Model] phase=load model=\(modelID) backend=\(backend) load_ms=\(Int(loadMs)) status=ok")
    }

    static func modelLoadFailed(modelID: String, reason: String) {
        logger.error("[Model] phase=load model=\(modelID) status=failed reason=\(reason)")
    }

    static func modelUnloaded() {
        logger.info("[Model] phase=unload status=ok")
    }

    // MARK: - [Turn] Per-turn routing summary

    static func turn(
        route: String,
        skillCount: Int,
        multimodal: Bool,
        inputChars: Int,
        historyDepth: Int,
        headroomMB: Int
    ) {
        logger.info("[Turn] route=\(route) skills=\(skillCount) multimodal=\(multimodal) input_chars=\(inputChars) history_depth=\(historyDepth) headroom_mb=\(headroomMB)")
    }

    // MARK: - [Perf] Inference benchmark

    static func perf(
        ttftMs: Int,
        chunks: Int,
        chunksPerSec: Double,
        headroomMB: Int
    ) {
        logger.info("[Perf] ttft_ms=\(ttftMs) chunks=\(chunks) chunks_per_sec=\(String(format: "%.1f", chunksPerSec)) headroom_mb=\(headroomMB)")
    }

    // MARK: - [Warn] Actionable warnings

    static func warn(_ tag: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logger.warning("[Warn] \(tag)\(suffix)")
    }

    static func error(_ tag: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logger.error("[Error] \(tag)\(suffix)")
    }

    // MARK: - [Event] Lifecycle events (bootstrap, teardown, etc.)

    static func event(_ tag: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logger.info("[Event] \(tag)\(suffix)")
    }

    // MARK: - Suppress LiteRT Runtime Noise

    /// Call once at startup to set TF_CPP_MIN_LOG_LEVEL=2 (WARNING+).
    /// Must be called before any LiteRT API usage.
    static func suppressRuntimeNoise() {
        setenv("TF_CPP_MIN_LOG_LEVEL", "2", 1)
    }

    // MARK: - Diagnostics Bundle (plan §3.2 DiagnosticsLogger.exportDiagnostics)

    /// 导出诊断包 — 给用户报 bug 时一键 dump 设备/runtime/最近事件。
    /// 不包含用户输入内容,只包含运行时元数据 + 设备规格 + LiteRT bootstrap 时间。
    /// 调用方:配置页 "Export Diagnostics" 按钮。
    static func exportDiagnosticsBundle() -> DiagnosticsBundle {
        DiagnosticsBundle(
            timestamp: Date(),
            deviceModel: deviceModelIdentifier(),
            systemVersion: systemVersionString(),
            litertBootstrapped: LiteRTBootstrap.isBootstrapped,
            litertBootstrapTimestamp: LiteRTBootstrap.bootstrapTimestamp,
            availableMemoryMB: Int(MemoryStats.headroomMB),
            note: "Diagnostics export. No user content included."
        )
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func systemVersionString() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

// MARK: - DiagnosticsBundle

/// 诊断信息快照,Codable 以便序列化导出。
struct DiagnosticsBundle: Codable {
    let timestamp: Date
    let deviceModel: String
    let systemVersion: String
    let litertBootstrapped: Bool
    let litertBootstrapTimestamp: CFAbsoluteTime
    let availableMemoryMB: Int
    let note: String

    /// 序列化为 JSON 字符串 (UTF-8)。失败返回 nil。
    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
