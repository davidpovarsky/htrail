import XCTest
@testable import HTTrailCore

/// Unit tests for the copy/export/hex helpers shared by both apps.
final class ExportSupportTests: XCTestCase {

    func testHexDumpFormat() {
        let dump = HexDump.make(Data("HTTP/1.1".utf8))
        let firstLine = dump.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(firstLine.hasPrefix("00000000  48 54 54 50 2f 31 2e 31"), "offset+hex wrong: \(firstLine)")
        XCTAssertTrue(firstLine.hasSuffix("|HTTP/1.1|"), "ascii column wrong: \(firstLine)")
    }

    func testHexDumpNonPrintableBytes() {
        let dump = HexDump.make(Data([0x00, 0x1f, 0x7f, 0x41])) // NUL, US, DEL, 'A'
        XCTAssertTrue(dump.contains("|...A|"), "non-printables should render as dots: \(dump)")
    }

    func testHexDumpEmpty() {
        XCTAssertEqual(HexDump.make(Data()), "—")
    }

    func testHexDumpTruncationNoted() {
        let dump = HexDump.make(Data(repeating: 0x41, count: 100), maxBytes: 32)
        XCTAssertTrue(dump.contains("truncated for display"), "should note truncation")
    }

    func testFileExtensionMapping() {
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: "application/json"), "json")
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: "text/html; charset=utf-8"), "html")
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: "image/png"), "png")
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: "image/jpeg"), "jpg")
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: "application/octet-stream"), "bin")
        XCTAssertEqual(ExportSupport.fileExtension(forContentType: nil), "bin")
    }

    func testHeadersText() {
        let headers = [HeaderPair(name: "Content-Type", value: "application/json"),
                       HeaderPair(name: "X-Test", value: "42")]
        XCTAssertEqual(ExportSupport.headersText(headers), "Content-Type: application/json\nX-Test: 42")
    }
}
