import XCTest
@testable import HTTrailCore

@MainActor
final class AppModelPairingTests: XCTestCase {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-pair-\(UUID().uuidString)", isDirectory: true)
        return AppModel(sessionStore: CaptureSessionStore(directory: dir))
    }

    private func flow(host: String) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                    headers: [], body: Data(), timestamp: Date())
        return Flow(request: req, response: resp, state: .completed,
                    startedAt: Date(), endedAt: Date(), secure: true)
    }

    func testPairDeviceStartsDistinctProxyAndRecordsFlows() async throws {
        let model = makeModel()
        let ca = try CertificateAuthority.create()
        let req = PairRequest(deviceName: "TestPhone", deviceID: "dev-1",
                              caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM)
        let resp = await model.pairDevice(req)
        let unwrapped = try XCTUnwrap(resp)
        XCTAssertGreaterThan(unwrapped.proxyPort, 0)
        XCTAssertNotEqual(unwrapped.proxyPort, model.proxyPort)
        XCTAssertEqual(model.pairedDeviceCount, 1)

        let session = try XCTUnwrap(model.sessions.first { $0.name.contains("TestPhone") })
        model.ingestDeviceFlow(flow(host: "a.example"), sessionID: session.id)
        XCTAssertEqual(model.sessionStoreFlowCountForTesting(session.id), 1)

        await model.unpairDevice("dev-1")
        XCTAssertEqual(model.pairedDeviceCount, 0)
    }

    func testPairingSwitchesToLiveDeviceSessionAndFeedsFlows() async throws {
        let model = makeModel()
        let ca = try CertificateAuthority.create()
        let req = PairRequest(deviceName: "TestPhone", deviceID: "dev-1",
                              caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM)
        let resp = await model.pairDevice(req)
        XCTAssertNotNil(resp)
        let session = try XCTUnwrap(model.sessions.first { $0.name.contains("TestPhone") })

        // Pairing flips the Mac UI to live-view this device's (empty) session.
        XCTAssertEqual(model.viewingSessionID, session.id)
        XCTAssertTrue(model.displayedFlows.isEmpty)

        // Flows fed for that device appear live in displayedFlows (newest-first),
        // and updates to an existing flow replace in place rather than duplicate.
        let f = flow(host: "a.example")
        model.ingestDeviceFlow(f, sessionID: session.id)
        XCTAssertEqual(model.displayedFlows.count, 1)
        XCTAssertEqual(model.displayedFlows.first?.request.host, "a.example")
        model.ingestDeviceFlow(f, sessionID: session.id)            // same id again
        XCTAssertEqual(model.displayedFlows.count, 1)
        model.ingestDeviceFlow(flow(host: "b.example"), sessionID: session.id)
        XCTAssertEqual(model.displayedFlows.count, 2)
        XCTAssertEqual(model.displayedFlows.first?.request.host, "b.example")

        await model.unpairDevice("dev-1")
    }
}
