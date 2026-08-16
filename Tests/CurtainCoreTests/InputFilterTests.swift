import XCTest
@testable import CurtainCore

/// Purpose: Tap-lifecycle regression tests for InputFilter — start/stop/ensureActive
///          and both watchdog recovery paths (`.tapDisabledByTimeout` /
///          `.tapDisabledByUserInput`).
/// Honesty about coverage: a real CGEventTap requires Accessibility permission granted
///          to the test-runner process, which CI cannot do headlessly (out_of_scope
///          per this ticket). Two consequences, both intentional:
///          1. `start()` is exercised for real in these tests, but in CI it always
///             takes the "Accessibility not granted" failure branch (returns false,
///             `tap` stays nil) — so these tests prove start() fails gracefully
///             without crashing, not that a real tap installs successfully. That
///             success path (tap != nil) is only manually verifiable (see the
///             ticket's QA-C requirement) or on a machine with Accessibility already
///             granted to the test host.
///          2. The two watchdog recovery paths and the tap-thread callback dispatch
///             cannot be driven through a real CGEventTapCallBack in-process (it's a
///             bare C function pointer fired by the OS on a real tap). Instead they
///             are exercised through `simulateTapDisabled(_:)`, an additive seam that
///             is a byte-for-byte mirror of the callback's disabled-type branch (see
///             InputFilter.swift's `callback`), and observed via
///             `reenableInvocationCount`, a counter incremented by the same
///             `reenableFromCallback()` the real callback calls. This is a regression
///             test for the dispatch logic, not an end-to-end proof that the OS
///             actually re-delivers events after re-enabling — that remains
///             manually-verified.
/// SPORT: MASTER-INPUTFILTER
@MainActor
final class InputFilterTests: XCTestCase {

    // MARK: - (a) start() fails gracefully without Accessibility

    func testStartFailsGracefullyWithoutAccessibility() {
        let filter = InputFilter()
        // CI/test-runner processes are not Accessibility-trusted, so this exercises
        // the real "tap could not be created" branch — the one case CI CAN reach.
        let result = filter.start()

        if AXIsProcessTrusted() {
            // Rare (a developer's already-trusted local machine): the success path
            // ran for real. Don't assert false in that case — just confirm no crash
            // and clean up.
            XCTAssertTrue(result)
            XCTAssertTrue(filter.isTapInstalled)
            filter.stop()
        } else {
            XCTAssertFalse(result, "start() must return false, not crash, when the tap can't be created")
            XCTAssertFalse(filter.isTapInstalled)
        }
    }

    func testStartIsIdempotentWhenAlreadyInstalled() {
        // start() short-circuits with `if tap != nil { return true }` before ever
        // touching CGEvent.tapCreate again. Calling it twice must not crash or
        // double-install regardless of whether the first call actually got a tap.
        let filter = InputFilter()
        let first = filter.start()
        let second = filter.start()
        XCTAssertEqual(first, second)
        filter.stop()
    }

    // MARK: - (b) stop() invalidates the watchdog and tears down cleanly

    func testStopTearsDownCleanlyEvenWithoutAnInstalledTap() {
        let filter = InputFilter()
        // No crash calling stop() on a filter that was never started, or one whose
        // start() failed (the CI-reachable path) — cancelRetry()/watchdog?.invalidate()
        // must all be nil-safe.
        filter.stop()
        XCTAssertFalse(filter.isTapInstalled)
    }

    func testStopCancelsAnyPendingRetry() {
        let filter = InputFilter()
        // ensureActive/retryUntilTrusted are exercised below; here just prove stop()
        // clears a pending retry loop as part of its teardown contract.
        filter.retryUntilTrusted {}
        // If Accessibility happened to be trusted and start() succeeded synchronously
        // inline, retryUntilTrusted's fast path fires onSuccess without scheduling a
        // timer, so isRetryPending would already be false; the assertion after stop()
        // holds either way.
        filter.stop()
        XCTAssertFalse(filter.isRetryPending, "stop() must cancel any pending retryUntilTrusted loop")
    }

    // MARK: - (c) ensureActive() idempotency / no-tap safety

    func testEnsureActiveIsSafeNoOpWithoutAnInstalledTap() {
        let filter = InputFilter()
        // guard let t = tap else { return } — must not crash when there is no tap.
        filter.ensureActive()
        filter.ensureActive()
        XCTAssertFalse(filter.isTapInstalled)
    }

    func testRetryUntilTrustedFastPathFiresOnSuccessImmediatelyWhenAlreadyInstalled() {
        // Deliberately test the "already installed" branch (`if isTapInstalled {
        // onSuccess(); return }`) without depending on a real tap: start() may or may
        // not have installed one depending on the host's AX trust, so gate on the
        // actual state and only assert the behavior that branch guarantees.
        let filter = InputFilter()
        _ = filter.start()
        guard filter.isTapInstalled else {
            // Untrusted CI host: this specific fast-path can't be reached without a
            // real tap. Documented gap — see class-level comment. Skip rather than
            // assert a false negative.
            filter.stop()
            return
        }
        var fired = false
        filter.retryUntilTrusted { fired = true }
        XCTAssertTrue(fired, "retryUntilTrusted must call onSuccess synchronously when isTapInstalled is already true")
        XCTAssertFalse(filter.isRetryPending, "the fast path must not schedule a poll timer")
        filter.stop()
    }

    func testRetryUntilTrustedSchedulesAPollLoopWhenNotYetInstalled() {
        let filter = InputFilter()
        // Without calling start() first, isTapInstalled is false, so this always
        // reaches the "not yet installed" branch regardless of host AX trust,
        // reliably exercising the poll-loop-scheduling side (not the tap-creation
        // side, which is out of scope per the ticket).
        XCTAssertFalse(filter.isTapInstalled)
        filter.retryUntilTrusted {}
        XCTAssertTrue(filter.isRetryPending, "retryUntilTrusted must schedule a poll timer when not yet installed")
        filter.cancelRetry()
        XCTAssertFalse(filter.isRetryPending)
    }

    // MARK: - (d) .tapDisabledByTimeout recovery path re-arms

    func testTapDisabledByTimeoutRecoveryPathReArms() {
        let filter = InputFilter()
        let before = filter.reenableInvocationCount
        filter.simulateTapDisabled(.tapDisabledByTimeout)
        XCTAssertEqual(
            filter.reenableInvocationCount, before + 1,
            "the .tapDisabledByTimeout branch must invoke reenableFromCallback() exactly once")
    }

    // MARK: - (e) .tapDisabledByUserInput recovery path re-arms

    func testTapDisabledByUserInputRecoveryPathReArms() {
        let filter = InputFilter()
        let before = filter.reenableInvocationCount
        filter.simulateTapDisabled(.tapDisabledByUserInput)
        XCTAssertEqual(
            filter.reenableInvocationCount, before + 1,
            "the .tapDisabledByUserInput branch must invoke reenableFromCallback() exactly once")
    }

    func testOtherDisabledTypesDoNotTriggerReenable() {
        // Regression guard on the guard clause itself: an unrelated CGEventType must
        // NOT be treated as a disable notification.
        let filter = InputFilter()
        let before = filter.reenableInvocationCount
        filter.simulateTapDisabled(.keyDown)
        XCTAssertEqual(
            filter.reenableInvocationCount, before,
            "only .tapDisabledByTimeout/.tapDisabledByUserInput may trigger a re-arm")
    }

    // MARK: - (f) cancelRetry() actually stops a pending retry loop

    func testCancelRetryStopsAPendingRetryLoop() {
        let filter = InputFilter()
        filter.retryUntilTrusted {}
        XCTAssertTrue(filter.isRetryPending)
        filter.cancelRetry()
        XCTAssertFalse(filter.isRetryPending, "cancelRetry() must invalidate and clear the pending poll timer")
        // Idempotent: calling it again with nothing pending must not crash.
        filter.cancelRetry()
        XCTAssertFalse(filter.isRetryPending)
    }
}
