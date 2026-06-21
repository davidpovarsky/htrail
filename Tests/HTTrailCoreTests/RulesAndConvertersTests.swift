import XCTest
import NIOPosix
@testable import HTTrailCore

final class InterceptRuleProxyTests: XCTestCase {
    /// A block rule should short-circuit the request with the configured status,
    /// proving the engine runs inside the live MITM path.
    func testBlockRuleReturns403() async throws {
        let ca = try CertificateAuthority.create()
        let caURL = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID()).pem")
        try ca.caCertificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: caURL) }

        let engine = InterceptEngine()
        var rule = InterceptRule()
        rule.kind = .block
        rule.urlPattern = "*example.com*"
        rule.blockStatus = 403
        engine.setRules([rule])

        let sink = CollectingSink()
        let port = 19_120
        let proxy = ProxyServer(port: port, certificateAuthority: ca, sink: sink, engine: engine)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "-x", "http://127.0.0.1:\(port)", "--cacert", caURL.path,
                             "-o", "/dev/null", "-w", "%{http_code}", "https://example.com/"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try process.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        if out.trimmingCharacters(in: .whitespaces) == "000" { throw XCTSkip("No network") }
        XCTAssertEqual(out.trimmingCharacters(in: .whitespaces), "403")
    }
}

final class GlobTests: XCTestCase {
    func testGlobMatching() {
        XCTAssertTrue(Glob.match("*example.com*", "https://api.example.com/x"))
        XCTAssertTrue(Glob.match("*.json", "https://x/data.json"))
        XCTAssertTrue(Glob.match("*", "anything"))
        XCTAssertFalse(Glob.match("*.css", "https://x/data.json"))
        XCTAssertTrue(Glob.match("api.example.com", "https://api.example.com/x"))
    }
}

final class CurlConverterTests: XCTestCase {
    func testImportCurl() throws {
        let cmd = """
        curl -X POST 'https://api.example.com/login' \
          -H 'Content-Type: application/json' \
          -H 'Accept: application/json' \
          --data '{"user":"ada"}'
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://api.example.com/login")
        XCTAssertEqual(request.headers.count, 2)
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertTrue(request.rawBody.contains("ada"))
    }

    func testRoundTripExport() throws {
        var request = APIRequest(method: "POST", url: "https://api.example.com/x")
        request.headers = [KeyValueItem(name: "X-Test", value: "1")]
        request.bodyMode = .json
        request.rawBody = #"{"a":1}"#
        let curl = CurlConverter().exportCommand(request)
        XCTAssertTrue(curl.contains("-X POST"))
        XCTAssertTrue(curl.contains("https://api.example.com/x"))
        XCTAssertTrue(curl.contains("X-Test: 1"))
    }
}

final class HARExporterTests: XCTestCase {
    func testExportsValidHAR() throws {
        let request = CapturedRequest(method: "GET", url: "https://x/y", scheme: "https", host: "x",
                                      port: 443, path: "/y", httpVersion: "HTTP/1.1",
                                      headers: [HeaderPair(name: "Accept", value: "*/*")],
                                      body: Data(), timestamp: Date())
        let response = CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                        headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                                        body: Data("{}".utf8), timestamp: Date())
        let flow = Flow(request: request, response: response, state: .completed,
                        startedAt: Date(), endedAt: Date(), secure: true)
        let data = try HARExporter().export([flow])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let log = try XCTUnwrap(json?["log"] as? [String: Any])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let resp = try XCTUnwrap(entries[0]["response"] as? [String: Any])
        XCTAssertEqual(resp["status"] as? Int, 200)
    }
}

final class WorkspacePersistenceTests: XCTestCase {
    func testEnvironmentResolution() {
        var env = RequestEnvironment(name: "dev")
        env.variables = [KeyValueItem(name: "base", value: "https://dev.api"),
                         KeyValueItem(name: "off", value: "x", enabled: false)]
        XCTAssertEqual(env.resolved["base"], "https://dev.api")
        XCTAssertNil(env.resolved["off"])
    }

    func testCollectionsPersistRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONStore(directory: dir)
        let ws = Workspace(store: store)
        ws.setCollections([RequestCollection(name: "API", requests: [APIRequest(name: "Ping")])])
        let reloaded = Workspace(store: store)
        XCTAssertEqual(reloaded.collections.first?.name, "API")
        XCTAssertEqual(reloaded.collections.first?.requests.first?.name, "Ping")
    }
}
