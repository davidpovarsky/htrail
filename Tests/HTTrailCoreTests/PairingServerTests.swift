import XCTest
@testable import HTTrailCore

final class PairingServerTests: XCTestCase {
    func testPairInvokesHandlerAndReturnsPort() async throws {
        let server = PairingServer()
        server.onPair = { req in
            XCTAssertEqual(req.deviceName, "iPhone")
            XCTAssertEqual(req.caCertPEM, "CERT")
            return PairResponse(proxyPort: 6789, sessionName: "iPhone session")
        }
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }

        let body = try JSONEncoder().encode(PairRequest(
            deviceName: "iPhone", deviceID: "dev-1", caCertPEM: "CERT", caKeyPEM: "KEY"))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        XCTAssertEqual(decoded.proxyPort, 6789)
    }

    func testMalformedBodyReturns400() async throws {
        let server = PairingServer()
        server.onPair = { _ in PairResponse(proxyPort: 1, sessionName: "x") }
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = Data("not json".utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 400)
    }
}
