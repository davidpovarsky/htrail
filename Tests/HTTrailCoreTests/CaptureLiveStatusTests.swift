import XCTest
@testable import HTTrailCore

final class CaptureLiveStatusTests: XCTestCase {
    private func status(_ vpn: VPNPhase, remote: Bool, _ health: CaptureHealth = .unknown,
                        engineLive: Bool = false) -> CaptureLiveStatus {
        CaptureHealthCheck.liveStatus(vpn: vpn, targetIsRemote: remote, health: health, engineLive: engineLive)
    }

    func testTunnelPhaseDominatesBeforeConnected() {
        XCTAssertEqual(status(.off, remote: true, .healthy), .stopped)
        XCTAssertEqual(status(.connecting, remote: false, engineLive: true), .starting)
        XCTAssertEqual(status(.reconnecting, remote: true, .healthy), .reconnecting)
    }

    func testRemoteHealthMapping() {
        XCTAssertEqual(status(.connected, remote: true, .healthy), .capturingRemote)
        XCTAssertEqual(status(.connected, remote: true, .unreachable), .macUnreachable)
        XCTAssertEqual(status(.connected, remote: true, .tlsUntrusted), .macUntrusted)
        // Health not yet known while connected reads as still starting up.
        XCTAssertEqual(status(.connected, remote: true, .unknown), .starting)
    }

    func testLocalUsesEngineHeartbeat() {
        XCTAssertEqual(status(.connected, remote: false, engineLive: true), .capturingLocal)
        XCTAssertEqual(status(.connected, remote: false, engineLive: false), .extensionStalled)
        // On-device also needs the CA trusted: engine alive but CA untrusted →
        // surface the untrusted banner rather than a false "capturing".
        XCTAssertEqual(status(.connected, remote: false, .tlsUntrusted, engineLive: true), .macUntrusted)
        // A stalled engine takes precedence over trust state.
        XCTAssertEqual(status(.connected, remote: false, .tlsUntrusted, engineLive: false), .extensionStalled)
    }
}
