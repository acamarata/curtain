#!/usr/bin/env swift
//
// probe-detection.swift — on-device verification tool for Curtain's detection.
//
// Run: swift Scripts/probe-detection.swift
//
// Prints one timestamped line per second showing every raw signal Curtain can use
// to detect a Screen Sharing session: the CGSession capture key, the on-console
// flag, the presence of screen-sharing helper processes, and the netstat rows on
// the VNC ports (TCP 5900 + UDP 5900-5902). It ALSO diffs the full CGSession
// dictionary and prints any key that appears, disappears, or changes value — so a
// live connection reveals every session-dictionary signal macOS exposes, including
// ones we do not know about yet. Start it, then open a real Screen Sharing session
// to this Mac and watch which signals flip. Ctrl-C to stop.
//
// Reading the output during a live test:
//   captured=true            -> the authoritative capture key works; detection is solid.
//   tcp_estab>=1             -> classic VNC transport visible to netstat.
//   udp_peered>=1            -> High-Performance (UDP) transport visible to netstat.
//   dict change lines        -> candidate signals if none of the above fired.

import Cocoa
import CoreGraphics
import Foundation

let captureKey = "CGSSessionScreenIsCaptured"
let consoleKey = kCGSessionOnConsoleKey as String

func sessionDict() -> [String: Any] {
    (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
}

func boolValue(_ dict: [String: Any], _ key: String) -> Bool {
    (dict[key] as? Bool) ?? false
}

func shell(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        // A probe tool must fail loudly: a silent "" here once masked a dead
        // netstat path and made every socket count read as zero.
        print("!! probe helper failed to launch: \(path) — \(error)")
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func screenShareProcesses() -> String {
    let out = shell("/usr/bin/pgrep", ["-fl", "ScreenSharingAgent|ScreenSharingSubscriber|screensharingd"])
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "none" }
    // Collapse to a compact one-line summary of matched process names.
    let names = trimmed.split(separator: "\n").compactMap { line -> String? in
        line.split(separator: " ").dropFirst().first.map(String.init)
    }
    return names.isEmpty ? "present" : names.joined(separator: ",")
}

func isVNCLocal(_ local: String) -> Bool {
    local.hasSuffix(".5900") || local.hasSuffix(".5901") || local.hasSuffix(".5902")
}

func isRealPeer(_ foreign: String) -> Bool {
    foreign != "*.*" && !foreign.hasSuffix(".*")
}

func vncSockets() -> String {
    // netstat lives in /usr/sbin on macOS — NOT /usr/bin.
    let out = shell("/usr/sbin/netstat", ["-an"])
    var estab = 0      // ESTABLISHED inbound TCP on 5900 — a real classic VNC session
    var listen = 0     // 5900 LISTEN — always present when Screen Sharing is enabled
    var udpTotal = 0   // any UDP socket on 5900-5902 — informational
    var udpPeered = 0  // UDP on 5900-5902 with a real foreign peer — High-Performance session
    for raw in out.split(separator: "\n") {
        let line = String(raw)
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 5 else { continue }
        let proto = fields[0].lowercased()
        let local = fields[3]
        let foreign = fields[4]
        guard isVNCLocal(local) else { continue }
        if proto.hasPrefix("tcp") {
            let state = fields.count >= 6 ? fields[5] : ""
            if state == "ESTABLISHED", isRealPeer(foreign) {
                estab += 1
            } else if state == "LISTEN" {
                listen += 1
            }
        } else if proto.hasPrefix("udp") {
            udpTotal += 1
            if isRealPeer(foreign) { udpPeered += 1 }
        }
    }
    return "tcp_estab=\(estab) tcp_listen=\(listen) udp=\(udpTotal) udp_peered=\(udpPeered)"
}

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss"

func flatten(_ dict: [String: Any]) -> [String: String] {
    var flat: [String: String] = [:]
    for (k, v) in dict { flat[k] = String(describing: v) }
    return flat
}

print("Curtain detection probe — Ctrl-C to stop")

// Dump the full session dictionary once so the baseline is on record.
var lastDict = flatten(sessionDict())
print("CGSession dictionary at start:")
for (k, v) in lastDict.sorted(by: { $0.key < $1.key }) {
    print("  \(k) = \(v)")
}

print("time     | captured | onConsole | processes | netstat 5900-5902")

while true {
    let dict = sessionDict()
    let captured = boolValue(dict, captureKey)
    let onConsole = boolValue(dict, consoleKey)
    let stamp = formatter.string(from: Date())
    let line = "\(stamp) | "
        + "captured=\(captured) | "
        + "onConsole=\(onConsole) | "
        + "procs=\(screenShareProcesses()) | "
        + vncSockets()
    print(line)

    // Diff the full dictionary: any key that moves during a connection is a
    // candidate detection signal, even ones we have never heard of.
    let now = flatten(dict)
    for (k, v) in now.sorted(by: { $0.key < $1.key }) where lastDict[k] != v {
        print("\(stamp) | DICT \(k): \(lastDict[k] ?? "(absent)") -> \(v)")
    }
    for k in lastDict.keys.sorted() where now[k] == nil {
        print("\(stamp) | DICT \(k): removed")
    }
    lastDict = now

    fflush(stdout)
    Thread.sleep(forTimeInterval: 1.0)
}
