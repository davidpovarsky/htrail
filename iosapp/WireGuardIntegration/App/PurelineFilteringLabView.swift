#if DEBUG
import SwiftUI
import WebKit
import Network

/// A real WebKit/URLSession client using a loopback test route. It never
/// impersonates a working iOS Network Extension or silently falls back direct.
@MainActor
final class PurelineLabBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var address: String
    @Published var pageStatus = "Ready"
    @Published var nativeStatus = ""
    @Published var nativeImages: [UIImage] = []
    let webView: WKWebView
    private let session: URLSession

    override init() {
        address = UserDefaults.standard.string(forKey: "purelineLabURL") ?? "https://example.com/"
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 18520), tlsOptions: nil)
        proxy.allowFailover = false
        // Only static loopback gallery HTML is direct; external images stay on WireGuard.
        proxy.excludedDomains = ["127.0.0.1", "localhost"]
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        let networking = URLSessionConfiguration.ephemeral
        networking.proxyConfigurations = [proxy]
        networking.urlCache = nil
        networking.requestCachePolicy = .reloadIgnoringLocalCacheData
        networking.timeoutIntervalForRequest = 45
        networking.timeoutIntervalForResource = 90
        session = URLSession(configuration: networking)
        super.init()
        webView.navigationDelegate = self
        webView.accessibilityIdentifier = "pureline.lab.web"
    }

    func load() {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            pageStatus = "Enter a complete HTTP or HTTPS address."
            return
        }
        pageStatus = "Loading through WireGuard lab…"
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageStatus = "Page loaded"
        refreshImageCount()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageStatus = "Load failed: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageStatus = "Load failed: \(error.localizedDescription)"
    }

    func refreshImageCount() {
        webView.evaluateJavaScript("JSON.stringify({total:document.images.length,loaded:Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).length})") { [weak self] result, _ in
            guard let text = result as? String, let data = text.data(using: .utf8),
                  let counts = try? JSONDecoder().decode(ImageCounts.self, from: data) else { return }
            Task { @MainActor in self?.pageStatus = "Page loaded · \(counts.loaded)/\(counts.total) images decoded" }
        }
    }

    func loadNativeSamples() async {
        nativeImages = []
        nativeStatus = "Loading with URLSession through the same WireGuard route…"
        let urls = [
            "https://randomuser.me/api/portraits/men/77.jpg",
            "https://randomuser.me/api/portraits/women/77.jpg",
            "https://randomuser.me/api/portraits/men/42.jpg",
            "https://randomuser.me/api/portraits/women/42.jpg"
        ]
        var failures = 0
        for text in urls {
            do {
                let (data, response) = try await session.data(from: URL(string: text)!)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let image = UIImage(data: data) else {
                    failures += 1
                    continue
                }
                nativeImages.append(image)
            } catch { failures += 1 }
        }
        nativeStatus = "\(nativeImages.count) images decoded · \(failures) failures"
    }

    private struct ImageCounts: Decodable { let total: Int; let loaded: Int }
}

struct PurelineFilteringLabView: View {
    @StateObject private var browser = PurelineLabBrowser()
    @State private var surface = 0

    var body: some View {
        VStack(spacing: 8) {
            Text("Mac WireGuard test route · not an iOS VPN")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("pureline.lab.route")
            Picker("Test client", selection: $surface) {
                Text("WebKit browser").tag(0)
                Text("Native images").tag(1)
            }.pickerStyle(.segmented).accessibilityIdentifier("pureline.lab.client")
            if surface == 0 {
                HStack {
                    TextField("https://", text: $browser.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).textFieldStyle(.roundedBorder)
                        .onSubmit { browser.load() }
                        .accessibilityIdentifier("pureline.lab.address")
                    Button("Go") { browser.load() }.accessibilityIdentifier("pureline.lab.go")
                }
                Text(browser.pageStatus).font(.caption).accessibilityIdentifier("pureline.lab.status")
                PurelineLabWebView(webView: browser.webView)
                Button("Check loaded images") { browser.refreshImageCount() }
            } else {
                Button("Load four public test images") { Task { await browser.loadNativeSamples() } }
                    .accessibilityIdentifier("pureline.lab.native.load")
                Text(browser.nativeStatus).font(.caption).accessibilityIdentifier("pureline.lab.native.status")
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                        ForEach(Array(browser.nativeImages.enumerated()), id: \.offset) { item in
                            Image(uiImage: item.element).resizable().scaledToFit()
                                .frame(maxWidth: 250).accessibilityLabel("Processed test image \(item.offset + 1)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .navigationTitle("Filtering lab")
        .task {
            if UserDefaults.standard.bool(forKey: "purelineNativeLab") {
                surface = 1
                await browser.loadNativeSamples()
            } else { browser.load() }
        }
    }
}

private struct PurelineLabWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
