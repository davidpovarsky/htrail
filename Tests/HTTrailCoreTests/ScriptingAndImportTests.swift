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

    func testPostmanBackupImportPreservesCollectionsFoldersRequestsAndEnvironments() throws {
        let doc = """
        {
          "version": 1,
          "collections": [{
            "id": "col-1",
            "name": "Legacy API",
            "order": ["root-req"],
            "folders_order": ["folder-1"],
            "folders": [
              {"id": "folder-1", "name": "Auth", "folder": null, "order": ["login-req"], "folders_order": ["folder-2"]},
              {"id": "folder-2", "name": "Nested", "folder": "folder-1", "order": ["form-req"], "folders_order": []}
            ],
            "requests": [
              {
                "id": "root-req",
                "name": "Root Ping",
                "method": "GET",
                "url": "https://api.example.com/ping?debug=1",
                "queryParams": [{"key": "debug", "value": "1", "enabled": true}],
                "headerData": [{"key": "Accept", "value": "application/json", "enabled": true}],
                "events": [{"listen": "test", "script": {"exec": ["pm.test(\\\"ok\\\", function () {});"]}}]
              },
              {
                "id": "login-req",
                "folder": "folder-1",
                "name": "Login",
                "method": "POST",
                "url": "https://api.example.com/login",
                "headerData": [{"key": "Content-Type", "value": "application/json", "enabled": true}],
                "dataMode": "raw",
                "rawModeData": "{\\"u\\":1}",
                "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "{{token}}"}]}
              },
              {
                "id": "form-req",
                "folder": "folder-2",
                "name": "Submit Form",
                "method": "POST",
                "url": "https://api.example.com/form",
                "dataMode": "urlencoded",
                "data": [{"key": "email", "value": "ada@example.com", "enabled": true, "type": "text"}],
                "events": [{"listen": "prerequest", "script": {"exec": "pm.environment.set('x', 'y');"}}]
              }
            ]
          }],
          "environments": [{
            "id": "env-1",
            "name": "Dev",
            "values": [
              {"key": "baseUrl", "value": "https://dev.example.com", "enabled": true},
              {"key": "disabled", "value": "nope", "enabled": false}
            ]
          }]
        }
        """

        let imported = try PostmanBackupImporter().importBackup(Data(doc.utf8))

        XCTAssertEqual(imported.collections.count, 1)
        let collection = try XCTUnwrap(imported.collections.first)
        XCTAssertEqual(collection.name, "Legacy API")
        XCTAssertEqual(collection.requests.map(\.name), ["Root Ping"])
        XCTAssertEqual(collection.folders.map(\.name), ["Auth"])

        let root = try XCTUnwrap(collection.requests.first)
        XCTAssertEqual(root.url, "https://api.example.com/ping")
        XCTAssertEqual(root.queryParams.map(\.name), ["debug"])
        XCTAssertEqual(root.headers.first?.name, "Accept")
        XCTAssertEqual(root.testScript, "pm.test(\"ok\", function () {});")

        let authFolder = try XCTUnwrap(collection.folders.first)
        let login = try XCTUnwrap(authFolder.requests.first)
        XCTAssertEqual(login.name, "Login")
        XCTAssertEqual(login.method, "POST")
        XCTAssertEqual(login.bodyMode, .json)
        XCTAssertEqual(login.rawBody, #"{"u":1}"#)
        XCTAssertEqual(login.auth.type, .bearer)
        XCTAssertEqual(login.auth.token, "{{token}}")

        let nested = try XCTUnwrap(authFolder.folders.first)
        let form = try XCTUnwrap(nested.requests.first)
        XCTAssertEqual(form.bodyMode, .formURLEncoded)
        XCTAssertEqual(form.bodyForm.first?.name, "email")
        XCTAssertEqual(form.bodyForm.first?.value, "ada@example.com")
        XCTAssertEqual(form.preRequestScript, "pm.environment.set('x', 'y');")

        XCTAssertEqual(imported.environments.count, 1)
        let environment = try XCTUnwrap(imported.environments.first)
        XCTAssertEqual(environment.name, "Dev")
        XCTAssertEqual(environment.variables.map(\.name), ["baseUrl", "disabled"])
        XCTAssertFalse(environment.variables[1].enabled)
    }

    func testPostmanBackupLocatorSelectsNewestDatedBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostmanBackups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = directory.appendingPathComponent("backup-2026-01-01T00-00-00.000Z.json")
        let newest = directory.appendingPathComponent("backup-2026-06-25T13-20-56.301Z.json")
        let unrelated = directory.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: older)
        try Data("{}".utf8).write(to: newest)
        try Data("{}".utf8).write(to: unrelated)

        let locator = PostmanBackupLocator(postmanDirectory: directory)

        XCTAssertEqual(locator.latestBackupFile()?.lastPathComponent, newest.lastPathComponent)
    }
}
