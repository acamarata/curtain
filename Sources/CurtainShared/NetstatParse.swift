import Foundation

/// Purpose: decide, from `netstat -an` output text, whether there is a genuine
///          inbound Screen Sharing connection: an ESTABLISHED TCP session on local
///          port 5900 (classic VNC) or a peered UDP socket on 5900-5902 (the
///          Sequoia/26 High-Performance transport). A LISTEN socket on 5900 is
///          always present whenever Screen Sharing is enabled, and wildcard UDP
///          listeners can linger, so neither alone proves anything; only a row
///          with a real foreign peer (not `*.*`) counts.
public enum NetstatParse {
    /// Returns true when the netstat output contains an ESTABLISHED inbound TCP
    /// session on local port 5900 with a real peer.
    public static func hasEstablishedVNC(_ netstatOutput: String) -> Bool {
        for raw in netstatOutput.split(separator: "\n") {
            let line = String(raw)
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // netstat -an TCP columns: proto recv-q send-q local-address foreign-address state
            guard fields.count >= 6 else { continue }
            guard fields[0].lowercased().hasPrefix("tcp") else { continue }

            let local = fields[3]
            let foreign = fields[4]
            let state = fields[5]

            // Local side must be our 5900 listener accepting the inbound connection.
            guard local.hasSuffix(".5900") else { continue }
            // Must be an established connection with a real peer, not a LISTEN socket.
            guard state == "ESTABLISHED" else { continue }
            guard isRealPeer(foreign) else { continue }
            return true
        }
        return false
    }

    /// Returns true when the netstat output contains a UDP socket on local port
    /// 5900-5902 that is connected to a real foreign peer. High-Performance Screen
    /// Sharing (macOS 14+, Apple silicon) streams over UDP, so there is no
    /// ESTABLISHED TCP row to find — but an active session shows as a peered UDP
    /// socket. A wildcard foreign address (`*.*`) is just a listener and never
    /// counts, so this cannot fire at rest.
    public static func hasPeeredUDPVNC(_ netstatOutput: String) -> Bool {
        for raw in netstatOutput.split(separator: "\n") {
            let line = String(raw)
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // netstat -an UDP columns: proto recv-q send-q local-address foreign-address
            guard fields.count >= 5 else { continue }
            guard fields[0].lowercased().hasPrefix("udp") else { continue }

            let local = fields[3]
            let foreign = fields[4]

            guard local.hasSuffix(".5900") || local.hasSuffix(".5901") || local.hasSuffix(".5902") else { continue }
            guard isRealPeer(foreign) else { continue }
            return true
        }
        return false
    }

    /// A foreign address is a real peer only when it names an actual remote
    /// host+port, not the `*.*` / `host.*` wildcard forms a listener shows.
    private static func isRealPeer(_ foreign: String) -> Bool {
        foreign != "*.*" && !foreign.hasSuffix(".*")
    }
}
