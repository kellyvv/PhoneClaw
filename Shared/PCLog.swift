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
//   - LiteRT runtime noise suppressed via TF_CPP_MIN_LOG_LEVEL

enum PCLog {

    private static let logger = Logger(subsystem: "PhoneClaw", category: "App")

    // MARK: - [Model] Load / Unload

    static func modelLoaded(
        modelID: String,
        backend: String = "litert-cpu",
        loadMs: Double
    ) {
        let msg = "[Model] phase=load model=\(modelID) backend=\(backend) load_ms=\(Int(loadMs)) status=ok"
        logger.info("\(msg)")
        print(msg)
    }

    static func modelLoadFailed(modelID: String, reason: String) {
        let msg = "[Model] phase=load model=\(modelID) status=failed reason=\(reason)"
        logger.error("\(msg)")
        print(msg)
    }

    static func modelUnloaded() {
        let msg = "[Model] phase=unload status=ok"
        logger.info("\(msg)")
        print(msg)
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
        let msg = "[Turn] route=\(route) skills=\(skillCount) multimodal=\(multimodal) input_chars=\(inputChars) history_depth=\(historyDepth) headroom_mb=\(headroomMB)"
        logger.info("\(msg)")
        print(msg)
    }

    // MARK: - [Perf] Inference benchmark

    static func perf(
        ttftMs: Int,
        prefillTokens: Int,
        prefillTps: Double,
        decodeTokens: Int,
        decodeTps: Double,
        headroomMB: Int
    ) {
        let msg = "[Perf] ttft_ms=\(ttftMs) prefill_tokens=\(prefillTokens) prefill_tps=\(String(format: "%.1f", prefillTps)) decode_tokens=\(decodeTokens) decode_tps=\(String(format: "%.1f", decodeTps)) headroom_mb=\(headroomMB)"
        logger.info("\(msg)")
        print(msg)
    }

    // MARK: - [Warn] Actionable warnings

    static func warn(_ tag: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        let msg = "[Warn] \(tag)\(suffix)"
        logger.warning("\(msg)")
        print(msg)
    }

    static func error(_ tag: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        let msg = "[Error] \(tag)\(suffix)"
        logger.error("\(msg)")
        print(msg)
    }

    // MARK: - Suppress LiteRT Runtime Noise

    /// Call once at startup to set TF_CPP_MIN_LOG_LEVEL=2 (WARNING+).
    /// Must be called before any LiteRT API usage.
    static func suppressRuntimeNoise() {
        setenv("TF_CPP_MIN_LOG_LEVEL", "2", 1)
    }
}
