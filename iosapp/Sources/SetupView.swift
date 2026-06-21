import SwiftUI
import HTTrailCore

/// On-device capture (VPN + CA) provisioning, sharing for other devices, device
/// info, HAR export and capture guidance.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                onDeviceCaptureSection
                rootCASection
                proxySection
                otherDevicesSection
                deviceSection
                captureSection
                Section { Text(model.statusMessage).font(.caption).foregroundStyle(.secondary) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .navigationTitle("Setup")
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
            .keyboardDismissButton()
            .task { await vpn.reload() }
            .task { await model.checkCATrust() }
            .onAppear { portText = "\(model.proxyPort)" }
        }
    }

    // MARK: - Root CA trust

    private var rootCASection: some View {
        Section {
            LabeledContent("Root CA") {
                HStack(spacing: 6) {
                    if model.caCheckInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.caTrusted ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(model.caTrusted ? Color.green : Color.orange)
                    }
                    Text(model.caCheckInProgress ? "Checking…"
                         : (model.caTrusted ? "Installed & trusted" : "Not trusted"))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await model.checkCATrust() }
            } label: { Label("Re-check CA Trust", systemImage: "arrow.clockwise") }
                .disabled(model.caCheckInProgress)
        } header: {
            Text("Certificate Authority")
        } footer: {
            Text("HTTrail can only decrypt HTTPS once its root CA is installed and fully trusted (Settings ▸ General ▸ About ▸ Certificate Trust Settings).")
        }
    }

    // MARK: - Proxy port

    private var proxySection: some View {
        Section {
            HStack {
                Text("Proxy port")
                Spacer()
                TextField("9090", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .disabled(vpn.isActive || model.isProxyRunning)
            }
            if vpn.isActive || model.isProxyRunning {
                Text("Stop capturing to change the port.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Apply Port") { commitPort() }
                    .disabled(Int(portText) == model.proxyPort || Int(portText) == nil)
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text("Port HTTrail listens on (1024–65535). Restart capture after changing it.")
        }
    }

    private func commitPort() {
        guard let port = Int(portText) else { portText = "\(model.proxyPort)"; return }
        model.setProxyPort(port)
        portText = "\(model.proxyPort)"
    }

    // MARK: - On-device capture (VPN + CA)

    private var onDeviceCaptureSection: some View {
        Section {
            Text("Capture this iPhone's own HTTP/HTTPS traffic. Two steps: install the profile (adds the capture VPN + root CA), then start capturing.")
                .font(.footnote).foregroundStyle(.secondary)

            // Step 1 — install the combined VPN + CA profile via the system flow.
            Button {
                if let url = model.captureProfileInstallURL() { openURL(url) }
            } label: {
                Label("1. Install VPN + CA Profile", systemImage: "arrow.down.doc")
            }
            Text("Safari downloads the profile, then approve it in Settings ▸ General ▸ VPN & Device Management. Also enable trust under Settings ▸ General ▸ About ▸ Certificate Trust Settings.")
                .font(.caption2).foregroundStyle(.secondary)

            // Step 2 — start/stop the installed capture VPN.
            if vpn.isActive {
                Button(role: .destructive) {
                    vpn.disable()
                    model.endCaptureSession()
                } label: { Label("Stop Capturing", systemImage: "stop.circle") }
            } else {
                Button {
                    model.beginCaptureSession()
                    Task { await vpn.startCapture(port: model.proxyPort) }
                } label: { Label("2. Start Capturing This Device", systemImage: "shield.lefthalf.filled") }
            }

            LabeledContent("VPN status") {
                HStack(spacing: 6) {
                    Circle().fill(vpn.isActive ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(vpn.statusText).foregroundStyle(.secondary)
                }
            }
            // Confirms the background capture engine is live and which rules it's
            // actually running — so "are my rules wired?" is directly observable.
            if let status = model.captureEngineStatus, model.captureEngineLive {
                LabeledContent("Capture engine") {
                    Text("\(status.ruleCount) rule\(status.ruleCount == 1 ? "" : "s") · \(status.allowlistCount) allowlist")
                        .foregroundStyle(.secondary)
                }
            } else if vpn.isActive {
                LabeledContent("Capture engine") {
                    Text("starting…").foregroundStyle(.secondary)
                }
            }
            if let err = vpn.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Capture this device")
        }
    }

    // MARK: - Sharing for other devices

    private var otherDevicesSection: some View {
        Section("Capture another device") {
            Text("To capture a *different* device through this one, share the proxy+CA profile (or the raw CA), install it there, then point that device's Wi-Fi proxy at \(model.deviceIP):\(model.proxyPort).")
                .font(.footnote).foregroundStyle(.secondary)
            if let url = model.profileFileURL {
                ShareLink(item: url) { Label("Share Proxy + CA Profile", systemImage: "square.and.arrow.up") }
            }
            if let url = model.caFileURL {
                ShareLink(item: url) { Label("Share Root CA (.pem)", systemImage: "doc.text") }
            }
        }
    }

    private var deviceSection: some View {
        Section("This device") {
            LabeledContent("IP address", value: model.deviceIP)
            LabeledContent("LAN proxy", value: model.isProxyRunning ? "Running" : "Stopped")
        }
    }

    private var captureSection: some View {
        Section("Capture") {
            Button {
                shareURL = model.exportHAR()
            } label: { Label("Export Current Capture (HAR)…", systemImage: "square.and.arrow.up") }
                .disabled(model.flows.isEmpty)
            Text("\(model.flows.count) flows in current capture").font(.caption).foregroundStyle(.secondary)
            Text("Browse and export past sessions in the Capture tab.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
