import XCTest
@testable import HTTrailCore

@MainActor
final class CaptureSessionModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-model-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> AppModel {
        AppModel(sessionStore: CaptureSessionStore(directory: dir))
    }

    private func flow(id: UUID = UUID(), host: String, contentType: String?, status: Int? = 200) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = status.map { s in
            CapturedResponse(statusCode: s, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                             headers: contentType.map { [HeaderPair(name: "Content-Type", value: $0)] } ?? [],
                             body: Data(), timestamp: Date())
        }
        return Flow(id: id, request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testBeginSessionCreatesActiveSessionAndIngestStamps() {
        let model = makeModel()
        model.beginCaptureSession()
        let active = try! XCTUnwrap(model.activeSessionID)
        XCTAssertEqual(model.viewingSessionID, active)
        XCTAssertEqual(model.sessions.count, 1)

        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        XCTAssertEqual(model.flows.count, 1)
        XCTAssertEqual(model.flows.first?.sessionID, active)
        XCTAssertEqual(model.sessions.first?.recordCount, 1)
    }

    func testResumeReopensAndLoadsPriorFlows() {
        let model = makeModel()
        model.beginCaptureSession()
        let first = model.activeSessionID!
        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        model.endCaptureSession()
        XCTAssertNotNil(model.sessions.first { $0.id == first }?.endedAt)

        model.beginCaptureSession(resuming: first)
        XCTAssertEqual(model.activeSessionID, first)
        XCTAssertNil(model.sessions.first { $0.id == first }?.endedAt, "reopened")
        XCTAssertEqual(model.flows.count, 1, "prior flow reloaded")
        model.ingestForTesting(flow(host: "b", contentType: "text/html"))
        XCTAssertEqual(model.flows.count, 2)
    }

    func testFilteredFlowsHonorTextAndResourceType() {
        let model = makeModel()
        model.beginCaptureSession()
        model.ingestForTesting(flow(host: "api.test", contentType: "application/json"))
        model.ingestForTesting(flow(host: "cdn.test", contentType: "image/png"))

        model.resourceTypeFilter = [.image]
        XCTAssertEqual(model.filteredFlows.map(\.request.host), ["cdn.test"])

        model.resourceTypeFilter = []
        model.filterText = "api"
        XCTAssertEqual(model.filteredFlows.map(\.request.host), ["api.test"])
    }

    func testDeleteSelectedFlowsAndDeleteSession() {
        let model = makeModel()
        model.beginCaptureSession()
        let keep = UUID(); let drop = UUID()
        model.ingestForTesting(flow(id: keep, host: "keep", contentType: "application/json"))
        model.ingestForTesting(flow(id: drop, host: "drop", contentType: "application/json"))

        model.selectedFlowIDs = [drop]
        model.deleteSelectedFlows()
        XCTAssertEqual(model.flows.map(\.request.host), ["keep"])
        XCTAssertEqual(model.sessions.first?.recordCount, 1)

        let sessionID = model.activeSessionID!
        model.deleteSession(sessionID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.activeSessionID)
    }

    func testExportHARForViewedPastSession() throws {
        let model = makeModel()
        model.beginCaptureSession()
        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        model.endCaptureSession()
        let id = model.sessions.first!.id

        model.viewSession(id)
        let url = try XCTUnwrap(model.exportHAR())
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let log = (json?["log"] as? [String: Any])
        let entries = try XCTUnwrap(log?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
    }
}
