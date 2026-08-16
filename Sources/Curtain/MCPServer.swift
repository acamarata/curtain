import CurtainCore
import Foundation
import Network

/// Purpose: Curtain's opt-in, off-by-default local MCP server. Hosts exactly one
///          tool, `curtain_status` (CurtainStatusTool.swift) — see that file for
///          the HARD SECURITY BOUNDARY this whole surface exists under. This file
///          owns only transport: accepting loopback connections, parsing minimal
///          MCP JSON-RPC requests, and dispatching `initialize` / `tools/list` /
///          `tools/call` to CurtainStatusTool.
/// Inputs: `Settings.mcpServerEnabled` (checked at `start()` time — the caller,
///          not this type, decides when to call `start()`, but `start()` itself
///          re-checks the flag so it can never be started while the flag is
///          false, closing the gap between "some caller forgot to check" and
///          "the server can't run"). A `SessionCoordinator` reference to read
///          `.isActive` from (never mutated).
/// Outputs: JSON-RPC 2.0 responses over a single-request-per-connection HTTP
///          POST, matching the MCP "Streamable HTTP" transport's minimal case
///          (no SSE upgrade — every response here is a complete, synchronous
///          reply, which is all `curtain_status` ever needs).
/// Constraints: TRANSPORT CHOICE RATIONALE — Curtain is a long-running menu-bar
///          process (not spawned per MCP call), so a stdio subprocess transport
///          (the shape most MCP clients default to, e.g. Claude Desktop's local
///          server config) is the wrong fit here: stdio MCP servers are designed
///          to be launched BY the client as a child process, but Curtain is
///          already running as an independent app before any client exists, and
///          re-architecting it to be spawned per-connection would fight its
///          entire lifecycle (menu bar icon, SessionCoordinator, the tick timer).
///          An in-process listener the already-running app hosts is the natural
///          fit — Network.framework's `NWListener` needs no third-party
///          dependency (Package.swift stays dependency-free) and gives an
///          explicit, inspectable bind address. The listener is created with
///          `NWEndpoint.Host` fixed to the loopback literal `"127.0.0.1"` — never
///          `.any` or a wildcard — so the OS itself refuses any non-local
///          connection attempt; MCPServerLoopbackBindTests asserts this
///          statically (constructs the same parameters this file uses and
///          confirms the resulting endpoint is loopback) rather than relying on
///          runtime firewall behavior. `start()` is idempotent (a second call
///          while already running is a no-op) and unconditionally re-checks
///          `Settings.mcpServerEnabled` itself — the gate lives at server-start
///          time, not only in whatever caller decides to invoke `start()`, so
///          there is no configuration reachable through the shipped Settings UI
///          (or any future one) that starts this listener while the flag reads
///          false. `@MainActor` because it holds a `SessionCoordinator`
///          reference (itself `@MainActor`) and calls into `CurtainStatusTool`,
///          which is also `@MainActor`; the underlying `NWListener`/`NWConnection`
///          callbacks hop back to the main queue explicitly (see `start()`'s
///          `queue: .main` argument) so no actor-isolation boundary is crossed
///          unsafely.
/// SPORT: MASTER-MCPSERVER
@MainActor
final class MCPServer {
    private let coordinator: SessionCoordinator
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Port the server listens on once started, or nil while stopped. Read by tests
    /// to open a real loopback connection against a running instance; not persisted
    /// anywhere (ephemeral per-launch, matching this being a purely local, opt-in
    /// dev/ops surface with no discovery mechanism beyond "ask the running app").
    private(set) var boundPort: UInt16?

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Start listening, but ONLY if `Settings.mcpServerEnabled` is true at the moment
    /// this is called. Re-checked here (not just by whatever call site decides to
    /// invoke `start()`) so the off-by-default gate is enforced architecturally, not
    /// just by convention — see the file-level Constraints doc. Idempotent: a second
    /// call while `listener` is already non-nil does nothing.
    func start(port: UInt16 = 0) {
        guard Settings.mcpServerEnabled else { return }
        guard listener == nil else { return }

        let params = NWParameters.tcp
        // Loopback-only: `requiredLocalEndpoint` MUST be set on `params` BEFORE
        // `NWListener(using:on:)` is constructed below — `NWListener`'s initializer
        // reads/copies `params` at construction time, so assigning this property
        // afterward is silently a no-op and the listener binds to all interfaces
        // (`.any`), not just loopback. This exact ordering bug was caught by CR-C
        // (T-P1-E14-01): the listener was confirmed reachable from the LAN and a
        // Tailscale interface before this fix. `port: 0` (the default) asks the OS
        // for an ephemeral free port, since this is a local dev/ops tool with no
        // fixed well-known port to publish. See
        // MCPServerLoopbackReachabilityTests.testServerRefusesNonLoopbackConnection
        // for the regression test — it opens a real off-loopback-bound outbound
        // connection attempt against a running instance, not just a static-constant
        // assertion (which is exactly the check that missed this bug originally).
        let requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: MCPServer.loopbackHost, port: requestedPort)
        guard let nwListener = try? NWListener(using: params, on: requestedPort) else { return }

        // Both handlers are guaranteed to run on `.main` (the queue passed to
        // `start(queue:)` below), so `MainActor.assumeIsolated` is sound here — the
        // alternative, hopping via `Task { @MainActor in ... }`, would make connection
        // accept/state handling asynchronous relative to the network callback for no
        // benefit, since we already know we're on the right queue.
        nwListener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        nwListener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .ready = state { self?.boundPort = self?.listener?.port?.rawValue }
                if case .failed = state { self?.stop() }
            }
        }
        listener = nwListener
        nwListener.start(queue: .main)
    }

    /// Fixed loopback literal — never `.any`/a wildcard interface. Kept as a shared
    /// constant so `start()` and the test asserting loopback-only binding read the
    /// exact same value rather than two independently-typed literals drifting apart.
    static let loopbackHost = NWEndpoint.Host("127.0.0.1")

    /// Stop listening and drop all open connections. Safe to call when already stopped.
    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        for (_, connection) in connections { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state { self?.drop(key) }
                if case .cancelled = state { self?.drop(key) }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, key: key, buffer: Data())
    }

    /// Cancel (if still tracked) and remove a connection. In the success path (a
    /// full request handled and its response sent) the key is already removed from
    /// `connections` by `receive(on:key:buffer:)` before this runs, so `cancel()`
    /// here is skipped — the connection closes naturally once `send`'s completion
    /// fires. This function is the actual cancel-and-remove path for the OTHER
    /// cases: a connection that failed/was cancelled by the peer, or one that
    /// disconnected/errored before ever completing a full request.
    private func drop(_ key: ObjectIdentifier) {
        connections[key]?.cancel()
        connections.removeValue(forKey: key)
    }

    /// Hard cap on accumulated request bytes (headers + body) per connection. This is
    /// a loopback-only, single-purpose local endpoint, so a well-behaved MCP client
    /// call is always tiny — this cap exists only to stop a slow/never-terminating
    /// peer from growing `buffer` unboundedly across repeated `receive` calls (CR-C
    /// finding, T-P1-E14-01). Any connection that exceeds this before a complete
    /// request is parsed is dropped outright.
    private static let maxRequestBytes = 65536

    /// Accumulate bytes until a full HTTP request (headers + Content-Length body) has
    /// arrived, then hand off to `handle(requestBody:)` and write the HTTP response.
    /// This is a minimal HTTP/1.1 parser sufficient for a single JSON POST per
    /// connection — no keep-alive, no chunked encoding, no other HTTP verbs, matching
    /// the "just enough MCP to discover and call curtain_status" scope of this ticket.
    private func receive(on connection: NWConnection, key: ObjectIdentifier, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }

                if buffer.count > MCPServer.maxRequestBytes {
                    self.drop(key)
                    return
                }

                if let (body, _) = MCPServer.splitCompletedHTTPRequest(buffer) {
                    let responseJSON = self.handle(requestBody: body)
                    let response = MCPServer.httpResponse(jsonBody: responseJSON)
                    // Cancel only AFTER the send's completion fires (not immediately after
                    // issuing it) — canceling right away raced NWConnection's own flush and
                    // was observed to abort the write mid-flight ("network connection was
                    // lost" on the client side) before URLSession ever received a response.
                    connection.send(
                        content: response,
                        completion: .contentProcessed { [weak self] _ in
                            MainActor.assumeIsolated { self?.drop(key) }
                        })
                    // Remove from the tracking dictionary now (bookkeeping only — does NOT
                    // cancel the live connection, see `drop(_:)`'s doc comment) so a second
                    // `stop()` call mid-flight can't double-cancel this connection.
                    self.connections.removeValue(forKey: key)
                    return
                }

                if isComplete || error != nil {
                    self.drop(key)
                    return
                }
                self.receive(on: connection, key: key, buffer: buffer)
            }
        }
    }

    /// Returns the JSON body once the full HTTP request (headers terminated by
    /// `\r\n\r\n`, followed by exactly `Content-Length` body bytes) has arrived; nil
    /// while still waiting on more bytes. Deliberately tolerant of any request path
    /// (`POST /` or `POST /mcp` etc. all route the same way) since this is a
    /// single-purpose local endpoint, not a general HTTP server.
    private static func splitCompletedHTTPRequest(_ buffer: Data) -> (body: Data, headers: String)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let contentLength =
            headerString
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = buffer[bodyStart..<(bodyStart + contentLength)]
        return (Data(body), headerString)
    }

    private static func httpResponse(jsonBody: Data) -> Data {
        let headers =
            "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(jsonBody.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(jsonBody)
        return response
    }

    // MARK: - JSON-RPC dispatch

    /// Dispatch one JSON-RPC 2.0 request to the minimal MCP method subset this
    /// server supports (`initialize`, `tools/list`, `tools/call`). Any other method
    /// gets a JSON-RPC "method not found" error — there is no default/fallback
    /// behavior that could accidentally expose more than these three methods.
    private func handle(requestBody: Data) -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
            let method = object["method"] as? String
        else {
            return MCPServer.encode(errorResponse(id: nil, code: -32700, message: "Parse error"))
        }
        let id = object["id"]

        switch method {
        case "initialize":
            return MCPServer.encode(
                jsonRPCResult(
                    id: id,
                    result: [
                        "protocolVersion": "2024-11-05",
                        "serverInfo": ["name": "curtain", "version": "1.0"],
                        "capabilities": ["tools": [String: Any]()]
                    ]))

        case "tools/list":
            return MCPServer.encode(
                jsonRPCResult(
                    id: id,
                    result: [
                        "tools": [
                            [
                                "name": CurtainStatusTool.name,
                                "description": CurtainStatusTool.toolDescription,
                                "inputSchema": CurtainStatusTool.inputSchema
                            ]
                        ]
                    ]))

        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            let toolName = params["name"] as? String
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard toolName == CurtainStatusTool.name else {
                return MCPServer.encode(errorResponse(id: id, code: -32602, message: "Unknown tool"))
            }
            // Every key of `arguments` (including any extraneous/mutating-shaped field
            // like `armed: false`) flows only into CurtainStatusTool.run(arguments:),
            // which ignores all of them unconditionally — see that file's doc comment.
            let statusResult = CurtainStatusTool.run(arguments: arguments, coordinator: coordinator)
            let text = MCPServer.jsonString(statusResult)
            return MCPServer.encode(
                jsonRPCResult(
                    id: id,
                    result: [
                        "content": [["type": "text", "text": text]]
                    ]))

        default:
            return MCPServer.encode(errorResponse(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func jsonRPCResult(id: Any?, result: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        response["id"] = id ?? NSNull()
        return response
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        response["id"] = id ?? NSNull()
        return response
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
