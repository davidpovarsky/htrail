import XCTest
@testable import HTTrailCore

@MainActor
final class ComposeHistoryTests: XCTestCase {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-hist-\(UUID().uuidString)", isDirectory: true)
        return AppModel(sessionStore: CaptureSessionStore(directory: dir))
    }

    private func makeModel(workspaceDirectory: URL) -> AppModel {
        let sessions = workspaceDirectory.appendingPathComponent("sessions", isDirectory: true)
        let workspace = Workspace(store: JSONStore(directory: workspaceDirectory))
        return AppModel(sessionStore: CaptureSessionStore(directory: sessions), workspace: workspace)
    }

    private func entry() -> HistoryEntry {
        var req = APIRequest()
        req.method = "POST"
        req.url = "https://api.example.com/widgets"
        let resp = APIResponse(statusCode: 201, headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                               body: Data(#"{"ok":true}"#.utf8), durationMS: 42)
        return HistoryEntry(request: req, statusCode: 201, durationMS: 42, timestamp: Date(), response: resp)
    }

    func testLoadHistoryRestoresRequestAndResponse() {
        let model = makeModel()
        let e = entry()

        model.loadHistory(e)

        // The historical request becomes the selected request, keeping its id.
        XCTAssertEqual(model.selectedRequestID, e.request.id)
        XCTAssertEqual(model.requests.last?.url, "https://api.example.com/widgets")
        // Its response is restored so the response pane shows the old result.
        XCTAssertEqual(model.responsesByRequest[e.request.id]?.statusCode, 201)
        XCTAssertEqual(model.responsesByRequest[e.request.id]?.bodyString, #"{"ok":true}"#)
        XCTAssertEqual(model.mode, .compose)
    }

    func testLoadHistoryDoesNotDuplicateOnRepeatClicks() {
        let model = makeModel()
        let e = entry()
        let baseline = model.requests.count

        model.loadHistory(e)
        model.loadHistory(e)
        model.loadHistory(e)

        // Reopening the same history entry reselects the open request rather
        // than appending a fresh copy each time.
        XCTAssertEqual(model.requests.count, baseline + 1)
        XCTAssertEqual(model.requests.filter { $0.id == e.request.id }.count, 1)
    }

    func testComposeRequestTitleUsesHostnameForDefaultName() {
        var request = APIRequest()
        request.url = "https://api.example.com/widgets?limit=10"

        XCTAssertEqual(AppModel.composeRequestTitle(for: request), "api.example.com")

        request.name = "List widgets"
        XCTAssertEqual(AppModel.composeRequestTitle(for: request), "List widgets")
    }

    func testComposeHistoryTitleUsesHostnameAndTimestamp() {
        let history = entry()

        XCTAssertEqual(
            AppModel.composeHistoryTitle(for: history, timestampText: "Jun 23, 2026 10:20"),
            "api.example.com · Jun 23, 2026 10:20"
        )
    }

    func testDefaultComposeURLUsesTraceEndpoint() {
        XCTAssertEqual(APIRequest().url, AppModel.defaultComposeURL)
        XCTAssertEqual(AppModel.defaultComposeURL, "https://1.1.1.1/cdn-cgi/trace")
    }

    func testEditingDefaultComposeURLClearsTheField() {
        let model = makeModel()
        let idx = try! XCTUnwrap(model.selectedRequestIndex)
        model.requests[idx].url = AppModel.defaultComposeURL

        model.prepareComposeURLFieldForEditing(at: idx)

        XCTAssertEqual(model.requests[idx].url, "")
    }

    func testComposeURLPasteReplacesSchemeStubWithFullURL() {
        let model = makeModel()
        let idx = try! XCTUnwrap(model.selectedRequestIndex)

        model.requests[idx].url = "https://https://abc.com/path?q=1"
        XCTAssertTrue(model.normalizeComposeURLIfNeeded(model.requests[idx].url, at: idx))
        XCTAssertEqual(model.requests[idx].url, "https://abc.com/path?q=1")

        model.requests[idx].url = "http://wss://socket.example/live"
        XCTAssertTrue(model.normalizeComposeURLIfNeeded(model.requests[idx].url, at: idx))
        XCTAssertEqual(model.requests[idx].url, "wss://socket.example/live")
    }

    func testSocketIODoesNotInheritWebSocketDefaultURL() {
        let model = makeModel()
        XCTAssertEqual(model.wsURL, AppModel.defaultWebSocketURL)

        model.rtProtocol = .socketIO

        XCTAssertEqual(model.wsURL, "")
    }

    func testImportCollectionFromPostmanBackupAddsCollectionsAndEnvironments() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-postman-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(workspaceDirectory: dir)
        let backup = """
        {
          "version": 1,
          "collections": [{
            "name": "Postman Local",
            "order": ["req-1"],
            "requests": [{
              "id": "req-1",
              "name": "Ping",
              "method": "GET",
              "url": "https://api.example.com/ping?ok=1",
              "queryParams": [{"key": "ok", "value": "1", "enabled": true}]
            }]
          }],
          "environments": [{
            "name": "Local",
            "values": [{"key": "baseUrl", "value": "https://local.example.com", "enabled": true}]
          }]
        }
        """
        let url = dir.appendingPathComponent("backup-2026-06-25T13-20-56.301Z.json")
        try Data(backup.utf8).write(to: url)

        model.importCollection(from: url)

        XCTAssertEqual(model.collections.last?.name, "Postman Local")
        XCTAssertEqual(model.collections.last?.requests.first?.url, "https://api.example.com/ping")
        XCTAssertEqual(model.collections.last?.requests.first?.queryParams.first?.name, "ok")
        XCTAssertEqual(model.environments.last?.name, "Local")
        XCTAssertEqual(model.activeEnvironmentID, model.environments.last?.id)
        XCTAssertEqual(model.mode, .compose)
        XCTAssertTrue(model.statusMessage.contains("Imported Postman backup"))

        let reloaded = Workspace(store: JSONStore(directory: dir))
        XCTAssertEqual(reloaded.collections.last?.name, "Postman Local")
        XCTAssertEqual(reloaded.environments.last?.name, "Local")
    }
}
