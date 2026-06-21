import SwiftUI
import WebKit
import AppKit
import HTTrailCore

/// The single permitted use of HTML in HTTrail: rendering a captured response
/// body as a live web preview (the "preview/renderer" requirement).
struct HTMLPreview: NSViewRepresentable {
    let html: String
    /// Base URL used to resolve relative resources, if known.
    var baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}

/// Renders an image response body, top-aligned and scrollable. SVG is drawn by
/// the web view (NSImage can't decode SVG); raster formats (PNG/JPEG/WebP/GIF/
/// BMP/TIFF/HEIC) are decoded by `NSImage`.
struct ImagePreview: View {
    let data: Data
    var contentType: String? = nil
    var body: some View {
        if ImageSniffer.isSVG(data: data, contentType: contentType) {
            HTMLPreview(html: ImageSniffer.svgPreviewHTML(data))
        } else if let image = NSImage(data: data) {
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView("Can't decode image", systemImage: "photo")
        }
    }
}
