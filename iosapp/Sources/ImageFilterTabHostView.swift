import EmbeddedImageFilter
import HTTrailCore
import ImageFilterCore
import SwiftUI
import UniformTypeIdentifiers

/// HTTrail-owned shell around the complete vendored image-classifier UI.
/// The only downstream control added here is the opt-in direct VPN bridge switch;
/// the original classifier UI itself remains unchanged inside the module.
struct ImageFilterTabHostView: View {
    @State private var directFilteringEnabled = DirectImageFilterSettings.isEnabled
    @StateObject private var configuration = PurelineFilterConfigurationViewModel()
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pureline Filter Configuration")
                            .font(.headline)
                        Text("Direct VPN filtering uses the active on-device policy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("Direct VPN filtering", isOn: $directFilteringEnabled)
                        .labelsHidden()
                }

                if let snapshot = configuration.snapshot {
                    let config = snapshot.configuration
                    let revision = snapshot.revision
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        metadataRow("Active", revision.importedFilename ?? config.name)
                        metadataRow("Status", acknowledgementText(revision))
                        metadataRow("Name", config.name)
                        metadataRow("Schema", String(config.schemaVersion))
                        metadataRow("Revision", "#\(revision.sequence) · \(revision.hash.prefix(12))")
                        metadataRow("Validated", revision.validatedAt.formatted())
                        metadataRow("Applied", configuration.acknowledgement?.appliedAt?.formatted() ?? "Waiting for PacketTunnel")
                        metadataRow("Models", "MobileCLIP2 \(config.models.mobileCLIP2 ? "ON" : "OFF") · NudeNet \(config.models.nudeNet ? "ON" : "OFF")")
                    }
                    .font(.caption)
                }

                if let error = configuration.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                HStack {
                    Button("Import Configuration") { importing = true }
                    Button("Export Current Configuration") {
                        configuration.prepareExport(); exporting = configuration.exportDocument != nil
                    }
                    Button("Restore Default") { configuration.restoreDefault() }
                }
                .buttonStyle(.bordered)
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
        .onAppear { configuration.start() }
        .onDisappear { configuration.stop() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { configuration.importConfiguration(from: url) }
            else if case .failure(let error) = result { configuration.errorMessage = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $exporting, document: configuration.exportDocument,
            contentType: .json, defaultFilename: configuration.snapshot?.configuration.name ?? "pureline-filter"
        ) { result in
            if case .failure(let error) = result { configuration.errorMessage = error.localizedDescription }
            configuration.exportDocument = nil
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }

    private func acknowledgementText(_ revision: PurelineFilterRevision) -> String {
        guard let acknowledgement = configuration.acknowledgement else { return "Valid · PacketTunnel not yet acknowledged" }
        return acknowledgement.hash == revision.hash
            ? "Valid · Applied to PacketTunnel"
            : "Valid · PacketTunnel is on revision #\(acknowledgement.sequence)"
    }
}
