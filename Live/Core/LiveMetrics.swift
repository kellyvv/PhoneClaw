import Foundation

// MARK: - Live Turn Metrics
//
// Structured per-turn telemetry for the Live Mode pipeline.
// Each completed turn prints one summary line with E2E breakdown.
// Used to drive performance tuning and identify bottlenecks.

struct LiveTurnMetrics {
    let turnId: UInt64

    // Timestamps (CFAbsoluteTime)
    var turnConfirmedAt: CFAbsoluteTime = 0    // Turn confirmed (grace expired)
    var asrStartedAt: CFAbsoluteTime = 0       // ASR begin
    var asrCompletedAt: CFAbsoluteTime = 0     // ASR done
    var llmStartedAt: CFAbsoluteTime = 0       // LLM stream begin
    var llmFirstTokenAt: CFAbsoluteTime = 0    // LLM first token
    var firstSentenceAt: CFAbsoluteTime = 0    // First sentence yielded to TTS
    var ttsFirstChunkAt: CFAbsoluteTime = 0    // TTS first audio chunk ready
    var llmCompletedAt: CFAbsoluteTime = 0     // LLM stream done

    // Counts
    var tokenCount: Int = 0
    var speechSampleCount: Int = 0

    // Flags
    var interrupted: Bool = false

    // MARK: - Derived Metrics

    var speechDuration: TimeInterval {
        Double(speechSampleCount) / 16000.0
    }

    var asrLatency: TimeInterval {
        asrCompletedAt - asrStartedAt
    }

    var llmTTFB: TimeInterval {
        guard llmFirstTokenAt > 0 else { return 0 }
        return llmFirstTokenAt - llmStartedAt
    }

    var llmDuration: TimeInterval {
        guard llmCompletedAt > 0 else { return 0 }
        return llmCompletedAt - llmStartedAt
    }

    var firstSentenceLatency: TimeInterval {
        guard firstSentenceAt > 0 else { return 0 }
        return firstSentenceAt - turnConfirmedAt
    }

    var ttsFirstChunkLatency: TimeInterval {
        guard ttsFirstChunkAt > 0, firstSentenceAt > 0 else { return 0 }
        return ttsFirstChunkAt - firstSentenceAt
    }

    var e2eLatency: TimeInterval {
        guard ttsFirstChunkAt > 0 else { return 0 }
        return ttsFirstChunkAt - turnConfirmedAt
    }

    // MARK: - Summary

    func summary() -> String {
        let parts = [
            "Turn#\(turnId)",
            "E2E=\(ms(e2eLatency))ms",
            "(speech=\(ms(speechDuration))ms",
            "ASR=\(ms(asrLatency))ms",
            "TTFB=\(ms(llmTTFB))ms",
            "1st_sent=\(ms(firstSentenceLatency))ms",
            "TTS=\(ms(ttsFirstChunkLatency))ms)",
            "tokens=\(tokenCount)",
            interrupted ? "INTERRUPTED" : ""
        ].filter { !$0.isEmpty }
        return "[Live Metrics] " + parts.joined(separator: " ")
    }

    private func ms(_ t: TimeInterval) -> Int { Int(t * 1000) }
}
