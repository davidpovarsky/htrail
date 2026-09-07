import EmbeddedImageFilter
import HTTrailCore
import SwiftUI

/// HTTrail-owned shell around the complete vendored image-classifier UI.
/// The only downstream control added here is the opt-in direct VPN bridge switch;
/// the original classifier UI itself remains unchanged inside the module.
struct ImageFilterTabHostView: View {
    @State private var directFilteringEnabled = DirectImageFilterSettings.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Direct VPN filtering")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Run intercepted images through the classifier without the local HTTP server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $directFilteringEnabled)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            EmbeddedImageFilterRootView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: directFilteringEnabled) { _, enabled in
            DirectImageFilterSettings.isEnabled = enabled
        }
    }
}
