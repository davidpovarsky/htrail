import SwiftUI
import WebKit
import UIKit

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

/// Renders an image response body, top-aligned and scrollable.
struct ImagePreview: View {
    let data: Data
    var body: some View {
        if let image = UIImage(data: data) {
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
