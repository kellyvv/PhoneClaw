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

    // MARK: - Suppress LiteRT Runtime Noise

    /// Call once at startup to set TF_CPP_MIN_LOG_LEVEL=2 (WARNING+).
    /// Must be called before any LiteRT API usage.
    static func suppressRuntimeNoise() {
        setenv("TF_CPP_MIN_LOG_LEVEL", "2", 1)
    }
}
