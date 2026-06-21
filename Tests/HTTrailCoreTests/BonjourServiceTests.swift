import XCTest
@testable import HTTrailCore

final class BonjourServiceTests: XCTestCase {
    func testTXTEncodeDecodeRoundTrip() {
        let txt = BonjourTXT.encode(name: "Anu's Mac", port: 9090, caPort: 8443, caFP: "ab12cd34", pairPort: 0)
        let decoded = BonjourTXT.decode(txt)
        XCTAssertEqual(decoded.name, "Anu's Mac")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertEqual(decoded.caPort, 8443)
        XCTAssertEqual(decoded.caFP, "ab12cd34")
    }

    func testTXTDecodeMissingFieldsIsNil() {
        let decoded = BonjourTXT.decode([:])
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.port)
        XCTAssertNil(decoded.caPort)
        XCTAssertNil(decoded.caFP)
    }

    // Best-effort end-to-end: advertise on loopback and discover it. Requires
    // local Bonjour/mDNS to be available; if the environment forbids it, this
    // may time out — report it rather than treating as a hard failure.
    func testAdvertiseThenBrowseDiscoversService() {
        let advertiser = BonjourAdvertiser()
        advertiser.start(name: "TestMac", port: 9099, caPort: 8443, caFP: "deadbeef", pairPort: 0)
        defer { advertiser.stop() }

        let browser = BonjourBrowser()
        let exp = expectation(description: "discovered")
        let cancellable = browser.$found.sink { list in
            if list.contains(where: { $0.name == "TestMac" && $0.port == 9099 }) { exp.fulfill() }
        }
        browser.start()
        defer { browser.stop(); cancellable.cancel() }
        wait(for: [exp], timeout: 10)
    }
}
