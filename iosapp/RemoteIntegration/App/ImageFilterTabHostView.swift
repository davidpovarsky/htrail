import SwiftUI

/// The full application's Image Filter tab in the Remote build.
/// Classification happens on the selected server; no local model UI is exposed.
struct ImageFilterTabHostView: View {
    var body: some View {
        NavigationStack {
            PurelineWireGuardView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Pureline Remote", systemImage: "network.badge.shield.half.filled")
                            .font(.headline)
                        Text("Image classification runs on your filtering server. On-device capture and local image models are unavailable in this edition.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial)
                    .accessibilityIdentifier("pureline.remote.edition")
                }
        }
    }
}
