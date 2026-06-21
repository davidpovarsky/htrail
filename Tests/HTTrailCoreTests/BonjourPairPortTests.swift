import XCTest
@testable import HTTrailCore

final class BonjourPairPortTests: XCTestCase {
    func testTXTRoundTripIncludesPairPort() {
        let txt = BonjourTXT.encode(name: "Mac", port: 9090, caPort: 0, caFP: "", pairPort: 54321)
        let decoded = BonjourTXT.decode(txt)
        XCTAssertEqual(decoded.name, "Mac")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertEqual(decoded.pairPort, 54321)
    }

    func testDecodeToleratesMissingPairPort() {
        let legacy: [String: Data] = ["name": Data("Mac".utf8), "port": Data("9090".utf8)]
        let decoded = BonjourTXT.decode(legacy)
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertNil(decoded.pairPort)
    }

    /// `NetService.dictionary(fromTXTRecord:)` yields `NSNull` for an empty-valued
    /// TXT key (e.g. the Mac advertising `caFP: ""`). Decoding must tolerate it
    /// rather than force-bridging NSNull→Data and trapping (crash on iOS launch).
    func testDecodeToleratesNSNullValues() {
        let txt: [String: Any] = [
            "name": Data("Mac".utf8),
            "port": Data("9090".utf8),
            "caFP": NSNull(),
            "caPort": NSNull(),
            "pairPort": Data("5555".utf8),
        ]
        let decoded = BonjourTXT.decode(txt)
        XCTAssertEqual(decoded.name, "Mac")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertNil(decoded.caFP)
        XCTAssertNil(decoded.caPort)
        XCTAssertEqual(decoded.pairPort, 5555)
    }
}
