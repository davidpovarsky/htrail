import XCTest
@testable import HTTrailCore

final class CaptureSessionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-sessions-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> CaptureSessionStore { CaptureSessionStore(directory: dir) }

    private func flow(id: UUID = UUID(), host: String, status: Int?) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = status.map { CapturedResponse(statusCode: $0, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                                 headers: [], body: Data(), timestamp: Date()) }
        return Flow(id: id, request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testCreateAndListSessionsNewestFirst() {
        let store = makeStore()
        let a = store.createSession(name: "A", startedAt: Date())
        let b = store.createSession(name: "B", startedAt: Date())
        let all = store.allSessions()
        XCTAssertEqual(all.map(\.name), ["B", "A"])
        XCTAssertEqual(all.first?.id, b.id)
        XCTAssertEqual(all.last?.id, a.id)
    }

    func testRecordUpsertsByIDAndTracksCount() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        let fid = UUID()
        store.record(flow(id: fid, host: "h", status: nil), in: s.id)   // pending
        store.record(flow(id: fid, host: "h", status: 200), in: s.id)   // completed (same id)
        store.record(flow(host: "h2", status: 200), in: s.id)           // new id

        let flows = store.flows(in: s.id)
        XCTAssertEqual(flows.count, 2, "same id replaces, not duplicates")
        XCTAssertEqual(store.allSessions().first { $0.id == s.id }?.recordCount, 2)
        XCTAssertEqual(flows.first?.request.host, "h2", "newest first")
    }

    func testPersistsAcrossStoreInstances() {
        let s = makeStore().createSession(name: "S", startedAt: Date())
        makeStore().record(flow(host: "h", status: 200), in: s.id)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.flows(in: s.id).count, 1)
        XCTAssertEqual(reloaded.allSessions().first?.recordCount, 1)
    }

    func testRenameNotesReopenAndEnd() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        store.rename(s.id, to: "Renamed")
        store.setNotes(s.id, "hello")
        let now = Date()
        store.endSession(s.id, at: now)
        var got = store.allSessions().first { $0.id == s.id }
        XCTAssertEqual(got?.name, "Renamed")
        XCTAssertEqual(got?.notes, "hello")
        XCTAssertNotNil(got?.endedAt)
        store.reopen(s.id)
        got = store.allSessions().first { $0.id == s.id }
        XCTAssertNil(got?.endedAt, "reopen clears endedAt")
    }

    func testDeleteSelectedFlowsRecomputesCount() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        let keep = UUID(); let drop = UUID()
        store.record(flow(id: keep, host: "keep", status: 200), in: s.id)
        store.record(flow(id: drop, host: "drop", status: 200), in: s.id)
        store.deleteFlows([drop], in: s.id)
        XCTAssertEqual(store.flows(in: s.id).map(\.request.host), ["keep"])
        XCTAssertEqual(store.allSessions().first?.recordCount, 1)
    }

    func testDeleteSessionRemovesFileAndIndexEntry() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        store.record(flow(host: "h", status: 200), in: s.id)
        store.deleteSession(s.id)
        XCTAssertTrue(store.allSessions().isEmpty)
        XCTAssertTrue(store.flows(in: s.id).isEmpty)
        let file = dir.appendingPathComponent("\(s.id.uuidString).ndjson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
