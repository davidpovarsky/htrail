import XCTest
@testable import HTTrailCore

final class BodyEncodingTests: XCTestCase {
    // MARK: form-urlencoded

    func testURLEncodedSkipsDisabledFilesAndEmptyNames() {
        let fields = [
            BodyField(name: "a", value: "1"),
            BodyField(name: "b", value: "two words"),
            BodyField(name: "c", value: "x", enabled: false),     // disabled → skipped
            BodyField(name: "", value: "y"),                       // no name → skipped
            BodyField(name: "f", isFile: true, fileName: "x.bin"), // file → skipped in urlencoded
        ]
        XCTAssertEqual(BodyEncoder.urlEncoded(fields), "a=1&b=two+words")
    }

    func testURLEncodedPercentEncodesReserved() {
        let fields = [BodyField(name: "q", value: "a&b=c")]
        XCTAssertEqual(BodyEncoder.urlEncoded(fields), "q=a%26b%3Dc")
    }

    // MARK: multipart

    func testMultipartIncludesTextAndFileParts() {
        let fields = [
            BodyField(name: "field", value: "hello"),
            BodyField(name: "upload", isFile: true, fileName: "a.txt", fileData: Data("FILE".utf8)),
        ]
        let body = String(decoding: BodyEncoder.multipart(fields), as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"field\"\r\n\r\nhello\r\n"))
        XCTAssertTrue(body.contains("name=\"upload\"; filename=\"a.txt\""))
        XCTAssertTrue(body.contains("\r\nFILE\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(BodyEncoder.multipartBoundary)--\r\n"))
    }

    // MARK: JSON validation

    func testJSONValidation() {
        XCTAssertEqual(JSONValidation.check("   "), .empty)
        XCTAssertEqual(JSONValidation.check(#"{"a":1}"#), .valid)
        XCTAssertEqual(JSONValidation.check("[1,2,3]"), .valid)
        if case .invalid = JSONValidation.check("{bad json") {} else { XCTFail("expected invalid") }
    }

    func testJSONPrettyPrint() {
        let pretty = JSONValidation.prettyPrinted(#"{"b":2,"a":1}"#)
        XCTAssertNotNil(pretty)
        XCTAssertTrue(pretty!.contains("\n"))
        XCTAssertNil(JSONValidation.prettyPrinted("not json"))
    }

    // MARK: runner integration

    func testRunnerBuildsURLEncodedBodyFromFields() {
        var req = APIRequest(method: "POST", url: "https://example.com")
        req.bodyMode = .formURLEncoded
        req.bodyForm = [BodyField(name: "user", value: "{{u}}"), BodyField(name: "k", value: "v")]
        let urlRequest = RequestRunner().makeURLRequest(req, environment: ["u": "alice"])
        XCTAssertEqual(urlRequest?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: urlRequest?.httpBody ?? Data(), as: UTF8.self), "user=alice&k=v")
    }

    func testRunnerBuildsMultipartBodyAndContentType() {
        var req = APIRequest(method: "POST", url: "https://example.com")
        req.bodyMode = .multipart
        req.bodyForm = [BodyField(name: "f", value: "v")]
        let urlRequest = RequestRunner().makeURLRequest(req, environment: [:])
        XCTAssertEqual(urlRequest?.value(forHTTPHeaderField: "Content-Type"), BodyEncoder.multipartContentType)
        let body = String(decoding: urlRequest?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"f\"\r\n\r\nv\r\n"))
    }

    // MARK: cURL round-trip

    func testCurlImportFormFields() {
        let req = CurlConverter().importCommand("curl -F 'name=Bob' -F 'avatar=@me.png' https://x.test/u")
        XCTAssertEqual(req?.bodyMode, .multipart)
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.bodyForm.count, 2)
        XCTAssertEqual(req?.bodyForm.first?.name, "name")
        XCTAssertEqual(req?.bodyForm.last?.isFile, true)
        XCTAssertEqual(req?.bodyForm.last?.fileName, "me.png")
    }

    func testCurlExportFormFields() {
        var req = APIRequest(method: "POST", url: "https://x.test/u")
        req.bodyMode = .formURLEncoded
        req.bodyForm = [BodyField(name: "a", value: "1")]
        let curl = CurlConverter().exportCommand(req)
        XCTAssertTrue(curl.contains("--data 'a=1'"), curl)
    }
}
