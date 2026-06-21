import SwiftUI
import WebKit
import UIKit
import HTTrailCore

/// HTML response renderer — the only HTML in HTTrail, per design. JavaScript is
/// disabled so previews are inert.
struct WebPreview: UIViewRepresentable {
    let html: String
    var baseURL: URL?
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: .zero, configuration: config)
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}

/// Renders an image response body, top-aligned and scrollable. SVG is drawn by
/// the web view (UIImage can't decode SVG); raster formats (PNG/JPEG/WebP/GIF/
/// BMP/TIFF/HEIC) are decoded by `UIImage`.
struct ImagePreview: View {
    let data: Data
    var contentType: String? = nil
    var body: some View {
        if ImageSniffer.isSVG(data: data, contentType: contentType) {
            WebPreview(html: ImageSniffer.svgPreviewHTML(data))
        } else if let image = UIImage(data: data) {
            ScrollView {
                Image(uiImage: image)
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
