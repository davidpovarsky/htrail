import XCTest
import Network
@testable import HTTrailCore

final class CaptureHealthCheckTests: XCTestCase {
    func testReachableTrueAgainstLiveListenerFalseAgainstClosedPort() async throws {
        // Stand up a real TCP listener on an ephemeral port.
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = Int(listener.port!.rawValue)
        defer { listener.cancel() }

        let up = await CaptureHealthCheck.reachable(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertTrue(up, "live listener should be reachable")

        // Port 1 on loopback is virtually always closed.
        let down = await CaptureHealthCheck.reachable(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertFalse(down, "closed port should be unreachable")
    }

    func testCaptureTargetRemoteHostPort() {
        XCTAssertNil(CaptureTarget.thisDevice.remoteHostPort?.host)
        let p = DiscoveredProxy(id: "x", name: "Mac", host: "10.0.0.5", port: 9090, caPort: 0, caFP: "", pairPort: 0)
        XCTAssertEqual(CaptureTarget.remote(p).remoteHostPort?.host, "10.0.0.5")
        XCTAssertEqual(CaptureTarget.manual(host: "1.2.3.4", port: 8888).remoteHostPort?.port, 8888)
    }
}
