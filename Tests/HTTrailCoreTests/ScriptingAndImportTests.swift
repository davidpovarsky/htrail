import XCTest
@testable import HTTrailCore

final class ScriptRunnerTests: XCTestCase {
    func testPreRequestSetsEnvAndHeader() {
        let request = APIRequest(url: "https://api.example.com")
        let script = """
        pm.environment.set("token", "xyz");
        pm.request.headers.add({ key: "X-Run", value: "1" });
        console.log("prepared");
        """
        let result = ScriptRunner().runPreRequest(script, request: request, environment: [:])
        XCTAssertEqual(result.environment["token"], "xyz")
        XCTAssertTrue(result.request.headers.contains { $0.name == "X-Run" && $0.value == "1" })
        XCTAssertEqual(result.consoleLog.first, "prepared")
        XCTAssertNil(result.error)
    }

    func testTestScriptAssertions() {
        let request = APIRequest(url: "https://api.example.com")
        let response = APIResponse(statusCode: 200,
                                   headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                                   body: Data(#"{"ok":true}"#.utf8), durationMS: 10, error: nil)
        let script = """
        pm.test("status is 200", function() { pm.expect(pm.response.code).to.equal(200); });
        pm.test("body ok", function() { pm.expect(pm.response.json().ok).to.equal(true); });
        pm.test("fails", function() { pm.expect(1).to.equal(2); });
        """
        let result = ScriptRunner().runTests(script, request: request, response: response, environment: [:])
        XCTAssertEqual(result.tests.count, 3)
        XCTAssertTrue(result.tests[0].passed)
        XCTAssertTrue(result.tests[1].passed)
        XCTAssertFalse(result.tests[2].passed)
    }
}

final class ImporterTests: XCTestCase {
    func testOpenAPIImport() throws {
        let doc = """
        {"openapi":"3.0.0","info":{"title":"Pet API"},
         "servers":[{"url":"https://api.pets.com"}],
         "paths":{"/pets":{"get":{"summary":"List pets"},"post":{"summary":"Create pet"}}}}
        """
        let collection = try XCTUnwrap(OpenAPIImporter().importDocument(Data(doc.utf8)))
        XCTAssertEqual(collection.name, "Pet API")
        XCTAssertEqual(collection.requests.count, 2)
        XCTAssertTrue(collection.requests.contains { $0.method == "GET" && $0.url == "https://api.pets.com/pets" })
    }

    func testPostmanImport() throws {
        let doc = """
        {"info":{"name":"My API"},
         "item":[{"name":"Login","request":{"method":"POST","header":[{"key":"Accept","value":"application/json"}],
         "url":{"raw":"https://api.example.com/login"},"body":{"raw":"{\\"u\\":1}"}}}]}
        """
        let collection = try XCTUnwrap(PostmanImporter().importDocument(Data(doc.utf8)))
        XCTAssertEqual(collection.name, "My API")
        XCTAssertEqual(collection.requests.first?.method, "POST")
        XCTAssertEqual(collection.requests.first?.url, "https://api.example.com/login")
        XCTAssertEqual(collection.requests.first?.bodyMode, .json)
    }
}
