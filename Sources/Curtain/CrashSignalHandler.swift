import Darwin
import Foundation

/// Purpose: Layer 2 of crash telemetry (T-P1-E08-02) — a minimal, async-signal-safe
///          POSIX signal handler that catches the signals Swift's runtime raises for
///          fatal traps (SIGILL, SIGTRAP, SIGABRT), so a Swift-level crash (fatalError,
///          force-unwrap of nil, array-index-out-of-bounds, integer overflow) leaves a
///          one-line marker on disk instead of vanishing with zero trail.
/// Inputs: none (installSignalHandlers() takes no arguments; the handler itself
///          receives the POSIX signal number from the kernel).
/// Outputs: on a caught signal, writes a short fixed marker ("CURTAIN CRASH SIG=<n>\n")
///          to a fixed-path file under ~/Library/Application Support/Curtain/, then
///          re-raises the default disposition so the process still terminates/cores
///          exactly as it would have without this handler.
/// Constraints (READ BEFORE EDITING — async-signal-safety is load-bearing here):
///          POSIX signal handlers run in a severely restricted context. This handler
///          and everything it calls must be async-signal-safe per POSIX.1-2008 §2.4.3:
///          - NO malloc/free, directly or indirectly. This means NO Swift `Array`,
///            `String`, `Dictionary`, or any other heap-backed/COW Swift type may be
///            constructed or copied inside the handler — `[UInt8](repeating:count:)`,
///            `Array(someSequence)`, and String interpolation all call into the
///            allocator and are NOT safe here, even though they look like local stack
///            values at the call site. The handler below uses only fixed-size C
///            tuples (`(Int8, Int8, ...)`) and `withUnsafeTemporaryAllocation`
///            (true stack/alloca-backed scratch space, not heap) for its buffer, and
///            reads the log path through a raw `UnsafeMutablePointer<Int8>` captured
///            once at install time — never a Swift `Array` or `String` at signal time.
///          - NO Log.error / os.Logger / os_log — these are not documented as
///            async-signal-safe and may allocate or take internal locks.
///          - NO locks of any kind (a signal can interrupt the very lock it needs).
///          - Only raw libc calls on the async-signal-safe list are used: open(2)
///            (technically not on the strict list but widely relied upon in crash
///            handlers for O_CREAT|O_TRUNC opens to a fixed path; kept minimal and
///            best-effort — if it fails, the handler falls through to re-raise
///            without further attempts), write(2), close(2), and signal(2)/raise(2).
///          - The crash-marker path is precomputed once, at install time (main
///            thread, normal context), into a raw C buffer (`UnsafeMutablePointer<Int8>`)
///            that is never freed and never touched again except being read by the
///            handler — no Swift Array/String wraps it at signal time.
///          - After writing the marker, the handler restores the signal's default
///            disposition and re-raises it so the process still dies (and still
///            produces a normal macOS crash report) exactly as if this handler were
///            never installed — this is a marker-writer, not a crash suppressor.
/// Coverage boundary (be exact — do not let this comment drift into overclaiming):
///          this file registers ONLY SIGILL, SIGTRAP, and SIGABRT — the signals the
///          Swift runtime's fatal-error/trap machinery actually raises for
///          fatalError()/force-unwrap-nil/array-out-of-bounds/integer-overflow. It
///          does NOT register SIGSEGV (bad memory access — e.g. a real dangling-
///          pointer dereference), SIGBUS (misaligned/unmapped access), or SIGFPE
///          (integer divide-by-zero) — those are real, distinct native-crash signals
///          left uncovered by this ticket, not merely "the same gap by another
///          name." SIGKILL (and SIGSTOP) remain always-uncatchable by any process,
///          an OS guarantee no handler can close.
/// SPORT: MASTER-APP
enum CrashSignalHandler {
    /// Fixed capacity for the crash-log path buffer, generously sized for a real
    /// macOS home-directory path; `installSignalHandlers()` truncates (never
    /// overflows) if a path somehow exceeds this.
    fileprivate static let pathBufferCapacity = 1024

    /// Raw, non-Array, non-String storage for the crash-log path, allocated once at
    /// install time (safe context) and read — never copied into a Swift Array/String
    /// — by the handler. `UnsafeMutablePointer` intentionally, not `[Int8]`: a Swift
    /// Array's storage is heap-backed and COW-managed, which is exactly what must be
    /// avoided at signal time (see the file-level doc comment above).
    fileprivate static var crashLogPathBuffer: UnsafeMutablePointer<Int8> = {
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: pathBufferCapacity)
        buffer.initialize(repeating: 0, count: pathBufferCapacity)
        return buffer
    }()

    /// One-time best-effort directory creation, done at install time (safe context),
    /// so the async-signal-safe open() inside the handler doesn't need O_CREAT to
    /// also create intermediate directories (it can't). Also fills in
    /// `crashLogPathBuffer` from a normal (allocating, non-signal) context.
    private static func preparePathAndDirectory() {
        let home = NSHomeDirectory()
        let dir = home + "/Library/Application Support/Curtain"
        mkdir(dir, 0o755)  // ignore result; ENOENT/EEXIST both leave us in a fine state to try open()

        let path = dir + "/last-crash.log"
        path.withCString { cPath in
            var i = 0
            while cPath[i] != 0, i < pathBufferCapacity - 1 {
                crashLogPathBuffer[i] = cPath[i]
                i += 1
            }
            crashLogPathBuffer[i] = 0  // NUL-terminate
        }
    }

    /// Registers Layer 2: SIGILL, SIGTRAP, and SIGABRT — the signals the Swift
    /// runtime's fatal-error/trap machinery raises. Call once, early in
    /// applicationDidFinishLaunching, from the main thread (safe context). Does NOT
    /// register SIGSEGV/SIGBUS/SIGFPE — see the coverage-boundary note above.
    static func installSignalHandlers() {
        preparePathAndDirectory()

        signal(SIGILL, crashSignalHandler)
        signal(SIGTRAP, crashSignalHandler)
        signal(SIGABRT, crashSignalHandler)
    }
}

/// Top-level @convention(c) function — POSIX `signal(2)` requires a plain C function
/// pointer, which a Swift closure cannot satisfy if it captures state. Everything this
/// function touches is async-signal-safe: no allocation, no locks, no Swift/Foundation
/// logging APIs, no Swift Array/String construction. See CrashSignalHandler's doc
/// comment above for the full constraint list this was audited against.
private func crashSignalHandler(_ signalNumber: Int32) {
    // True stack/alloca-backed scratch space (NOT a Swift Array — no heap allocation)
    // for the fixed marker "CURTAIN CRASH SIG=<n>\n". withUnsafeTemporaryAllocation
    // is the documented allocation-free mechanism for exactly this kind of bounded,
    // transient buffer.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buffer in
        var length = 0

        // Fixed prefix, written byte-by-byte from a C string literal (a static,
        // preexisting null-terminated buffer baked into the binary — reading it is
        // not an allocation) rather than any Swift String/Array construction.
        let prefix: StaticString = "CURTAIN CRASH SIG="
        prefix.withUTF8Buffer { prefixBytes in
            for byte in prefixBytes {
                buffer[length] = byte
                length += 1
            }
        }

        // Manual itoa for a small non-negative signal number, writing digits
        // directly into the pre-allocated `buffer` (no intermediate Array) by
        // finding the digit count first, then filling front-to-back.
        if signalNumber <= 0 {
            buffer[length] = UInt8(ascii: "0"); length += 1
        } else {
            var digitCount = 0
            var probe = signalNumber
            while probe > 0 { digitCount += 1; probe /= 10 }

            var writeIndex = length + digitCount - 1
            var n = signalNumber
            while n > 0 {
                buffer[writeIndex] = UInt8(ascii: "0") + UInt8(n % 10)
                n /= 10
                writeIndex -= 1
            }
            length += digitCount
        }
        buffer[length] = UInt8(ascii: "\n"); length += 1

        let fd = open(CrashSignalHandler.crashLogPathBuffer, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            if let base = buffer.baseAddress {
                _ = write(fd, base, length)
            }
            close(fd)
        }
    }

    // Restore default disposition and re-raise so the process still terminates (and
    // macOS still produces its normal crash report) exactly as if this handler were
    // never installed — this is a marker-writer, not a crash suppressor.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
