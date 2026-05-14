import XCTest
@testable import PhoneClawCore

// MARK: - RuntimeSessionTransition tests
//
// Plan §3.2 / §4.2 — validate the transition whitelist.
//
// Methodology: the transition table is a closed, finite set. We assert:
//   1. Every documented legal transition returns nil (allowed)
//   2. A representative sample of illegal transitions returns non-nil (rejected)
//   3. activeModelID/activeBackend/canGenerate/isGenerating/isLoading helpers
//      report correctly for each state shape

final class RuntimeSessionTransitionTests: XCTestCase {

    // MARK: - Legal transitions (per plan §4.2 state diagram)

    func testLegalTransitions() {
        let m = "model-a"
        let legal: [(RuntimeSessionState, RuntimeSessionState)] = [
            (.idle, .loading(modelID: m, phase: .loadingWeights)),
            (.loading(modelID: m, phase: .loadingWeights), .ready(modelID: m, backend: "cpu")),
            (.loading(modelID: m, phase: .loadingWeights), .failed(.init(message: "x", category: .other))),
            (.ready(modelID: m, backend: "cpu"), .generating(modelID: m, txnID: UUID())),
            (.ready(modelID: m, backend: "cpu"), .switching(
                from: BackendSwitch(modelID: m, backend: "cpu"),
                to: BackendSwitch(modelID: m, backend: "gpu")
            )),
            (.ready(modelID: m, backend: "cpu"), .unloading(modelID: m)),
            (.generating(modelID: m, txnID: UUID()), .ready(modelID: m, backend: "cpu")),
            (.generating(modelID: m, txnID: UUID()), .failed(.init(message: "oom", category: .outOfMemory))),
            (.switching(
                from: BackendSwitch(modelID: m, backend: "cpu"),
                to: BackendSwitch(modelID: m, backend: "gpu")
            ), .loading(modelID: m, phase: .loadingWeights)),
            (.switching(
                from: BackendSwitch(modelID: m, backend: "cpu"),
                to: BackendSwitch(modelID: m, backend: "gpu")
            ), .failed(.init(message: "engine", category: .engineCreationFailed))),
            (.unloading(modelID: m), .idle),
            (.failed(.init(message: "x", category: .other)), .idle),
            (.failed(.init(message: "x", category: .other)), .loading(modelID: m, phase: .loadingWeights)),
            (.failed(.init(message: "x", category: .other)), .unloading(modelID: m)),
        ]
        for (from, to) in legal {
            XCTAssertNil(
                RuntimeSessionTransition.validate(from: from, to: to),
                "transition should be allowed: \(from) → \(to)"
            )
        }
    }

    // MARK: - Illegal transitions (representative sample)

    func testIllegalTransitionsRejected() {
        let m = "model-a"
        let txnID = UUID()
        let illegal: [(RuntimeSessionState, RuntimeSessionState)] = [
            // idle cannot skip loading to ready
            (.idle, .ready(modelID: m, backend: "cpu")),
            // idle cannot go straight to generating
            (.idle, .generating(modelID: m, txnID: txnID)),
            // ready cannot loop back to itself
            (.ready(modelID: m, backend: "cpu"), .ready(modelID: m, backend: "gpu")),
            // generating cannot directly load
            (.generating(modelID: m, txnID: txnID), .loading(modelID: m, phase: .loadingWeights)),
            // generating cannot directly switch
            (.generating(modelID: m, txnID: txnID), .switching(
                from: BackendSwitch(modelID: m, backend: "cpu"),
                to: BackendSwitch(modelID: m, backend: "gpu")
            )),
            // unloading must go to idle, not directly back to loading
            (.unloading(modelID: m), .loading(modelID: m, phase: .loadingWeights)),
            // failed cannot directly generate (must recover first)
            (.failed(.init(message: "x", category: .other)), .generating(modelID: m, txnID: txnID)),
        ]
        for (from, to) in illegal {
            XCTAssertNotNil(
                RuntimeSessionTransition.validate(from: from, to: to),
                "transition should be rejected: \(from) → \(to)"
            )
        }
    }

    // MARK: - Query helpers

    func testActiveModelIDExtraction() {
        let m = "model-x"
        XCTAssertNil(RuntimeSessionState.idle.activeModelID)
        XCTAssertEqual(RuntimeSessionState.loading(modelID: m, phase: .loadingWeights).activeModelID, m)
        XCTAssertEqual(RuntimeSessionState.ready(modelID: m, backend: "cpu").activeModelID, m)
        XCTAssertEqual(RuntimeSessionState.generating(modelID: m, txnID: UUID()).activeModelID, m)
        XCTAssertEqual(RuntimeSessionState.unloading(modelID: m).activeModelID, m)
        // switching reports the target modelID (new session being prepared)
        XCTAssertEqual(
            RuntimeSessionState.switching(
                from: BackendSwitch(modelID: m, backend: "cpu"),
                to: BackendSwitch(modelID: m, backend: "gpu")
            ).activeModelID,
            m
        )
        XCTAssertNil(RuntimeSessionState.failed(.init(message: "x", category: .other)).activeModelID)
    }

    func testActiveBackendOnlyOnReady() {
        let m = "model"
        XCTAssertEqual(RuntimeSessionState.ready(modelID: m, backend: "gpu").activeBackend, "gpu")
        XCTAssertNil(RuntimeSessionState.idle.activeBackend)
        XCTAssertNil(RuntimeSessionState.loading(modelID: m, phase: .loadingWeights).activeBackend)
        XCTAssertNil(RuntimeSessionState.generating(modelID: m, txnID: UUID()).activeBackend)
    }

    func testIsStablePredicate() {
        let m = "model"
        XCTAssertTrue(RuntimeSessionState.idle.isStable)
        XCTAssertTrue(RuntimeSessionState.ready(modelID: m, backend: "cpu").isStable)
        XCTAssertTrue(RuntimeSessionState.failed(.init(message: "x", category: .other)).isStable)
        // Transient states are not stable
        XCTAssertFalse(RuntimeSessionState.loading(modelID: m, phase: .loadingWeights).isStable)
        XCTAssertFalse(RuntimeSessionState.generating(modelID: m, txnID: UUID()).isStable)
        XCTAssertFalse(RuntimeSessionState.unloading(modelID: m).isStable)
    }

    func testCanGenerateOnlyOnReady() {
        let m = "model"
        XCTAssertTrue(RuntimeSessionState.ready(modelID: m, backend: "cpu").canGenerate)
        XCTAssertFalse(RuntimeSessionState.idle.canGenerate)
        XCTAssertFalse(RuntimeSessionState.generating(modelID: m, txnID: UUID()).canGenerate)
        XCTAssertFalse(RuntimeSessionState.failed(.init(message: "x", category: .other)).canGenerate)
    }

    func testIsGeneratingOnlyOnGenerating() {
        let m = "model"
        XCTAssertTrue(RuntimeSessionState.generating(modelID: m, txnID: UUID()).isGenerating)
        XCTAssertFalse(RuntimeSessionState.ready(modelID: m, backend: "cpu").isGenerating)
        XCTAssertFalse(RuntimeSessionState.idle.isGenerating)
    }

    // MARK: - RuntimeError recovery semantics

    func testRuntimeErrorEqualsByValue() {
        let a = RuntimeError(message: "x", category: .engineCreationFailed, recoveryOptions: [.retry])
        let b = RuntimeError(message: "x", category: .engineCreationFailed, recoveryOptions: [.retry])
        XCTAssertEqual(a, b)
    }

    func testRecoveryOptionsAreOrderedAndUnique() {
        let err = RuntimeError(
            message: "gpu failed",
            category: .engineCreationFailed,
            recoveryOptions: [.switchBackend("cpu"), .retry]
        )
        XCTAssertEqual(err.recoveryOptions.count, 2)
        XCTAssertEqual(err.recoveryOptions[0], .switchBackend("cpu"))
        XCTAssertEqual(err.recoveryOptions[1], .retry)
    }
}
