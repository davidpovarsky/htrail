import XCTest
@testable import HTTrailCore

final class ResourceTypeTests: XCTestCase {
    private func flow(contentType: String?, path: String) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://e/\(path)", scheme: "https",
                                  host: "e", port: 443, path: path, httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = contentType.map {
            CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                             headers: [HeaderPair(name: "Content-Type", value: $0)],
                             body: Data(), timestamp: Date())
        }
        return Flow(request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testClassifiesByContentType() {
        XCTAssertEqual(ResourceType.classify(flow(contentType: "image/png", path: "/a")), .image)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/css", path: "/a")), .css)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/javascript", path: "/a")), .js)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/html; charset=utf-8", path: "/a")), .html)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/json", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/xml", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/event-stream", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/plain", path: "/a")), .other)
    }

    func testFallsBackToURLExtensionWhenTypeMissingOrOctetStream() {
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/app.js?v=2")), .js)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/octet-stream", path: "/logo.png")), .image)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/data.json")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/index.html")), .html)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/")), .other)
    }
}
