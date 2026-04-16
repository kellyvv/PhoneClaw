import Foundation

// MARK: - Sleeper Protocol (injectable time abstraction)

/// Abstraction over `Task.sleep` for deterministic testing.
/// Production code uses `RealSleeper`; tests inject `FakeSleeper`.
protocol Sleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

struct RealSleeper: Sleeper {
    func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}

// MARK: - Voice Turn Controller
//
// Manages the user-turn lifecycle independently from LiveModeEngine.
// Decouples VAD events (raw speech signals) from turn decisions.
//
// State machine:
//   listening ──[speechStart]──→ recording
//   recording ──[speechEnd]──→ pendingStop
//   pendingStop ──[speechStart within grace]──→ recording (merge samples)
//   pendingStop ──[grace expired]──→ confirmed → onTurnConfirmed
//
// The graceWindow (100ms) is NOT a second silence detector.
// It's a thin safety net for VAD boundary jitter at speechEnd.
// FluidAudio's minSilenceDuration (0.75s) is the primary silence detector.

class VoiceTurnController {

    enum Phase: Equatable {
        case listening
        case recording
        case pendingStop
    }

    // MARK: - Configuration

    /// Grace window after speechEnd. NOT a silence detector —
    /// just a thin buffer for VAD boundary jitter. Keep short.
    var graceWindow: TimeInterval = 0.1

    /// Defensive fuse for pendingStop. Should NEVER win over graceTask
    /// in normal operation. Only fires if graceTask fails due to a bug.
    var pendingStopTimeout: TimeInterval = 3.0

    // MARK: - Callbacks

    /// Fired when the user starts speaking (first speechStart in a turn).
    var onTurnStarted: (() -> Void)?

    /// Fired when the turn is confirmed (grace expired without resume).
    /// Delivers merged samples from all speech segments in this turn.
    var onTurnConfirmed: ((_ samples: [Float]) -> Void)?

    /// Fired when pendingStopTimeout expires (defensive, should be rare).
    var onTurnCancelled: (() -> Void)?

    // MARK: - State

    private(set) var phase: Phase = .listening
    private var accumulatedSamples: [Float] = []
    private var graceTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let sleeper: Sleeper

    // MARK: - Init

    init(sleeper: Sleeper = RealSleeper()) {
        self.sleeper = sleeper
    }

    // MARK: - VAD Event Handlers

    func handleSpeechStart() {
        switch phase {
        case .listening:
            phase = .recording
            accumulatedSamples = []
            onTurnStarted?()

        case .pendingStop:
            // User resumed within grace window → merge into same turn
            graceTask?.cancel()
            timeoutTask?.cancel()
            phase = .recording

        case .recording:
            break  // Already recording, ignore duplicate
        }
    }

    func handleSpeechEnd(samples: [Float]) {
        guard phase == .recording else { return }
        accumulatedSamples.append(contentsOf: samples)
        phase = .pendingStop

        graceTask?.cancel()
        graceTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: self?.graceWindow ?? 0.1)
            } catch { return }
            guard let self, self.phase == .pendingStop else { return }
            let samples = self.accumulatedSamples
            self.phase = .listening
            self.accumulatedSamples = []
            self.onTurnConfirmed?(samples)
        }

        // Defensive fuse — should never win over grace in normal operation
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(for: self?.pendingStopTimeout ?? 3.0)
            } catch { return }
            guard let self, self.phase == .pendingStop else { return }
            self.phase = .listening
            self.accumulatedSamples = []
            self.onTurnCancelled?()
        }
    }

    // MARK: - External Control

    /// Force-reset to listening. Used by barge-in and stop().
    func reset() {
        graceTask?.cancel()
        timeoutTask?.cancel()
        graceTask = nil
        timeoutTask = nil
        phase = .listening
        accumulatedSamples = []
    }
}
