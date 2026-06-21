import Foundation

/// Decides whether a response body is a previewable image and which family it
/// belongs to, so the UI can route SVG to a web renderer and raster formats
/// (PNG/JPEG/WebP/GIF/BMP/TIFF/HEIC/ICO) to `NSImage`/`UIImage`.
///
/// Detection prefers the `Content-Type`, then falls back to magic bytes — so an
/// image served as `application/octet-stream` (or a mislabelled SVG) still
/// previews.
public enum ImageSniffer {

    public enum Kind: Equatable, Sendable { case svg, raster }

    /// The image family of `data`, or `nil` if it doesn't look like an image.
    public static func kind(data: Data, contentType: String?) -> Kind? {
        if isSVG(data: data, contentType: contentType) { return .svg }
        if isRaster(data: data, contentType: contentType) { return .raster }
        return nil
    }

    /// True if `data` can be previewed as an image.
    public static func isImage(data: Data, contentType: String?) -> Bool {
        kind(data: data, contentType: contentType) != nil
    }

    /// SVG by content-type (`image/svg+xml`, or anything mentioning `svg`) or by
    /// sniffing the leading markup (`<svg …>` / `<?xml …><svg>`).
    public static func isSVG(data: Data, contentType: String?) -> Bool {
        if let ct = contentType?.lowercased(), ct.contains("svg") { return true }
        if data.isEmpty { return false }
        guard let s = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        let head = s.drop { $0 == "\u{FEFF}" || $0.isWhitespace }.lowercased()
        if head.hasPrefix("<svg") { return true }
        if head.hasPrefix("<?xml") && head.contains("<svg") { return true }
        return false
    }

    /// Raster image by `image/*` content-type (excluding SVG) or by magic bytes.
    public static func isRaster(data: Data, contentType: String?) -> Bool {
        if let ct = contentType?.lowercased(), ct.hasPrefix("image/"), !ct.contains("svg") {
            return true
        }
        return hasRasterMagic(data)
    }

    /// Recognise the common raster signatures from the first 16 bytes.
    public static func hasRasterMagic(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return false }
        func eq(_ off: Int, _ sig: [UInt8]) -> Bool {
            guard b.count >= off + sig.count else { return false }
            for (i, v) in sig.enumerated() where b[off + i] != v { return false }
            return true
        }
        if eq(0, [0x89, 0x50, 0x4E, 0x47]) { return true }                       // PNG
        if eq(0, [0xFF, 0xD8, 0xFF]) { return true }                             // JPEG
        if eq(0, [0x47, 0x49, 0x46, 0x38]) { return true }                       // GIF8x
        if eq(0, [0x42, 0x4D]) { return true }                                   // BMP
        if eq(0, [0x49, 0x49, 0x2A, 0x00]) || eq(0, [0x4D, 0x4D, 0x00, 0x2A]) { return true } // TIFF
        if eq(0, [0x00, 0x00, 0x01, 0x00]) { return true }                       // ICO
        if eq(0, [0x52, 0x49, 0x46, 0x46]) && eq(8, [0x57, 0x45, 0x42, 0x50]) { return true } // RIFF…WEBP
        if eq(4, [0x66, 0x74, 0x79, 0x70]) { return true }                       // ISO-BMFF (HEIC/HEIF/AVIF)
        return false
    }

    /// Wrap raw SVG bytes in a minimal, inert HTML document that scales the image
    /// to fit the preview pane. Rendered by the app's `WKWebView` wrappers (which
    /// already disable JavaScript), since `NSImage`/`UIImage` can't decode SVG.
    public static func svgPreviewHTML(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:0;height:100%;}
          body{display:flex;align-items:center;justify-content:center;box-sizing:border-box;padding:8px;}
          img{max-width:100%;max-height:100vh;width:auto;height:auto;}
        </style></head>
        <body><img alt="SVG preview" src="data:image/svg+xml;base64,\(b64)"></body></html>
        """
    }
}
