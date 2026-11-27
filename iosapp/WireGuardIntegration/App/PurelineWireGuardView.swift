import SwiftUI
import UniformTypeIdentifiers

struct PurelineWireGuardView: View {
    @StateObject private var controller = PurelineWGController()
    @State private var importing = false
    @State private var importError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Label(controller.statusLabel, systemImage: controller.status == .connected ? "network.badge.shield.half.filled" : "network")
                    .accessibilityIdentifier("pureline.wg.status")
                if !controller.endpoint.isEmpty { LabeledContent("Server", value: controller.endpoint) }
                Button("Import WireGuard profile", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("pureline.wg.import")
                    .disabled(controller.busy || controller.isActive)
                if controller.isActive {
                    Button("Disconnect", role: .destructive) { Task { await controller.disconnect() } }
                        .accessibilityIdentifier("pureline.wg.disconnect")
                        .disabled(controller.busy)
                } else {
                    Button("Connect to remote filter", systemImage: "power") { Task { await controller.connect() } }
                        .accessibilityIdentifier("pureline.wg.connect")
                        .disabled(controller.busy || !controller.hasProfile || !PurelineWGController.supportsTunnel)
                }
                if controller.busy { ProgressView("Updating VPN…") }
            } header: { Text("Remote filtering") } footer: {
                Text("This mode sends traffic through your selected server for filtering. The local Pureline models are used only by local capture. A connected VPN does not by itself confirm image filtering.")
            }

            if controller.hasProfile {
                Section("Coverage") {
                    LabeledContent("IPv4", value: "Routed through server")
                    LabeledContent("IPv6", value: controller.routesIPv6 ? "Routed through server" : "Not included in this profile")
                    Text("Encrypted apps with certificate pinning and content loaded from an app's own cache may bypass image inspection. Check the server certificate and test the pages you use.")
                        .font(.footnote)
                }
                Section("Tunnel traffic") {
                    LabeledContent("Received", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: controller.statistics.receivedBytes), countStyle: .binary))
                    LabeledContent("Sent", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: controller.statistics.sentBytes), countStyle: .binary))
                    if controller.statistics.latestHandshake > 0 {
                        LabeledContent("Last handshake") {
                            Text(Date(timeIntervalSince1970: controller.statistics.latestHandshake), style: .relative)
                        }
                    } else { LabeledContent("Handshake", value: "Not observed") }
                }
            }

            Section("Server certificate") {
                Text("Install the certificate supplied by your filtering server and enable full trust in Settings → General → About → Certificate Trust Settings. The local HTTrail certificate is separate.")
                    .font(.footnote)
            }

            #if DEBUG
            Section("Development verification") {
                NavigationLink("Open filtering test browser") { PurelineFilteringLabView() }
                    .accessibilityIdentifier("pureline.wg.lab")
                if !PurelineWGController.supportsTunnel {
                    Text("The simulator can test this interface and a separately configured Mac filtering route. It cannot start the iOS packet tunnel.")
                        .font(.footnote)
                }
            }
            #endif

            if let message = controller.error ?? importError {
                Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("pureline.wg.error") }
            }
        }
        .navigationTitle("WireGuard")
        .task { await controller.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await controller.reload() } }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in controller.refreshStatistics() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 65_536 else { throw PurelineWGProfile.ProfileError.invalid("The profile is too large.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 65_536, let source = String(data: data, encoding: .utf8) else {
                    throw PurelineWGProfile.ProfileError.invalid("Select a UTF-8 WireGuard .conf file.")
                }
                importError = nil
                Task { await controller.install(source) }
            } catch { importError = error.localizedDescription }
        }
    }
}
