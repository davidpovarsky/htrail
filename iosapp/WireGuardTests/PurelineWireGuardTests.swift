import XCTest
@testable import PurelineWireGuardValidation

final class PurelineWireGuardTests: XCTestCase {
    // Synthetic public test material, never used by a real peer.
    private var profile: String {
        """
        [Interface]
        PrivateKey = \(Data(repeating: 1, count: 32).base64EncodedString())
        Address = 10.255.0.2/32
        DNS = 10.255.0.53
        MTU = 1280
        [Peer]
        PublicKey = \(Data(repeating: 2, count: 32).base64EncodedString())
        AllowedIPs = 0.0.0.0/0
        Endpoint = 192.0.2.1:51820
        PersistentKeepalive = 25
        """
    }

    func testAcceptsFullIPv4ProfileAndReportsIPv6Gap() throws {
        let parsed = try PurelineWGProfile.parse(profile)
        XCTAssertEqual(parsed.endpoint, "192.0.2.1:51820")
        XCTAssertFalse(parsed.routesIPv6)
        XCTAssertEqual(parsed.tunnel.peers.count, 1)
    }

    func testRecognizesExplicitIPv6Coverage() throws {
        let text = profile.replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0", with: "AllowedIPs = 0.0.0.0/0, ::/0")
        XCTAssertTrue(try PurelineWGProfile.parse(text).routesIPv6)
    }

    func testRejectsShellHooksRatherThanExecutingOrIgnoringThem() {
        let text = profile.replacingOccurrences(of: "MTU = 1280", with: "PostUp = echo private-data")
        XCTAssertThrowsError(try PurelineWGProfile.parse(text)) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-data"))
        }
    }

    func testRejectsDuplicatePrivateKeyWithoutExposingValue() {
        let text = profile.replacingOccurrences(of: "Address =", with: "PrivateKey = secret-material\nAddress =")
        XCTAssertThrowsError(try PurelineWGProfile.parse(text)) { error in
            XCTAssertFalse(error.localizedDescription.contains("secret-material"))
        }
    }

    func testRejectsDuplicatePeersBeforeUpstreamFatalPrecondition() {
        let peer = profile.components(separatedBy: "[Peer]")[1]
        XCTAssertThrowsError(try PurelineWGProfile.parse(profile + "\n[Peer]" + peer))
    }

    func testRejectsSplitTunnelPresentedAsWholeDeviceFiltering() {
        XCTAssertThrowsError(try PurelineWGProfile.parse(profile.replacingOccurrences(of: "0.0.0.0/0", with: "10.0.0.0/8")))
    }

    func testRejectsMissingDNSAndInvalidMTU() {
        XCTAssertThrowsError(try PurelineWGProfile.parse(profile.replacingOccurrences(of: "DNS = 10.255.0.53\n", with: "")))
        XCTAssertThrowsError(try PurelineWGProfile.parse(profile.replacingOccurrences(of: "MTU = 1280", with: "MTU = 99999")))
    }

    func testRejectsOversizedAndInvalidKeyMaterial() {
        XCTAssertThrowsError(try PurelineWGProfile.parse(String(repeating: "a", count: 65_537)))
        XCTAssertThrowsError(try PurelineWGProfile.parse(profile.replacingOccurrences(of: Data(repeating: 1, count: 32).base64EncodedString(), with: "bad-secret"))) { error in
            XCTAssertFalse(error.localizedDescription.contains("bad-secret"))
        }
    }

    func testStatisticsProjectionContainsNoRawConfiguration() throws {
        let parsed = PurelineWGStatistics.parse("private_key=do-not-emit\npublic_key=do-not-emit\nrx_bytes=12\ntx_bytes=8\nlast_handshake_time_sec=123\nrx_bytes=4\ntx_bytes=7\nlast_handshake_time_sec=120")
        XCTAssertEqual(parsed.receivedBytes, 16)
        XCTAssertEqual(parsed.sentBytes, 15)
        XCTAssertEqual(parsed.latestHandshake, 123)
        let encoded = String(data: try JSONEncoder().encode(parsed), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("do-not-emit"))
        XCTAssertFalse(encoded.contains("private"))
    }

    func testMalformedRuntimeCountersCannotOverflowOrBecomeNonFinite() {
        let parsed = PurelineWGStatistics.parse("rx_bytes=18446744073709551615\nrx_bytes=1\ntx_bytes=-1\nlast_handshake_time_sec=nan")
        XCTAssertEqual(parsed.receivedBytes, UInt64.max)
        XCTAssertEqual(parsed.sentBytes, 0)
        XCTAssertEqual(parsed.latestHandshake, 0)
    }

    @MainActor
    func testSimulatorCannotReportVPNAsConnected() {
        #if targetEnvironment(simulator)
        let controller = PurelineWGController()
        XCTAssertFalse(PurelineWGController.supportsTunnel)
        XCTAssertFalse(controller.isActive)
        XCTAssertNotEqual(controller.statusLabel, "VPN connected")
        #endif
    }
}
