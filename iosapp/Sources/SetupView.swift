import SwiftUI
import UIKit
import HTTrailCore

/// On-device capture (VPN + CA) provisioning, sharing for other devices, device
/// info, HAR export and capture guidance.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var shareURL: URL?
    @State private var portText = ""
    @State private var startGateReadiness: CaptureStartReadiness?
    @State private var checkingStartReadiness = false

    var body: some View {
        NavigationStack {
            Form {
                onDeviceCaptureSection
                rootCASection
                proxySection
                otherDevicesSection
                deviceSection
                captureSection
                Section {
                    Text(model.statusMessage)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.color.textFaint)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground)
            .tint(Theme.color.accent)
            .preferredColorScheme(.dark)
            .htScreenChrome("Setup") { LiveStatusPill(active: vpn.isActive) }
            .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
            .sheet(isPresented: startGateBinding) {
                if let readiness = startGateReadiness {
                    CaptureSetupGateSheet(
                        readiness: readiness,
                        targetLabel: CaptureTarget.thisDevice.label,
                        isChecking: checkingStartReadiness,
                        onInstallProfile: installCaptureProfile,
                        onRecheck: startOnDeviceCapture,
                        onOpenSettings: openAppSettings
                    )
                }
            }
            .keyboardDismissButton()
            .task { await vpn.reload() }
            .task { await model.checkCATrust() }
            .onAppear { portText = "\(model.proxyPort)" }
        }
    }

    // MARK: - Shared row styling

    /// Surface fill for a Form section row in the v2 dark palette.
    private var rowBackground: some View {
        Theme.color.surface.opacity(0.55)
    }

    // MARK: - Root CA trust

    private var rootCASection: some View {
        Section {
            HStack(spacing: 13) {
                if model.caCheckInProgress {
                    ProgressView().controlSize(.regular).frame(width: 26, height: 26)
                } else {
                    Image(systemName: model.caTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(model.caTrusted ? Color(hex: "#34D399") : Theme.color.amber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.caCheckInProgress ? "Checking…"
                         : (model.caTrusted ? "Root CA trusted" : "Root CA not trusted"))
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Theme.color.textBright)
                    Text(model.caTrusted ? "Certificate Trust enabled"
                         : "Enable in Certificate Trust Settings")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.color.textDim)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await model.checkCATrust() }
                } label: {
                    Text("Re-check")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.color.textSoft)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.caCheckInProgress)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((model.caTrusted ? Theme.color.green : Theme.color.amber).opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((model.caTrusted ? Theme.color.green : Theme.color.amber).opacity(0.25), lineWidth: 1))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        } header: {
            HTEyebrow("Certificate Authority")
        } footer: {
            Text("HTTrail can only decrypt HTTPS once its root CA is installed and fully trusted (Settings ▸ General ▸ About ▸ Certificate Trust Settings).")
                .font(.caption)
                .foregroundStyle(Theme.color.textFaint)
        }
    }

    // MARK: - Proxy port

    private var proxySection: some View {
        Section {
            HStack {
                Text("Proxy port").foregroundStyle(Theme.color.textSoft)
                Spacer()
                TextField("9090", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.color.textBright)
                    .frame(width: 90)
                    .disabled(vpn.isActive || model.isProxyRunning)
            }
            .listRowBackground(rowBackground)

            if vpn.isActive || model.isProxyRunning {
                Text("Stop capturing to change the port.")
                    .font(.caption2).foregroundStyle(Theme.color.textFaint)
                    .listRowBackground(rowBackground)
            } else {
                Button("Apply Port") { commitPort() }
                    .foregroundStyle(Theme.color.accent)
                    .disabled(Int(portText) == model.proxyPort || Int(portText) == nil)
                    .listRowBackground(rowBackground)
            }
        } header: {
            HTEyebrow("Proxy")
        } footer: {
            Text("Port HTTrail listens on (1024–65535). Restart capture after changing it.")
                .font(.caption)
                .foregroundStyle(Theme.color.textFaint)
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
            CapturePrivacyDisclosure(targetLabel: CaptureTarget.thisDevice.label, compact: true)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            Text("Route this \(localDeviceNoun)'s traffic through HTTrail's on-device VPN to decrypt and inspect every request.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.color.textDim)
                .lineSpacing(2)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            // Step 1 — install the combined VPN + CA profile via the system flow.
            StepCard(number: "1", tint: Theme.color.blue, badgeText: Color(hex: "#BFD4FF"),
                     title: "Install VPN + CA Profile",
                     subtitle: "Opens Settings to approve the profile",
                     trailing: .chevron) {
                if let url = model.captureProfileInstallURL() { openURL(url) }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))

            // Step 2 — start/stop the installed capture VPN.
            if vpn.isActive {
                StepCard(number: "2", tint: Theme.color.red, badgeText: Color(hex: "#FCA5A5"),
                         title: "Stop Capturing This Device",
                         subtitle: "Turns off the local capture engine",
                         trailing: .stop) {
                    vpn.disable()
                    model.endCaptureSession()
                    model.stopCaptureMonitor()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
            } else {
                StepCard(number: "2", tint: Theme.color.green, badgeText: Color(hex: "#6EE7B7"),
                         title: checkingStartReadiness ? "Checking Capture Setup" : "Start Capturing This Device",
                         subtitle: "Turns on the local capture engine",
                         trailing: .play) {
                    startOnDeviceCapture()
                }
                .disabled(checkingStartReadiness)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
            }

            Text("Safari downloads the profile, then approve it in Settings ▸ General ▸ VPN & Device Management. Also enable trust under Settings ▸ General ▸ About ▸ Certificate Trust Settings.")
                .font(.caption2).foregroundStyle(Theme.color.textFaint)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))

            // Combined status pill: VPN state + which rules the engine is running.
            captureStatusPill
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            if let err = vpn.lastError {
                Text(err).font(.caption).foregroundStyle(Theme.color.red)
                    .listRowBackground(rowBackground)
            }
        } header: {
            HTEyebrow("Capture this device")
        }
    }

    private var startGateBinding: Binding<Bool> {
        Binding(
            get: { startGateReadiness != nil },
            set: { if !$0 { startGateReadiness = nil } }
        )
    }

    private func startOnDeviceCapture() {
        model.captureTarget = .thisDevice
        Task { await preflightAndStartOnDeviceCapture() }
    }

    @MainActor
    private func preflightAndStartOnDeviceCapture() async {
        guard !checkingStartReadiness else { return }
        checkingStartReadiness = true
        defer { checkingStartReadiness = false }

        await vpn.reload()
        await model.checkCATrust()
        let readiness = CaptureStartReadiness.evaluate(
            vpnConfigurationInstalled: vpn.hasConfiguration,
            certificateTrusted: model.caTrusted
        )
        guard readiness.canStart else {
            startGateReadiness = readiness
            model.statusMessage = "Capture setup needs attention before traffic is routed."
            return
        }

        _ = await model.applyCaptureTargetForStart()
        guard await vpn.startCapture(port: model.proxyPort) else {
            await vpn.reload()
            let latest = CaptureStartReadiness.evaluate(
                vpnConfigurationInstalled: vpn.hasConfiguration,
                certificateTrusted: model.caTrusted
            )
            if latest.canStart {
                model.statusMessage = vpn.lastError ?? "Could not start the capture VPN."
            } else {
                startGateReadiness = latest
                model.statusMessage = "Capture setup needs attention before traffic is routed."
            }
            return
        }

        startGateReadiness = nil
        model.beginCaptureSession()
        model.startCaptureMonitor(remote: nil)
    }

    private func installCaptureProfile() {
        if let url = model.captureProfileInstallURL() { openURL(url) }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private var localDeviceNoun: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// "VPN active · Capture engine: N rules · M allowlist" status pill that
    /// folds VPN state and the live engine heartbeat into one row.
    private var captureStatusPill: some View {
        HStack(spacing: 9) {
            ConnectionDot(status: vpn.isActive ? .live : .off)
            Text(vpn.isActive ? "VPN active" : vpn.statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(vpn.isActive ? Color(hex: "#6EE7B7") : Theme.color.textDim)
            if let status = model.captureEngineStatus, model.captureEngineLive {
                Text("· Capture engine: \(status.ruleCount) rule\(status.ruleCount == 1 ? "" : "s") · \(status.allowlistCount) allowlist")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.color.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else if vpn.isActive {
                Text("· Capture engine: starting…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.color.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Sharing for other devices

    private var otherDevicesSection: some View {
        Section {
            Text("To capture a *different* device through this one, share the proxy+CA profile (or the raw CA), install it there, then point that device's Wi-Fi proxy at \(model.deviceIP):\(model.proxyPort).")
                .font(.footnote).foregroundStyle(Theme.color.textDim)
                .listRowBackground(rowBackground)
            if let url = model.profileFileURL {
                ShareLink(item: url) {
                    Label("Share Proxy + CA Profile", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Theme.color.accent)
                }
                .listRowBackground(rowBackground)
            }
            if let url = model.caFileURL {
                ShareLink(item: url) {
                    Label("Share Root CA (.pem)", systemImage: "doc.text")
                        .foregroundStyle(Theme.color.accent)
                }
                .listRowBackground(rowBackground)
            }
        } header: {
            HTEyebrow("Capture another device")
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent {
                Text(model.deviceIP)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.color.textBright)
            } label: {
                Text("IP address").foregroundStyle(Theme.color.textSoft)
            }
            .listRowBackground(rowBackground)

            LabeledContent {
                HStack(spacing: 6) {
                    ConnectionDot(status: model.isProxyRunning ? .live : .off)
                    Text(model.isProxyRunning ? "Running" : "Stopped")
                        .font(Theme.mono(12))
                        .foregroundStyle(model.isProxyRunning ? Theme.color.green : Theme.color.textDim)
                }
            } label: {
                Text("LAN proxy").foregroundStyle(Theme.color.textSoft)
            }
            .listRowBackground(rowBackground)
        } header: {
            HTEyebrow("This device")
        }
    }

    private var captureSection: some View {
        Section {
            Button {
                shareURL = model.exportHAR()
            } label: {
                Label("Export current capture (HAR)", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.color.textSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
                .buttonStyle(.plain)
                .disabled(model.flows.isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            Text("\(model.flows.count) flows in current capture")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.color.textDim)
                .listRowBackground(rowBackground)
            Text("Browse and export past sessions in the Capture tab.")
                .font(.caption2).foregroundStyle(Theme.color.textFaint)
                .listRowBackground(rowBackground)
        } header: {
            HTEyebrow("Capture")
        }
    }
}

/// A numbered onboarding step rendered as a tinted card: a rounded number badge,
/// a bold title + dim subtitle, and a trailing affordance (chevron / play / stop).
/// Matches the v2 design's blue "1" and green "2" capture steps.
private struct StepCard: View {
    enum Trailing { case chevron, play, stop }
    let number: String
    let tint: Color
    let badgeText: Color
    let title: String
    let subtitle: String
    let trailing: Trailing
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(number)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(badgeText)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.20),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Theme.color.textBright)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.color.textDim)
                }
                Spacer(minLength: 0)
                trailingIcon
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingIcon: some View {
        switch trailing {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.color.textFaint)
        case .play:
            Image(systemName: "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.color.green)
        case .stop:
            Image(systemName: "stop.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.color.red)
        }
    }
}
