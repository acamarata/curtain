import Foundation

/// Purpose: Detect Screen Sharing connect / disconnect / idle and fire callbacks.
/// How: polls `netstat` for an ESTABLISHED connection on the VNC port (5900).
///      lsof does NOT work here — the screensharing sockets are owned by _rmd/root
///      and are invisible to a user-context lsof (verified). Disconnect is debounced
///      (N consecutive misses) so a transient blip never kills a live session.
/// SPORT: MASTER-SESSIONMONITOR
final class SessionMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onIdleTimeout: (() -> Void)?

    private var timer: Timer?
    private var connected = false
    private var missCount = 0
    private var idleFired = false
    private let missLimit = 3          // ~6s at 2s poll
    private let pollInterval: TimeInterval = 2

    func start() {
        connected = isVNCEstablished()
        if connected { onConnect?() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        if isVNCEstablished() {
            missCount = 0
            if !connected { connected = true; idleFired = false; onConnect?() }
            if Settings.idleEnabled {
                if !idleFired, idleSeconds() >= Settings.idleMinutes * 60 {
                    idleFired = true
                    onIdleTimeout?()
                } else if idleSeconds() < Settings.idleMinutes * 60 {
                    idleFired = false
                }
            }
        } else if connected {
            missCount += 1
            if missCount >= missLimit { connected = false; missCount = 0; onDisconnect?() }
        }
    }

    // MARK: - Probes

    private func isVNCEstablished() -> Bool {
        let out = shell("/usr/bin/netstat", ["-an"])
        for line in out.split(separator: "\n") {
            if line.contains(".5900 ") && line.contains("ESTABLISHED") { return true }
        }
        return false
    }

    /// Seconds since the last HID (human) input event.
    private func idleSeconds() -> Int {
        let out = shell("/usr/sbin/ioreg", ["-c", "IOHIDSystem"])
        for line in out.split(separator: "\n") where line.contains("HIDIdleTime") {
            if let ns = line.split(separator: "=").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                return ns / 1_000_000_000
            }
        }
        return 0
    }

    private func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.launchPath = path; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
