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

    func testImportCurlDoubleQuotedEscapedJSON() throws {
        // Windows/cmd "Copy as cURL" double-quotes the body and escapes the inner
        // quotes with `\"`. The body must come back as clean JSON, not literal
        // backslashes or stray quotes.
        let cmd = #"curl -X POST "https://api.example.com/u" -H "Content-Type: application/json" --data-raw "{\"name\":\"ada\",\"n\":42}""#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://api.example.com/u")
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertEqual(request.rawBody, #"{"name":"ada","n":42}"#)
        XCTAssertFalse(request.rawBody.contains("\\"))
    }

    func testImportCurlBashEscapedApostrophe() throws {
        // bash/zsh/sh splice a literal apostrophe into a single-quoted string with
        // the '\'' idiom (close, escaped quote, reopen). It must survive as one arg.
        let cmd = #"curl -X POST 'https://api.example.com/x' --data 'it'\''s a test'"#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.url, "https://api.example.com/x")
        XCTAssertEqual(request.rawBody, "it's a test")
    }

    func testImportCurlPowerShellDoubledQuotes() throws {
        // PowerShell / cmd / SQL embed a quote by doubling it: "" -> ".
        let cmd = #"curl -X POST "https://api.example.com/x" --data-raw "{""name"":""ada"",""n"":42}""#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.url, "https://api.example.com/x")
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertEqual(request.rawBody, #"{"name":"ada","n":42}"#)
        XCTAssertFalse(request.rawBody.contains("\"\""))
    }

    func testImportCurlPowerShellBacktickQuotes() throws {
        // PowerShell also escapes inner quotes inside double quotes with a backtick.
        let cmd = "curl --data-raw \"{`\"name`\":`\"ada`\"}\" \"https://api.example.com/x\""
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.url, "https://api.example.com/x")
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertEqual(request.rawBody, #"{"name":"ada"}"#)
        XCTAssertFalse(request.rawBody.contains("`"))
    }

    func testImportCurlSingleQuotedJSONUnchanged() throws {
        // The common bash form (double-quoted JSON inside single quotes) must keep
        // its quotes verbatim — the doubled-quote rule must not eat them.
        let cmd = #"curl 'https://api.example.com/x' --data '{"a":"b","c":1}'"#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.rawBody, #"{"a":"b","c":1}"#)
    }

    func testImportCurlFormWithUrlEncodedContentType() throws {
        // Postman/Insomnia export form fields as `--form 'k="v"'` (always double-
        // quoted) and may pair them with an explicit form-urlencoded Content-Type.
        // The quotes must be stripped from the values, and the explicit header must
        // win over `--form`'s default multipart so the body is urlencoded.
        let cmd = """
        curl --location 'https://api.example.com/sms' \
          --header 'Content-Type: application/x-www-form-urlencoded' \
          --form 'msisdn="0819188052"' \
          --form 'sender="OTP_SMS"' \
          --form 'force="standard"'
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.bodyMode, .formURLEncoded)
        XCTAssertEqual(request.bodyForm.count, 3)
        XCTAssertEqual(request.bodyForm[0].name, "msisdn")
        XCTAssertEqual(request.bodyForm[0].value, "0819188052")   // quotes stripped
        XCTAssertEqual(request.bodyForm[1].value, "OTP_SMS")
        XCTAssertEqual(request.bodyForm[2].value, "standard")
    }

    func testImportCurlFormDefaultsToMultipart() throws {
        // Without an explicit urlencoded Content-Type, `--form` stays multipart —
        // but the Postman-style surrounding quotes are still stripped.
        let cmd = "curl 'https://api.example.com/up' --form 'name=\"ada\"' --form 'file=@/tmp/x.png'"
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.bodyMode, .multipart)
        XCTAssertEqual(request.bodyForm[0].value, "ada")
        XCTAssertTrue(request.bodyForm[1].isFile)
        XCTAssertEqual(request.bodyForm[1].fileName, "/tmp/x.png")
    }

    func testImportCurlUsesUrlOptionAndSkipsValueOptionsBeforeIt() throws {
        let cmd = """
        curl --connect-timeout 10 --max-time 30 \
          --proxy http://127.0.0.1:8888 \
          --url 'https://api.example.com/users?active=1'
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.url, "https://api.example.com/users")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.queryParams.map(\.name), ["active"])
        XCTAssertEqual(request.queryParams.map(\.value), ["1"])
    }

    func testImportCurlHeaderConvenienceOptionsDoNotBecomeUrl() throws {
        let cmd = """
        curl -I -A 'HTTrail/1.0' -e 'https://ref.example/start' \
          -b 'sid=abc' -H 'X-Test: 1' \
          'https://api.example.com/profile'
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "HEAD")
        XCTAssertEqual(request.url, "https://api.example.com/profile")
        XCTAssertEqual(request.headers.first { $0.name == "User-Agent" }?.value, "HTTrail/1.0")
        XCTAssertEqual(request.headers.first { $0.name == "Referer" }?.value, "https://ref.example/start")
        XCTAssertEqual(request.headers.first { $0.name == "Cookie" }?.value, "sid=abc")
        XCTAssertEqual(request.headers.first { $0.name == "X-Test" }?.value, "1")
    }

    func testImportCurlGetMovesDataToQueryParams() throws {
        let cmd = """
        curl -G 'https://api.example.com/search' \
          --data-urlencode 'q=ada lovelace' \
          --data 'page=1&sort=desc'
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://api.example.com/search")
        XCTAssertEqual(request.bodyMode, .none)
        XCTAssertEqual(request.queryParams.map(\.name), ["q", "page", "sort"])
        XCTAssertEqual(request.queryParams.map(\.value), ["ada lovelace", "1", "desc"])
    }

    func testImportCurlGetUrlQueryBecomesDecodedParams() throws {
        let cmd = """
        curl 'https://www.thaibulksms.com/sms_api.php?username=bank&password=secret&sender=FINNAPP&message=test%20A%20return%2022%E2%80%9328%20Jun%E2%80%9926%2050%%20OFF&msisdn=0812345678&force=corporate&ScheduledDelivery='
        """
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://www.thaibulksms.com/sms_api.php")
        XCTAssertEqual(request.queryParams.map(\.name), [
            "username", "password", "sender", "message", "msisdn", "force", "ScheduledDelivery"
        ])
        let params = Dictionary(uniqueKeysWithValues: request.queryParams.map { ($0.name, $0.value) })
        XCTAssertEqual(params["username"], "bank")
        XCTAssertEqual(params["message"], "test A return 22–28 Jun’26 50% OFF")
        XCTAssertEqual(params["ScheduledDelivery"], "")
    }

    func testImportCurlAttachedShortOptionValues() throws {
        let cmd = #"curl -XPUT -H'Content-Type: application/json' -d'{"ok":true}' https://api.example.com/items/1"#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url, "https://api.example.com/items/1")
        XCTAssertEqual(request.headers.first?.name, "Content-Type")
        XCTAssertEqual(request.headers.first?.value, "application/json")
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertEqual(request.rawBody, #"{"ok":true}"#)
    }

    func testImportCurlJsonOptionAddsBodyAndHeaders() throws {
        let cmd = #"curl --json '{"name":"ada"}' https://api.example.com/users"#
        let request = try XCTUnwrap(CurlConverter().importCommand(cmd))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://api.example.com/users")
        XCTAssertEqual(request.bodyMode, .json)
        XCTAssertEqual(request.rawBody, #"{"name":"ada"}"#)
        XCTAssertEqual(request.headers.first { $0.name == "Content-Type" }?.value, "application/json")
        XCTAssertEqual(request.headers.first { $0.name == "Accept" }?.value, "application/json")
    }

    func testExtractCurlFromFront() {
        let cmd = "curl 'https://api.example.com/x' -H 'Accept: application/json'"
        XCTAssertEqual(AppModel.extractCurlCommand(from: cmd), cmd)
    }

    func testExtractCurlPastedAfterExistingText() {
        // Field already had a URL and the curl was pasted at the end (no space) —
        // the embedded command must still be found and the junk prefix dropped.
        let pasted = "https://old.example.com/pathcurl --location 'https://api.example.com/x' --data 'a=1'"
        let extracted = AppModel.extractCurlCommand(from: pasted)
        XCTAssertEqual(extracted, "curl --location 'https://api.example.com/x' --data 'a=1'")
    }

    func testExtractCurlPastedMidString() {
        let pasted = "draft note  curl -X POST 'https://api.example.com/y'"
        XCTAssertEqual(AppModel.extractCurlCommand(from: pasted),
                       "curl -X POST 'https://api.example.com/y'")
    }

    func testExtractCurlIgnoresPlainURLContainingCurl() {
        // A URL that merely contains "curl" is not a command — must not match.
        XCTAssertNil(AppModel.extractCurlCommand(from: "https://example.com/curl/docs"))
        XCTAssertNil(AppModel.extractCurlCommand(from: "https://curl.se/download.html"))
        XCTAssertNil(AppModel.extractCurlCommand(from: "curl"))   // bare word, no command
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
