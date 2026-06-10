import XCTest
@testable import CurtainShared

final class NetstatParseTests: XCTestCase {
    func testListenOnlyIsFalse() {
        let out = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.5900                 *.*                    LISTEN
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(out))
    }

    func testEstablishedInboundIsTrue() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.1.20.5900      192.168.1.55.51234     ESTABLISHED
        """
        XCTAssertTrue(NetstatParse.hasEstablishedVNC(out))
    }

    func testEstablishedDifferentPortIsFalse() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.1.20.22        192.168.1.55.51234     ESTABLISHED
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(out))
    }

    func testForeignWildcardIsFalse() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.1.20.5900      *.*                    ESTABLISHED
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(out))
    }

    func testOutboundFiveNineHundredIsFalse() {
        // 5900 appears in the FOREIGN column (we are the client) — not an inbound VNC session.
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.1.20.51234     192.168.1.55.5900      ESTABLISHED
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(out))
    }

    func testEmptyOutputIsFalse() {
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(""))
    }

    func testEstablishedAmongNoiseIsTrue() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.5900                 *.*                    LISTEN
        tcp4       0      0  192.168.1.20.22        10.0.0.9.4421          ESTABLISHED
        tcp4       0      0  192.168.1.20.5900      10.0.0.9.62000         ESTABLISHED
        """
        XCTAssertTrue(NetstatParse.hasEstablishedVNC(out))
    }

    func testRealMacOS26ListenFormatIsFalse() {
        // Verbatim from `netstat -an` on macOS 26.5 with Screen Sharing enabled,
        // no session: LISTEN rows only must never read as established.
        let out = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  *.5900                 *.*                    LISTEN
        tcp6       0      0  *.5900                 *.*                    LISTEN
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(out))
        XCTAssertFalse(NetstatParse.hasPeeredUDPVNC(out))
    }

    // MARK: - Peered UDP (High-Performance transport)

    func testPeeredUDPOn5900IsTrue() {
        let out = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address
        udp4       0      0  192.168.1.20.5900      192.168.1.55.61234
        """
        XCTAssertTrue(NetstatParse.hasPeeredUDPVNC(out))
    }

    func testPeeredUDPOn5901And5902IsTrue() {
        let out5901 = """
        udp4       0      0  192.168.1.20.5901      192.168.1.55.61234
        """
        let out5902 = """
        udp6       0      0  fe80::1%en0.5902       fe80::2%en0.61234
        """
        XCTAssertTrue(NetstatParse.hasPeeredUDPVNC(out5901))
        XCTAssertTrue(NetstatParse.hasPeeredUDPVNC(out5902))
    }

    func testWildcardUDPListenerIsFalse() {
        // An unconnected UDP listener (foreign *.*) is just Screen Sharing being
        // enabled — it must NEVER activate (the overnight false-positive class).
        let out = """
        udp4       0      0  *.5900                 *.*
        udp4       0      0  192.168.1.20.5900      *.*
        """
        XCTAssertFalse(NetstatParse.hasPeeredUDPVNC(out))
    }

    func testPeeredUDPOnOtherPortIsFalse() {
        let out = """
        udp4       0      0  192.168.1.20.5353      192.168.1.55.5353
        udp4       0      0  192.168.1.20.59000     10.0.0.9.443
        """
        XCTAssertFalse(NetstatParse.hasPeeredUDPVNC(out))
    }

    func testPeeredUDPIsNotEstablishedTCP() {
        // The two detectors must not bleed into each other.
        let udpOnly = """
        udp4       0      0  192.168.1.20.5900      192.168.1.55.61234
        """
        let tcpOnly = """
        tcp4       0      0  192.168.1.20.5900      192.168.1.55.61234     ESTABLISHED
        """
        XCTAssertFalse(NetstatParse.hasEstablishedVNC(udpOnly))
        XCTAssertFalse(NetstatParse.hasPeeredUDPVNC(tcpOnly))
    }

    func testEmptyOutputUDPIsFalse() {
        XCTAssertFalse(NetstatParse.hasPeeredUDPVNC(""))
    }
}
