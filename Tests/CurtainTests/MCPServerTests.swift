import Network
import XCTest
@testable import Curtain
@testable import CurtainCore

/// Purpose: T-P1-E14-01 coverage for Curtain's opt-in Mac-side MCP server —
///          proves both the end-to-end `curtain_status` contract AND the HARD
///          SECURITY BOUNDARY (this surface can never mutate Settings/
///          SessionCoordinator state), by attempted misuse rather than by
///          absence-of-write-tools alone.
/// How: starts a real MCPServer (real NWListener bound to loopback on an
///      ephemeral port) against an isolated UserDefaults suite (same T-P1-E05-03
///      `Settings.d` seam every other CurtainCoreTests file uses) and a fresh
///      heartbeat.json under the real Application Support path (no injectable
///      path seam exists for it, matching SessionMonitorHeartbeatTests'
///      convention). Speaks raw HTTP/JSON-RPC over URLSession — deliberately not
///      through any MCP client SDK, since this project embeds the protocol
///      directly (see MCPServer.swift's transport rationale) and a raw call is
///      the most direct proof the server's own request/response cycle actually
///      works end to end.
/// Constraints: each test gets its own isolated UserDefaults suite and a fresh
///      MCPServer/port so tests never share listener state. `Settings.mcpServerEnabled`
///      is set true only inside tests that need a running server; the disabled-gate
///      test explicitly proves the opposite. `heartbeat.json` lives under a private
///      per-test-run temp directory via `SessionMonitor.heartbeatDirectoryOverride`
///      (the same seam `SessionMonitorHeartbeatTests` uses, pointed at a completely
///      separate directory from that file's) rather than the real Application
///      Support path — a prior version of this file wrote the hardcoded fixture
///      timestamp straight to the real, shared `heartbeat.json`, which a real
///      `SessionMonitor` instance started concurrently by `SessionMonitorHeartbeatTests`
///      (different XCTestCase, different test target, both linked into the same
///      `swift test` process) could clobber with a real current timestamp between
///      this file's write and its later read — see CHANGELOG.md's `[Unreleased]`
///      entry for the observed failure and the fix.
/// SPORT: MASTER-MCPSERVER
@MainActor
final class MCPServerTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!
    private var heartbeatURL: URL!
    private var tempDir: URL!
    private var coordinator: SessionCoordinator!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        suiteName = "MCPServerTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
        Settings.registerDefaults()

        // Isolated per-test-run directory, unique per test invocation and entirely
        // separate from SessionMonitorHeartbeatTests' own directory and from the
        // real Application Support path — see this file's Constraints doc above.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPServerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SessionMonitor.heartbeatDirectoryOverride = tempDir
        heartbeatURL = tempDir.appendingPathComponent("heartbeat.json")

        coordinator = SessionCoordinator()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        SessionMonitor.heartbeatDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.d = originalDefaults
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeHeartbeat(timestamp: String) throws {
        let payload: [String: Any] = [
            "timestamp": timestamp, "armed": true, "connected": false, "idleArmed": false, "idleFired": false
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: heartbeatURL, options: .atomic)
    }

    /// Starts a real MCPServer on an ephemeral loopback port and waits until it
    /// reports a bound port, so tests never race the async NWListener startup.
    private func startServer() throws -> UInt16 {
        Settings.mcpServerEnabled = true
        let s = MCPServer(coordinator: coordinator)
        server = s
        s.start()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in s.boundPort != nil }, object: nil)
        wait(for: [expectation], timeout: 5)
        guard let port = s.boundPort else {
            XCTFail("server did not bind a port")
            throw URLError(.cannotConnectToHost)
        }
        return port
    }

    /// Raw JSON-RPC POST against the running server, matching the minimal HTTP
    /// transport MCPServer.swift implements (single request/response per connection).
    private func rpcCall(port: UInt16, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { body["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let responseExpectation = expectation(description: "rpc response")
        var result: Result<[String: Any], Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { responseData, _, error in
            defer { responseExpectation.fulfill() }
            if let error {
                result = .failure(error)
                return
            }
            guard
                let responseData,
                let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else {
                result = .failure(URLError(.cannotParseResponse))
                return
            }
            result = .success(json)
        }.resume()
        wait(for: [responseExpectation], timeout: 5)
        return try result.get()
    }

    // MARK: - Off-by-default gate

    /// With the enable flag false (the registered default), start() must be a
    /// complete no-op: no listener, no bound port. This is the architectural
    /// enforcement point CR-C requires — checked inside start() itself, not only by
    /// whichever caller decides whether to invoke it.
    func testServerDoesNotStartWhenFlagIsFalse() {
        XCTAssertFalse(Settings.mcpServerEnabled, "precondition: flag defaults to false")
        let s = MCPServer(coordinator: coordinator)
        server = s
        s.start()

        // Give any (incorrect) async startup a moment to happen, then assert it didn't.
        let notStartedExpectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { notStartedExpectation.fulfill() }
        wait(for: [notStartedExpectation], timeout: 2)

        XCTAssertNil(s.boundPort, "server must not bind any port while mcpServerEnabled is false")
    }

    // MARK: - End-to-end functional test

    /// Enable the flag, start the server, call curtain_status over a real loopback
    /// HTTP connection, and assert every field matches known test-setup state.
    func testCurtainStatusReturnsKnownState() throws {
        Settings.armed = true
        try writeHeartbeat(timestamp: "2026-08-15T12:00:00Z")
        let port = try startServer()

        let listResponse = try rpcCall(port: port, method: "tools/list")
        guard let result = listResponse["result"] as? [String: Any],
            let tools = result["tools"] as? [[String: Any]]
        else { return XCTFail("tools/list did not return a tools array: \(listResponse)") }
        XCTAssertEqual(tools.count, 1, "server must expose exactly one tool")
        XCTAssertEqual(tools.first?["name"] as? String, "curtain_status")

        let callResponse = try rpcCall(
            port: port, method: "tools/call", params: ["name": "curtain_status", "arguments": [String: Any]()])
        guard let callResult = callResponse["result"] as? [String: Any],
            let content = callResult["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String,
            let statusData = text.data(using: .utf8),
            let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        else { return XCTFail("tools/call did not return decodable status content: \(callResponse)") }

        XCTAssertEqual(status["armed"] as? Bool, true)
        XCTAssertEqual(status["remoteSessionActive"] as? Bool, false)
        XCTAssertEqual(status["lastHeartbeatTimestamp"] as? String, "2026-08-15T12:00:00Z")
    }

    // MARK: - Adversarial read-only boundary test

    /// The HARD SECURITY BOUNDARY test. Enumerates the tool list (exactly one:
    /// curtain_status), confirms its schema has zero mutating parameters, then
    /// actually invokes curtain_status with an injected `armed: false` argument (and
    /// a second, differently-shaped injection attempt) and proves — by reading
    /// Settings.armed/SessionCoordinator state back AFTER the call, not merely by
    /// asserting the tool list length — that neither call had any effect.
    func testAdversarialCallsCannotMutateState() throws {
        Settings.armed = true
        try writeHeartbeat(timestamp: "2026-08-15T12:00:00Z")
        let port = try startServer()

        // 1. Tool enumeration + schema shape.
        let listResponse = try rpcCall(port: port, method: "tools/list")
        guard let result = listResponse["result"] as? [String: Any],
            let tools = result["tools"] as? [[String: Any]]
        else { return XCTFail("tools/list malformed: \(listResponse)") }
        XCTAssertEqual(tools.count, 1, "exactly one tool must be exposed, ever")
        guard let schema = tools.first?["inputSchema"] as? [String: Any] else {
            return XCTFail("curtain_status must advertise an inputSchema")
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        XCTAssertTrue(properties.isEmpty, "curtain_status's schema must define zero parameters")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        // 2. Attempted misuse: inject a mutating-shaped `armed: false` argument.
        XCTAssertTrue(Settings.armed, "precondition before attack 1")
        let attack1 = try rpcCall(
            port: port, method: "tools/call",
            params: ["name": "curtain_status", "arguments": ["armed": false]])
        XCTAssertNotNil(attack1["result"], "server must still answer (ignore, not error on, extra input)")
        XCTAssertTrue(Settings.armed, "Settings.armed must be UNCHANGED after an injected armed:false argument")

        // 3. A second attack shape: try to disarm AND flag a fabricated session-end.
        let attack2 = try rpcCall(
            port: port, method: "tools/call",
            params: [
                "name": "curtain_status",
                "arguments": ["armed": false, "remoteSessionActive": true, "setArmed": false]
            ])
        XCTAssertNotNil(attack2["result"])
        XCTAssertTrue(Settings.armed, "Settings.armed must still be UNCHANGED after a second injection attempt")
        XCTAssertFalse(coordinator.isActive, "SessionCoordinator state must be UNCHANGED by any curtain_status call")

        // 4. A call naming a nonexistent/mutating-sounding tool must be rejected, not silently run.
        let attack3 = try rpcCall(
            port: port, method: "tools/call",
            params: ["name": "curtain_disarm", "arguments": [String: Any]()])
        XCTAssertNotNil(attack3["error"], "an unknown tool name must return a JSON-RPC error, never a result")
        XCTAssertTrue(Settings.armed, "Settings.armed must be UNCHANGED after an unknown-tool call attempt")
    }

    // MARK: - Loopback-only bind

    /// Static assertion (per MCPServer.swift's Constraints doc) that the fixed host
    /// literal this server always binds to is the loopback address. Kept alongside
    /// (not instead of) `testServerRefusesNonLoopbackConnection` below — a static
    /// constant check alone previously gave false confidence: CR-C (T-P1-E14-01)
    /// found the listener was actually LAN/Tailscale-reachable despite this literal
    /// being correct, because `NWParameters.requiredLocalEndpoint` was being set
    /// AFTER `NWListener` had already been constructed from `params`, making the
    /// assignment a silent no-op. This test alone would NOT have caught that bug.
    func testBindHostIsLoopbackLiteral() {
        XCTAssertEqual(MCPServer.loopbackHost, NWEndpoint.Host("127.0.0.1"))
    }

    /// Real reachability regression test for the CR-C finding above (T-P1-E14-01):
    /// starts a real server, then attempts an actual TCP connect to its bound port
    /// via the machine's own non-loopback interface address (LAN IP or Tailscale IP)
    /// — i.e. simulates exactly what a peer elsewhere on the LAN/VPN would do,
    /// rather than connecting to `127.0.0.1` itself. A correctly loopback-bound
    /// listener never accepts a connection whose DESTINATION is a non-loopback
    /// local address, even though that address belongs to this same machine. This
    /// is the exact regression: before the fix, `NWParameters.requiredLocalEndpoint`
    /// was assigned to `params` AFTER `NWListener` had already been constructed from
    /// it, so the listener silently bound to `.any` and this connect attempt
    /// reached `.ready`. Skips (rather than falsely passing) if no non-loopback
    /// interface address can be discovered on the test machine.
    func testServerRefusesNonLoopbackConnection() throws {
        guard let nonLoopbackAddress = MCPServerTests.firstNonLoopbackIPv4Address() else {
            throw XCTSkip("no non-loopback IPv4 interface available on this test machine")
        }
        let port = try startServer()

        let connection = NWConnection(
            host: NWEndpoint.Host(nonLoopbackAddress),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)

        let outcomeExpectation = expectation(description: "connection settles")
        let outcomeBox = OutcomeBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Reaching .ready means a peer connecting to this machine's
                // LAN/Tailscale-facing address completed a TCP handshake against a
                // listener that was supposed to be loopback-only — exactly the
                // breach this test exists to catch.
                outcomeBox.reachedReady = true
                outcomeExpectation.fulfill()
            case .failed, .cancelled:
                outcomeExpectation.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .main)

        // Bounded wait: a correctly-enforced loopback requirement means this connect
        // attempt never reaches .ready — it either fails outright or simply never
        // progresses, and we time out waiting, which is the expected/passing outcome
        // here (distinguished from a hung test by the short bound).
        let result = XCTWaiter.wait(for: [outcomeExpectation], timeout: 3)
        connection.cancel()

        if result == .completed {
            XCTAssertFalse(
                outcomeBox.reachedReady,
                "a connection to this machine's own non-loopback address must never reach .ready "
                    + "against a loopback-only listener — the server is reachable from outside 127.0.0.1")
        }
        // .timedOut is also a pass: the connection attempt never completed, i.e. it
        // was correctly refused/never established — there is nothing further to assert.
    }

    /// Plain mutable box (not `Sendable`-checked var-capture) for the connection
    /// state callback above — `NWConnection.stateUpdateHandler` closures are not
    /// statically provably single-threaded to the compiler even though `queue: .main`
    /// guarantees it in practice, so a boxed reference type sidesteps the Swift 6
    /// "mutation of captured var in concurrently-executing code" diagnostic cleanly.
    private final class OutcomeBox: @unchecked Sendable {
        var reachedReady = false
    }

    /// First non-loopback IPv4 address found via `getifaddrs`, or nil if the test
    /// machine has none (e.g. a fully offline sandbox with only lo0).
    private static func firstNonLoopbackIPv4Address() -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let address = String(cString: host)
                if address != "0.0.0.0" { return address }
            }
        }
        return nil
    }
}
