import Foundation
import XCTest
@testable import HTTrailCore

final class ImageSnifferQATests: XCTestCase {
    func testRasterDetectionByContentTypeAndMagicBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(ImageSniffer.kind(data: png, contentType: "image/png"), .raster)
        XCTAssertTrue(ImageSniffer.isImage(data: png, contentType: "application/octet-stream"))
        XCTAssertFalse(ImageSniffer.isImage(data: Data("not-an-image".utf8), contentType: "text/plain"))
        print("HTTRAIL_RUNTIME_STEP image_sniffer=pass")
    }
}
