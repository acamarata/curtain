import Foundation
import IOKit.hid

/// Purpose: A second, independent input-filtering mechanism scoped ONLY to the KVM's
///          dedicated context: while active, only HID input from the registered
///          TinyPilot's specific USB device identity is allowed through; every other
///          physical HID device is genuinely BLOCKED — not merely detected or logged.
///          This exists because InputFilter (see that file's doc comment) cannot do
///          this job.
/// Why InputFilter cannot do this: InputFilter's CGEventTap classifies events using
///          `eventSourceStateID` — physical hardware reports sourceStateID == 1
///          (kCGEventSourceStateHIDSystemState), Screen Sharing's synthetic input
///          reports a different per-session ID. A TinyPilot KVM's emulated USB
///          keyboard/mouse is not software injection — it is genuine USB gadget-mode
///          HID traffic, so macOS reports it with sourceStateID == 1 too, identical to
///          a real keyboard at the desk. By the time an event reaches a CGEventTap its
///          originating device identity has already been abstracted away; sourceStateID
///          is a session-level concept with no device identity attached, so it cannot be
///          extended or special-cased to recognize "this specific USB device is the
///          KVM." IOHIDManager operates one layer lower, below CGEventTap, and exposes
///          each individual IOHIDDevice directly — vendor ID, product ID, and location
///          ID are readable per-device, and (crucially) each device can be opened and
///          controlled individually. That is the layer this subsystem uses.
/// How blocking actually works: `IOHIDManagerRegisterInputValueCallback` (an
///          input-VALUE callback) is observational only — it cannot suppress delivery
///          to the rest of the system, so an earlier draft of this subsystem that used
///          only that callback could detect a non-matching device but not truly block
///          it (a real gap, caught and fixed before this ticket shipped). Genuine
///          suppression instead uses `IOHIDDeviceOpen(_:kIOHIDOptionsTypeSeizeDevice)`,
///          documented by Apple as "used to open exclusive communication with the
///          device. This will prevent the system and other clients from receiving
///          events from the device" (IOHIDKeys.h). This subsystem therefore watches
///          for device ADDITION/REMOVAL (`IOHIDManagerRegisterDeviceMatchingCallback`
///          / `...RegisterDeviceRemovalCallback`) rather than input values: each time a
///          candidate device appears while the filter is effectively active, its
///          identity is resolved and matched; a non-matching device is opened with the
///          seize option (genuinely removing it from the system's normal HID delivery
///          path for as long as this filter holds it open), while the registered
///          device is left untouched so it passes through normally. Devices seized
///          while entering the KVM context, and any device that matches after
///          `deactivate()` is called, are all closed/released by `deactivate()`.
/// Non-conflict with InputFilter: InputFilter.swift is completely unmodified by this
///          subsystem and continues to do its existing job unchanged — blocking
///          desk-physical input from reaching apps generally, for the Screen-Sharing-
///          facing case. KVMInputFilter is additive: when activated, it independently
///          restricts input in the KVM's specific context to only the registered
///          device; it does not read, call, or alter anything in InputFilter. The two
///          run side by side without coordination because they operate on different
///          event pipelines (CGEventTap vs. IOHIDManager) for different purposes
///          (desk-vs-remote classification vs. per-device seizure).
/// Inputs: `Settings.kvmDeviceVendorID` / `.kvmDeviceProductID` / `.kvmDeviceLocationID`
///          (storage contract populated by E-11's setup-wizard pairing flow — not built
///          here). `activate()`/`deactivate()` explicitly gate whether the filter does
///          anything at all.
/// Outputs: `onBlockedDevice` fires for observability/diagnostics whenever a
///          non-matching device is actually seized (optional; nil by default).
/// Constraints: inert until both (a) `activate()` has been called and (b) a registered
///          identity exists in Settings — so a misconfigured or forgotten-active filter
///          can never block input anywhere else in the app; see `isEffectivelyActive`.
///          IOHIDManager device enumeration/open/close are the only places this
///          subsystem touches hardware; `KVMDeviceIdentity.matches` (the actual
///          decision logic) is pure and has zero IOHIDManager dependency, so it is
///          fully unit-testable without real hardware. Seizing a device is exclusive
///          but not destructive: `IOHIDDeviceClose` on `deactivate()` (or when the
///          device is unplugged) hands it straight back to the system.
/// Honesty: live verification against a real TinyPilot's actual USB vendor/product ID
///          (confirming they are stable across reconnects and match what E-11's pairing
///          flow captures), AND confirming `kIOHIDOptionsTypeSeizeDevice` genuinely
///          blocks a real physical keyboard/mouse end-to-end on this codebase's target
///          macOS versions, are remaining hardware-in-hand steps — NOT covered by this
///          ticket's automated tests, which exercise only the pure matching logic and
///          the activation-gating structure.
/// SPORT: MASTER-KVMINPUTFILTER
@MainActor
final class KVMInputFilter {
    private var manager: IOHIDManager?
    private var active = false
    /// Devices currently held open (seized) by this filter, keyed by their
    /// IOHIDDevice identity so `deactivate()` and the removal callback can look them
    /// up and close them individually. Never includes the registered/matching
    /// device — only non-matching devices are ever opened.
    private var seizedDevices: [ObjectIdentifier: IOHIDDevice] = [:]

    /// Fired on the main thread whenever a non-matching device is actually seized
    /// (i.e. genuinely blocked, not merely detected). Diagnostics/observability
    /// only — production code has no required listener.
    var onBlockedDevice: ((KVMDeviceIdentity) -> Void)?

    /// Fired on the main thread whenever a device matching the registered KVM
    /// identity is observed (T-P1-E13-03). Strictly additive and read-only: this
    /// closure is called from the exact same branch of `evaluate(device:)` that
    /// already decides "this is the registered device, leave it alone" — nothing
    /// about the decision itself changes, no new code path is introduced into the
    /// seize/pass-through logic, and there is no return value or throw that could
    /// feed back into `evaluate`. A listener that does nothing, does something
    /// slow, or throws inside its own body affects only that listener; it cannot
    /// alter whether a device is seized, and it has zero relationship to
    /// `CurtainController.shouldCover(uuid:isNew:)`, which reads only
    /// `Settings.kvmExcludedDisplayUUIDs` and has no dependency on this type at
    /// all. `nil` by default — matches `onBlockedDevice`'s pattern.
    var onMatchedDeviceActivity: (() -> Void)?

    /// True only when the caller has explicitly activated the filter AND a
    /// registered KVM identity exists in Settings. Both conditions are required so
    /// that calling `activate()` prematurely (before E-11's pairing flow has ever
    /// written an identity) is a no-op rather than a filter that seizes every HID
    /// device in existence. This is the guard that keeps the filter's blast radius
    /// scoped to "KVM context AND a KVM is actually registered."
    var isEffectivelyActive: Bool { active && registeredIdentity != nil }

    /// Reads the registered identity fresh from Settings on every check (not cached
    /// at activation time) so a change written mid-session — e.g. E-11's pairing
    /// flow completing while Curtain is already running — takes effect without
    /// requiring `activate()` to be called again.
    private var registeredIdentity: KVMDeviceIdentity? {
        let vendorID = Settings.kvmDeviceVendorID
        let productID = Settings.kvmDeviceProductID
        guard let vendorID, let productID else { return nil }
        return KVMDeviceIdentity(vendorID: vendorID, productID: productID, locationID: Settings.kvmDeviceLocationID)
    }

    /// Explicitly enter the KVM context. Narrow by design: this only starts the
    /// IOHIDManager watch and the seize decisions driven by `isEffectivelyActive` —
    /// it does not touch InputFilter, CGEventTap, or any other input path in the
    /// app. Callers are responsible for calling this only while genuinely in a
    /// KVM-dedicated context (e.g. the KVM's dedicated port/session) and
    /// `deactivate()` when leaving it, so the filter never lingers active outside
    /// that context.
    func activate() {
        active = true
        if manager == nil { startManager() }
    }

    /// Leave the KVM context. Safe to call even if never activated. Releases every
    /// device this filter seized (so a person's real keyboard/mouse never stays
    /// blocked after the KVM context ends) and tears down the IOHIDManager
    /// registration entirely (not merely flipping `active`), so a forgotten
    /// reference cannot keep seizing devices after the caller believes filtering
    /// has stopped.
    func deactivate() {
        active = false
        releaseAllSeizedDevices()
        stopManager()
    }

    private func startManager() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Register broadly (nil matching dictionary = all HID devices) rather than a
        // narrow matching dictionary keyed to the registered identity: the registered
        // identity can change at runtime (E-11 pairing can run after this filter is
        // already constructed), and we need to see — and individually decide on —
        // every candidate device, not just filter them out of enumeration. Matching
        // is therefore done in the device-matching callback via
        // `KVMDeviceIdentity.matches`, not via the IOHIDManager matching dictionary.
        IOHIDManagerSetDeviceMatching(mgr, nil)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, kvmDeviceAddedCallback, me)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, kvmDeviceRemovedCallback, me)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        // IOHIDManagerRegisterDeviceMatchingCallback only fires for devices that
        // attach AFTER registration; devices already present when activate() runs
        // (the common case — the KVM and any desk peripherals are already plugged
        // in before the user enters the KVM context) need to be evaluated too.
        evaluateAlreadyPresentDevices(mgr)
    }

    private func evaluateAlreadyPresentDevices(_ mgr: IOHIDManager) {
        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        for device in deviceSet {
            evaluate(device: device)
        }
    }

    private func stopManager() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    private func releaseAllSeizedDevices() {
        for (_, device) in seizedDevices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedDevices.removeAll()
    }

    /// Called from the device-matching (added) callback with the newly-seen device.
    /// Pure decision delegated entirely to `KVMDeviceIdentity.matches`; this method
    /// only decides what to do with the result — open-and-seize on a non-match,
    /// leave the matching device alone.
    fileprivate func evaluate(device: IOHIDDevice) {
        guard isEffectivelyActive, let registered = registeredIdentity else { return }
        guard let candidate = KVMDeviceIdentity(hidDevice: device) else { return }
        guard !registered.matches(candidate: candidate) else {
            // the registered KVM: leave it alone. Read-only observation hook
            // (T-P1-E13-03) fires here, alongside the existing early-return, purely
            // for optional notification consumers — it has no bearing on the
            // pass-through decision that was already made by reaching this branch.
            onMatchedDeviceActivity?()
            return
        }

        // Seize: this is the actual block. kIOHIDOptionsTypeSeizeDevice establishes
        // exclusive communication with the device, which Apple documents as
        // preventing "the system and other clients from receiving events from the
        // device" — i.e. genuine suppression, not detection.
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            Log.error("KVMInputFilter: failed to seize non-matching device (vendor \(candidate.vendorID), product \(candidate.productID)): IOReturn \(result)")
            return
        }
        seizedDevices[ObjectIdentifier(device)] = device
        onBlockedDevice?(candidate)
    }

    /// Called from the device-removal callback. If this filter had the device
    /// seized, drop our reference — the device is gone, so there is nothing left to
    /// close (`IOHIDDeviceClose` on an unplugged device is a harmless no-op, but
    /// skipping it avoids relying on that).
    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        seizedDevices.removeValue(forKey: ObjectIdentifier(device))
    }
}

/// Pure, independently-testable identity for a USB HID device. Zero IOHIDManager
/// dependency by design — every field is a plain value type, so `matches(candidate:)`
/// can be exercised with synthetic values and no real hardware, satisfying this
/// ticket's requirement that the matching logic be fully unit-testable. The
/// IOHIDDevice-reading initializer is a thin, separate convenience confined to the
/// hardware-facing call sites; it never participates in `matches`.
struct KVMDeviceIdentity: Equatable {
    let vendorID: Int
    let productID: Int
    /// Optional by design. A KVM's USB gadget-mode HID device's locationID encodes
    /// its USB port path, which can change across reconnects (different physical
    /// port, hub renumbering, or gadget-mode re-enumeration after the Pi reboots) —
    /// unlike vendor/product ID, which identify the device's USB descriptor and are
    /// stable regardless of which port it's plugged into. Treating locationID as
    /// required would make the filter spuriously reject the legitimate KVM after any
    /// reconnect that changes its port path, which is a false-block (defeats the
    /// KVM operator) rather than a false-allow (the security-relevant direction to
    /// avoid) — so it defaults to advisory: when both sides carry a locationID, it
    /// must match (a caller electing the stricter check gets it), but its absence on
    /// either side does not block an otherwise-matching vendor/product pair.
    let locationID: Int?

    init(vendorID: Int, productID: Int, locationID: Int?) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }

    /// Hardware-facing convenience initializer: resolves vendor/product/location ID
    /// from a real IOHIDDevice via IOHIDDeviceGetProperty. Returns nil if the
    /// device lacks a vendor or product ID (both required; location ID stays
    /// optional per the doc comment above). Kept separate from the plain
    /// memberwise init so `matches(candidate:)` and every unit test can construct
    /// and compare `KVMDeviceIdentity` values with zero IOHIDManager dependency.
    init?(hidDevice device: IOHIDDevice) {
        func intProperty(_ key: CFString) -> Int? {
            guard let ref = IOHIDDeviceGetProperty(device, key) else { return nil }
            return (ref as? NSNumber)?.intValue
        }
        guard let vendorID = intProperty(kIOHIDVendorIDKey as CFString),
            let productID = intProperty(kIOHIDProductIDKey as CFString)
        else { return nil }
        self.init(vendorID: vendorID, productID: productID, locationID: intProperty(kIOHIDLocationIDKey as CFString))
    }

    /// True when `candidate` is the registered device. `self` is the registered
    /// (expected) identity; `candidate` is what a live HID device reported.
    /// Vendor + product ID must always match exactly. locationID is checked only
    /// when BOTH sides have one — see the doc comment above for why an absent or
    /// differing locationID does not by itself fail the match.
    func matches(candidate: KVMDeviceIdentity) -> Bool {
        guard vendorID == candidate.vendorID, productID == candidate.productID else { return false }
        if let expectedLocation = locationID, let candidateLocation = candidate.locationID {
            return expectedLocation == candidateLocation
        }
        return true
    }
}

// Top-level C callbacks. IOHIDDeviceCallback is a bare C function pointer: it can't
// capture context, so the KVMInputFilter is recovered from `context`, matching
// InputFilter.swift's callback pattern of keeping the C-boundary function minimal and
// delegating the actual decision to a regular Swift method. Both callbacks fire on the
// run loop KVMInputFilter is scheduled on (the main run loop, per
// `IOHIDManagerScheduleWithRunLoop` above), so in practice they already run on the main
// thread — but Swift 6 strict concurrency has no static proof of that for a bare C
// callback, so the hop to `DispatchQueue.main.async` before touching the
// @MainActor-isolated instance is required (and harmless: same thread, immediate
// dispatch), mirroring InputFilter.swift's identical pattern for its own C callback.
private let kvmDeviceAddedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let unmanaged = Unmanaged<KVMInputFilter>.fromOpaque(context)
    DispatchQueue.main.async {
        unmanaged.takeUnretainedValue().evaluate(device: device)
    }
}

private let kvmDeviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let unmanaged = Unmanaged<KVMInputFilter>.fromOpaque(context)
    DispatchQueue.main.async {
        unmanaged.takeUnretainedValue().deviceRemoved(device)
    }
}
