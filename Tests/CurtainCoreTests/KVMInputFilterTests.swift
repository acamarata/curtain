import XCTest
@testable import CurtainCore

/// Purpose: Regression tests for `KVMDeviceIdentity.matches` — the pure,
///          IOHIDManager-independent matching logic this ticket requires be fully
///          unit-testable without real hardware.
/// Honesty about coverage: `KVMInputFilter` itself (the IOHIDManager wrapper) is
///          exercised only for its activation/deactivation lifecycle and
///          `isEffectivelyActive` gating below — those are structural/compile-time
///          checks that the guard logic is correct, not a proof that a real
///          IOHIDManager instance receives and correctly attributes real device
///          events. Live verification against a real TinyPilot's actual USB
///          vendor/product ID (confirming they are stable across reconnects and
///          match what E-11's pairing flow captures) is a remaining hardware-in-hand
///          step, not covered here. `matches(candidate:)` itself needs no such
///          caveat: it is a plain value-type comparison, fully exercised below.
/// SPORT: MASTER-KVMINPUTFILTER
@MainActor
final class KVMInputFilterTests: XCTestCase {

    // MARK: - KVMDeviceIdentity.matches — happy path

    func testMatchesIdenticalIdentityWithLocationID() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        XCTAssertTrue(registered.matches(candidate: candidate))
    }

    func testMatchesSameVendorProductWithNoLocationIDEitherSide() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        XCTAssertTrue(registered.matches(candidate: candidate))
    }

    // MARK: - KVMDeviceIdentity.matches — non-matching vendor/product

    func testDoesNotMatchDifferentVendorID() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        let candidate = KVMDeviceIdentity(vendorID: 0x9999, productID: 0xABCD, locationID: nil)
        XCTAssertFalse(registered.matches(candidate: candidate))
    }

    func testDoesNotMatchDifferentProductID() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0x9999, locationID: nil)
        XCTAssertFalse(registered.matches(candidate: candidate))
    }

    func testDoesNotMatchDifferentVendorAndProduct() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        let candidate = KVMDeviceIdentity(vendorID: 0x0001, productID: 0x0002, locationID: nil)
        XCTAssertFalse(registered.matches(candidate: candidate))
    }

    // MARK: - KVMDeviceIdentity.matches — locationID optional/advisory edge cases

    /// Documented decision (see KVMDeviceIdentity's doc comment): locationID is
    /// advisory, not required. A KVM's USB gadget-mode HID device's locationID
    /// encodes port path and can shift across reconnects, so vendor+product ID
    /// matching alone must succeed even when the registered identity carries a
    /// locationID the candidate lacks.
    func testMatchesWhenRegisteredHasLocationIDButCandidateDoesNot() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        XCTAssertTrue(registered.matches(candidate: candidate))
    }

    /// Symmetric case: candidate carries a locationID the registered identity does
    /// not. Still advisory-only, so vendor+product ID match is sufficient.
    func testMatchesWhenCandidateHasLocationIDButRegisteredDoesNot() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: nil)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        XCTAssertTrue(registered.matches(candidate: candidate))
    }

    /// When BOTH sides carry a locationID, it is checked, and a mismatch fails the
    /// match — a caller who wants the stricter check gets it whenever both values
    /// happen to be present, without that being required for the general case.
    func testDoesNotMatchWhenBothHaveDifferingLocationIDs() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1500_0000)
        XCTAssertFalse(registered.matches(candidate: candidate))
    }

    func testMatchesWhenBothHaveSameLocationID() {
        let registered = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        let candidate = KVMDeviceIdentity(vendorID: 0x1234, productID: 0xABCD, locationID: 0x1400_0000)
        XCTAssertTrue(registered.matches(candidate: candidate))
    }

    // MARK: - KVMInputFilter activation gating (structural, no real HID device)

    func testEffectivelyInactiveWhenNeverActivated() {
        let filter = KVMInputFilter()
        XCTAssertFalse(filter.isEffectivelyActive, "must stay inactive until activate() is called")
    }

    func testEffectivelyInactiveWhenActivatedWithNoRegisteredIdentity() {
        // Guards against the exact misconfiguration CR-C must verify: activate()
        // called (e.g. entering a KVM context) before E-11's pairing flow has ever
        // written an identity must NOT make the filter block every HID device.
        let suiteName = "KVMInputFilterTests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let original = Settings.d
        Settings.d = testDefaults
        defer {
            Settings.d = original
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertNil(Settings.kvmDeviceVendorID, "fresh suite must read as unregistered")

        let filter = KVMInputFilter()
        filter.activate()
        defer { filter.deactivate() }

        XCTAssertFalse(
            filter.isEffectivelyActive,
            "activate() alone (no registered identity) must not make the filter effectively active")
    }

    func testEffectivelyActiveWhenActivatedWithRegisteredIdentity() {
        let suiteName = "KVMInputFilterTests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let original = Settings.d
        Settings.d = testDefaults
        defer {
            Settings.d = original
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        Settings.kvmDeviceVendorID = 0x1234
        Settings.kvmDeviceProductID = 0xABCD

        let filter = KVMInputFilter()
        filter.activate()
        defer { filter.deactivate() }

        XCTAssertTrue(filter.isEffectivelyActive, "activate() + a registered identity must be effectively active")
    }

    func testDeactivateClearsEffectiveActivation() {
        let suiteName = "KVMInputFilterTests.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let original = Settings.d
        Settings.d = testDefaults
        defer {
            Settings.d = original
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        Settings.kvmDeviceVendorID = 0x1234
        Settings.kvmDeviceProductID = 0xABCD

        let filter = KVMInputFilter()
        filter.activate()
        XCTAssertTrue(filter.isEffectivelyActive)
        filter.deactivate()
        XCTAssertFalse(filter.isEffectivelyActive, "deactivate() must clear effective activation")
    }
}
