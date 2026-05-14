import XCTest
@testable import PhoneClawCore

// MARK: - GenerationTransaction tests
//
// Plan §3.2 / §7.2 — cancel safety + state machine correctness.
//
// Key invariants under test:
//   - Forward transitions: created → streaming → committed | cancelling → terminated
//   - State illegal-transition rejection (e.g. commit on .created stays in .created)
//   - didBeginStreaming flag correctness (Coordinator depends on this to decide
//     whether to await termination after a cancel)
//   - await termination resumes deterministically when state reaches terminal

final class GenerationTransactionTests: XCTestCase {

    func testInitialStateIsCreated() {
        let txn = GenerationTransaction(modelID: "test-model")
        XCTAssertEqual(txn.state, .created)
        XCTAssertFalse(txn.isTerminal)
        XCTAssertFalse(txn.didBeginStreaming)
    }

    func testBeginTransitionsToStreaming() {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        XCTAssertEqual(txn.state, .streaming)
        XCTAssertTrue(txn.didBeginStreaming)
        XCTAssertFalse(txn.isTerminal)
    }

    func testCommitFromStreamingReachesTerminal() {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        txn.commit()
        XCTAssertEqual(txn.state, .committed)
        XCTAssertTrue(txn.isTerminal)
    }

    func testCommitFromCreatedIsRejected() {
        let txn = GenerationTransaction(modelID: "test")
        txn.commit()
        // Plan rule: commit only valid from streaming; commit-from-created is no-op.
        XCTAssertEqual(txn.state, .created)
        XCTAssertFalse(txn.isTerminal)
    }

    func testCancelFromStreamingMovesToCancelling() {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        txn.cancel()
        XCTAssertEqual(txn.state, .cancelling)
        XCTAssertFalse(txn.isTerminal)  // cancelling is NOT terminal
        XCTAssertTrue(txn.didBeginStreaming)  // preserves pre-cancel state
    }

    func testCancelFromCreatedMovesToCancelling() {
        // Edge case: user cancels before stream produces first token.
        // didBeginStreaming stays false — Coordinator uses this to skip
        // `await txn.termination` (would deadlock otherwise).
        let txn = GenerationTransaction(modelID: "test")
        txn.cancel()
        XCTAssertEqual(txn.state, .cancelling)
        XCTAssertFalse(txn.didBeginStreaming)
    }

    func testMarkTerminatedFromCancellingReachesTerminal() {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        txn.cancel()
        txn.markTerminated(reason: .userCancelled)
        XCTAssertEqual(txn.state, .terminated(reason: .userCancelled))
        XCTAssertTrue(txn.isTerminal)
    }

    func testMarkTerminatedFromCreatedReachesTerminal() {
        // Cancel-before-stream path: coordinator calls markTerminated directly.
        let txn = GenerationTransaction(modelID: "test")
        txn.markTerminated(reason: .userCancelled)
        XCTAssertTrue(txn.isTerminal)
    }

    func testMarkTerminatedFromCommittedIsRejected() {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        txn.commit()
        // Cannot terminate a committed transaction — already terminal.
        txn.markTerminated(reason: .error("boom"))
        XCTAssertEqual(txn.state, .committed)  // unchanged
    }

    func testAwaitTerminationFastPathOnAlreadyTerminal() async {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()
        txn.commit()
        // Should return immediately — no suspension.
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await txn.termination
        }
        XCTAssertLessThan(elapsed, .milliseconds(50), "fast path should be near-instant")
    }

    func testAwaitTerminationResumesOnLateMarkTerminated() async {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()

        // Schedule a delayed markTerminated.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            txn.markTerminated(reason: .userCancelled)
        }

        // Await should suspend, then resume after markTerminated.
        await txn.termination
        XCTAssertTrue(txn.isTerminal)
    }

    func testMultipleAwaitersAllResume() async {
        let txn = GenerationTransaction(modelID: "test")
        txn.begin()

        // Three concurrent waiters.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await txn.termination }
            group.addTask { await txn.termination }
            group.addTask { await txn.termination }

            // Trigger termination after waiters are registered.
            try? await Task.sleep(for: .milliseconds(20))
            txn.markTerminated(reason: .userCancelled)

            await group.waitForAll()
        }
        XCTAssertTrue(txn.isTerminal)
    }

    func testTerminationReasonRoundTrip() {
        let cases: [GenerationTransaction.TerminationReason] = [
            .userCancelled,
            .error("inference failed"),
            .memoryPressure
        ]
        for reason in cases {
            let txn = GenerationTransaction(modelID: "test")
            txn.begin()
            txn.markTerminated(reason: reason)
            XCTAssertEqual(txn.state, .terminated(reason: reason))
        }
    }
}
