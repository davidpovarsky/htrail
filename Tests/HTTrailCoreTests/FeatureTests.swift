import XCTest
@testable import HTTrailCore

final class ProfileGeneratorTests: XCTestCase {
    func testProducesValidMobileconfigWithCertAndProxy() throws {
        let ca = try CertificateAuthority.create()
        let data = try ProfileGenerator().makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: "192.168.1.50", proxyPort: 9090
        )
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let root = try XCTUnwrap(plist)
        XCTAssertEqual(root["PayloadType"] as? String, "Configuration")

        let payloads = try XCTUnwrap(root["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 2)

        let cert = try XCTUnwrap(payloads.first { ($0["PayloadType"] as? String) == "com.apple.security.root" })
        let certData = try XCTUnwrap(cert["PayloadContent"] as? Data)
        XCTAssertFalse(certData.isEmpty, "CA DER must be embedded")

        let proxy = try XCTUnwrap(payloads.first { ($0["PayloadType"] as? String) == "com.apple.proxy.http.global" })
        XCTAssertEqual(proxy["HTTPProxy"] as? String, "192.168.1.50")
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, 9090)
    }
}

final class RequestRunnerTests: XCTestCase {
    func testBuildsURLRequestWithParamsHeadersAndJSONBody() throws {
        var request = APIRequest(method: "POST", url: "https://api.example.com/users")
        request.queryParams = [KeyValueItem(name: "page", value: "2")]
        request.headers = [KeyValueItem(name: "Authorization", value: "Bearer {{token}}")]
        request.bodyMode = .json
        request.rawBody = #"{"name":"{{name}}"}"#

        let runner = RequestRunner()
        let urlRequest = try XCTUnwrap(runner.makeURLRequest(request, environment: ["token": "abc", "name": "Ada"]))

        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.com/users?page=2")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(data: urlRequest.httpBody ?? Data(), encoding: .utf8), #"{"name":"Ada"}"#)
    }
}

final class SharedFlowStoreTests: XCTestCase {
    private func makeFlow(host: String, status: Int?) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = status.map { CapturedResponse(statusCode: $0, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                                 headers: [], body: Data(), timestamp: Date()) }
        return Flow(request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testRoundTripsFlowsNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-flows-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = SharedFlowStore(url: url)
        let a = makeFlow(host: "a.example", status: 200)
        let b = makeFlow(host: "b.example", status: 201)
        writer.record(a)
        writer.record(b)

        let reader = SharedFlowStore(url: url)
        let all = reader.readAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.request.host, "b.example", "readAll returns newest first")
    }

    func testUpsertsFlowByID() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-flows-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SharedFlowStore(url: url)
        var pending = makeFlow(host: "c.example", status: nil)
        store.record(pending)
        pending.response = CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                            headers: [], body: Data(), timestamp: Date())
        pending.state = .completed
        store.record(pending)

        let all = store.readAll()
        XCTAssertEqual(all.count, 1, "same id must replace, not duplicate")
        XCTAssertEqual(all.first?.statusCode, 200)
    }

    func testEvictsBeyondCapacity() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-flows-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SharedFlowStore(url: url, capacity: 3)
        for i in 0..<5 { store.record(makeFlow(host: "h\(i).example", status: 200)) }
        XCTAssertEqual(store.readAll().count, 3, "bounded to capacity")
    }
}
