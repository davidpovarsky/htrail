import XCTest
@testable import HTTrailCore

/// Image-format detection for the response-body preview (SVG vs raster, by
/// content-type or magic bytes).
final class ImageSnifferTests: XCTestCase {

    func testPNGByMagic() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        XCTAssertEqual(ImageSniffer.kind(data: png, contentType: nil), .raster)
        // Mislabelled as octet-stream still previews.
        XCTAssertTrue(ImageSniffer.isImage(data: png, contentType: "application/octet-stream"))
    }

    func testJPEGByMagic() {
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])
        XCTAssertEqual(ImageSniffer.kind(data: jpg, contentType: nil), .raster)
    }

    func testGIFByMagic() {
        XCTAssertTrue(ImageSniffer.hasRasterMagic(Data("GIF89a".utf8)))
    }

    func testWebPByMagic() {
        var d = Data("RIFF".utf8); d.append(contentsOf: [0, 0, 0, 0]); d.append(Data("WEBP".utf8))
        XCTAssertEqual(ImageSniffer.kind(data: d, contentType: nil), .raster)
    }

    func testHEICByMagic() {
        var d = Data([0, 0, 0, 0x18]); d.append(Data("ftypheic".utf8))
        XCTAssertTrue(ImageSniffer.hasRasterMagic(d))
    }

    func testRasterByContentTypeAlone() {
        // image/* (non-SVG) is enough even without recognisable magic bytes.
        XCTAssertTrue(ImageSniffer.isRaster(data: Data([1, 2, 3, 4]), contentType: "image/png"))
    }

    func testSVGByContentType() {
        XCTAssertTrue(ImageSniffer.isSVG(data: Data(), contentType: "image/svg+xml"))
        XCTAssertEqual(ImageSniffer.kind(data: Data("<svg/>".utf8), contentType: "image/svg+xml"), .svg)
    }

    func testSVGBySniffPlainTag() {
        let d = Data("  \n<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        XCTAssertTrue(ImageSniffer.isSVG(data: d, contentType: nil))
        // Even mislabelled text/plain is recognised by sniffing.
        XCTAssertEqual(ImageSniffer.kind(data: d, contentType: "text/plain"), .svg)
    }

    func testSVGBySniffXMLProlog() {
        let d = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg></svg>".utf8)
        XCTAssertTrue(ImageSniffer.isSVG(data: d, contentType: nil))
    }

    func testSVGTakesPrecedenceOverRaster() {
        XCTAssertEqual(ImageSniffer.kind(data: Data("<svg></svg>".utf8), contentType: nil), .svg)
    }

    func testNonImageIsNil() {
        let json = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertNil(ImageSniffer.kind(data: json, contentType: "application/json"))
        XCTAssertFalse(ImageSniffer.isImage(data: json, contentType: "application/json"))
    }

    func testSVGPreviewHTMLEmbedsImage() {
        let svg = Data("<svg width=\"4\" height=\"4\"></svg>".utf8)
        let html = ImageSniffer.svgPreviewHTML(svg)
        XCTAssertTrue(html.contains("data:image/svg+xml;base64,"))
        XCTAssertTrue(html.contains(svg.base64EncodedString()))
    }
}
