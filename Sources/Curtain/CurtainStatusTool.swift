import CurtainCore
import Foundation

/// Purpose: The single MCP tool this app exposes, `curtain_status`. Returns a
///          read-only snapshot of Curtain's protection state so an external MCP
///          client (e.g. a KVM Bridge operator's own tooling, once the Mac is
///          reachable again) can check "is Curtain actually protecting this desk
///          right now" without any ability to change that state.
/// Inputs: none — `curtain_status` accepts zero parameters. `run(arguments:)`
///          takes a raw `[String: Any]` only because JSON-RPC always carries an
///          `arguments` object; every key in it is deliberately ignored (see
///          Constraints) rather than parsed into a typed struct, so there is no
///          parameter name that could ever be wired to a mutation by accident.
/// Outputs: a JSON object with exactly three fields: `armed` (Bool, from
///          `Settings.armed`), `remoteSessionActive` (Bool, from
///          `SessionCoordinator.isActive`), and `lastHeartbeatTimestamp`
///          (String?, the `timestamp` field of `heartbeat.json`, nil if the file
///          is missing/unreadable/malformed — the tool never throws just because
///          SessionMonitor hasn't ticked yet).
/// Constraints: HARD SECURITY BOUNDARY — this file must never call any Settings
///          setter or SessionCoordinator mutator. It reads exactly three existing
///          read-only surfaces: `Settings.armed` (getter), `coordinator.isActive`
///          (getter), and `heartbeat.json` (read-only file parse) — see
///          Settings.swift's `armed` getter and SessionCoordinator.swift's
///          `isActive`/`isArmed` computed properties for the accessors this tool
///          calls. `run(arguments:)` accepts an `arguments` dictionary purely to
///          satisfy the MCP `tools/call` shape (a client may send an empty object
///          or, in an adversarial call, extra fields like `{"armed": false}`) —
///          every key is ignored unconditionally; nothing in this file ever reads
///          a value out of that dictionary. This is proven by
///          CurtainStatusToolAdversarialTests, which crafts exactly such a
///          mutating-shaped payload and asserts `Settings.armed` is unchanged
///          after the call.
/// SPORT: MASTER-MCPSERVER
enum CurtainStatusTool {

    /// MCP tool name as advertised in `tools/list` and matched in `tools/call`.
    static let name = "curtain_status"

    /// Human-readable description surfaced to MCP clients in `tools/list`.
    static let toolDescription =
        "Read-only snapshot of Curtain's current protection state: whether it is armed, "
        + "whether a remote screen-sharing session is currently active, and the timestamp "
        + "of the last SessionMonitor heartbeat. Accepts no parameters and can never change "
        + "any Curtain setting."

    /// JSON Schema for this tool's input, advertised in `tools/list`. Deliberately an
    /// object with zero properties and `additionalProperties: false` — this is what an
    /// MCP client reads to know the tool takes no input; the adversarial test proves the
    /// *implementation* also ignores unexpected input even if a client ignores this schema.
    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [String: Any](),
        "additionalProperties": false
    ]

    /// Build the `curtain_status` result. `arguments` is accepted only because the MCP
    /// `tools/call` request shape always includes an `arguments` object — every key in
    /// it is ignored, by design (see the file-level Constraints doc above). There is no
    /// code path from any key of `arguments` to any Settings or SessionCoordinator write.
    @MainActor
    static func run(arguments: [String: Any], coordinator: SessionCoordinator) -> [String: Any] {
        _ = arguments  // Explicitly unused: no argument is ever consulted. See file doc.
        return [
            "armed": Settings.armed,
            "remoteSessionActive": coordinator.isActive,
            "lastHeartbeatTimestamp": readHeartbeatTimestamp() as Any
        ]
    }

    /// Read-only parse of the `timestamp` field from the heartbeat file
    /// `SessionMonitor` writes (T-P1-E10-01), at
    /// `~/Library/Application Support/Curtain/heartbeat.json`. Never writes to that
    /// file, never re-implements liveness detection — this only extracts the one
    /// field this tool contracts to return. Returns nil (not a thrown error) if the
    /// file is missing, unreadable, or malformed, so a machine that hasn't ticked
    /// yet (or where the enclosing directory doesn't exist) still returns a valid
    /// `curtain_status` result with `lastHeartbeatTimestamp: null` rather than
    /// failing the whole call.
    private static func readHeartbeatTimestamp() -> String? {
        guard
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Curtain", isDirectory: true)
        else { return nil }
        let fileURL = dir.appendingPathComponent("heartbeat.json")
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["timestamp"] as? String
    }
}
