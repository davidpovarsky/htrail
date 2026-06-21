import XCTest
@testable import HTTrailCore

final class ProxyServerBoundPortTests: XCTestCase {
    func testEphemeralBindReportsRealPort() async throws {
        let ca = try CertificateAuthority.create()
        let bridge = FlowBridge()
        let server = ProxyServer(port: 0, certificateAuthority: ca, sink: bridge)
        try await server.start()
        defer { Task { try? await server.stop() } }
        XCTAssertGreaterThan(server.boundPort, 0)
        XCTAssertNotEqual(server.boundPort, 0)
    }
}
