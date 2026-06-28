import SwiftUI
import UIKit
import HTTrailCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var harURL: URL?
    @State private var editMode: EditMode = .inactive
    @State private var renaming: CaptureSession?
    @State private var renameText = ""
    @State private var showLocalNetInfo = false
    @State private var showManualEntry = false
    @State private var startGateReadiness: CaptureStartReadiness?
    @State private var checkingStartReadiness = false

    var body: some View {
        NavigationStack(path: $model.capturePath) {
            ZStack {
                Theme.appBackground
                VStack(spacing: 0) {
                    controlBar
                    if !vpn.isActive { capturePrivacyNotice }
                    discoveredMacsBar
                    Divider().overlay(Theme.color.hairline)
                    sessionsList
                }
            }
            .htScreenChrome("Capture") { LiveStatusPill(active: vpn.isActive) }
            .navigationDestination(for: CaptureSession.self) { session in
                sessionFlows(session)
            }
            .sheet(item: $harURL) { url in ShareSheet(items: [url]) }
            .alert("Rename Session", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let s = renaming { model.renameSession(s.id, to: renameText) }; renaming = nil }
            }
            .keyboardDismissButton()
            .onAppear { resumeBrowsingIfDisclosed() }
            .onDisappear { model.stopBonjourBrowsing() }
            .sheet(isPresented: $showLocalNetInfo) {
                LocalNetworkInfoSheet(onContinue: {
                    // Disclosure accepted: only NOW may we browse (which triggers
                    // the OS Local Network prompt) — disclosure shown first.
                    model.bonjourDisclosureShown = true
                    model.startBonjourBrowsing()
                })
            }
            .sheet(isPresented: $showManualEntry) {
                ManualProxySheet(host: $model.manualProxyHost, port: $model.manualProxyPort) {
                    selectTarget(.manual(host: model.manualProxyHost, port: model.manualProxyPort))
                }
            }
            .sheet(isPresented: startGateBinding) {
                if let readiness = startGateReadiness {
                    CaptureSetupGateSheet(
                        readiness: readiness,
                        targetLabel: model.captureTarget.label,
                        isChecking: checkingStartReadiness,
                        onInstallProfile: installCaptureProfile,
                        onRecheck: startCapture,
                        onOpenSettings: openAppSettings
                    )
                }
            }
            .safeAreaInset(edge: .top) { captureBanner }
        }
    }

    private var controlBar: some View {
        HStack {
            if vpn.isActive {
                Button { stopCapture() } label: {
                    Label("Stop", systemImage: "stop.circle.fill").font(.headline)
                }.tint(Theme.color.red)
            } else {
                Button { model.captureTarget = .thisDevice; startCapture() } label: {
                    Label(checkingStartReadiness ? "Checking…" : "Start (\(localDeviceTitle))",
                          systemImage: checkingStartReadiness ? "arrow.triangle.2.circlepath" : "play.circle.fill")
                        .font(.headline)
                }
                .tint(Theme.color.green)
                .disabled(checkingStartReadiness)
                Button { showManualEntry = true } label: {
                    Image(systemName: "square.and.pencil").font(.headline)
                }.tint(Theme.color.textDim)
                .accessibilityLabel("Manual proxy")
            }
            Spacer()
            if vpn.isActive {
                HStack(spacing: 6) {
                    ConnectionDot(status: .error)
                    Text("REC").font(Theme.mono(11, .bold)).foregroundStyle(Theme.color.red)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.color.red.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.color.red.opacity(0.3), lineWidth: 1))
                .padding(.trailing, 4)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(model.deviceIP):\(model.proxyPort)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.color.textDim)
                Text(vpn.isActive ? "Listening" : "Stopped")
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(vpn.isActive ? Theme.color.green : Theme.color.textFaint)
            }
        }
        .padding()
        .background(Theme.color.surface.opacity(0.5))
    }

    private var capturePrivacyNotice: some View {
        CapturePrivacyDisclosure(targetLabel: model.captureTarget.label, compact: true)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Theme.color.surface.opacity(0.28))
    }

    /// Separate, always-visible list of Macs discovered over Bonjour, each with
    /// its own explicit "capture here" button (no hidden long-press menu). When
    /// none are found yet, a hint points at the usual culprits.
    @ViewBuilder
    private var discoveredMacsBar: some View {
        if !vpn.isActive {
            VStack(alignment: .leading, spacing: 8) {
                if !model.discoveredProxies.isEmpty {
                    HTEyebrow("Macs on your network")
                    ForEach(model.discoveredProxies) { proxy in
                        Button { selectTarget(.remote(proxy)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer").foregroundStyle(Theme.color.cyan)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Capture on \(proxy.name)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.color.textBright)
                                    Text("\(proxy.host):\(proxy.port)")
                                        .font(Theme.mono(11)).foregroundStyle(Theme.color.textDim)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.color.green)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Theme.color.surface, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                                .strokeBorder(Theme.color.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                } else if !model.bonjourDisclosureShown {
                    Button { showLocalNetInfo = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer.and.arrow.down")
                                .foregroundStyle(Theme.color.cyan)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Find Macs for remote capture")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.color.textBright)
                                Text("Shows the Local Network prompt after an explanation")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.color.textDim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.color.textFaint)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Theme.color.surface, in: RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Theme.color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else if model.bonjourDisclosureShown {
                    Label("Looking for Macs running HTTrail on this Wi-Fi… If none appear: open HTTrail on the Mac, Start the proxy, enable “Discoverable over Bonjour”, and make sure Settings ▸ HTTrail ▸ Local Network is on and both devices share the same Wi-Fi.",
                          systemImage: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(Theme.color.textDim)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Capture actions

    private var startGateBinding: Binding<Bool> {
        Binding(
            get: { startGateReadiness != nil },
            set: { if !$0 { startGateReadiness = nil } }
        )
    }

    /// Browse only after the user has seen the Local Network disclosure, so the
    /// OS permission prompt never appears before our explanation (App Store).
    private func resumeBrowsingIfDisclosed() {
        if model.bonjourDisclosureShown { model.startBonjourBrowsing() }
    }

    private func selectTarget(_ target: CaptureTarget) {
        model.captureTarget = target
        if target.remoteHostPort != nil { startCapture() }
    }

    private func startCapture() {
        Task {
            await preflightAndStartCapture()
        }
    }

    @MainActor
    private func preflightAndStartCapture() async {
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

        let targetIsRemote = model.captureTarget.remoteHostPort != nil
        let endpoint = await model.applyCaptureTargetForStart()
        if targetIsRemote && endpoint == nil {
            model.statusMessage = "Choose a reachable Mac proxy before starting capture."
            return
        }

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
        if case .thisDevice = model.captureTarget {
            model.beginCaptureSession()
        }
        // Continuously monitor health (remote Mac probe, or on-device engine
        // heartbeat) so the banner reflects reality for the whole session.
        model.startCaptureMonitor(remote: endpoint)
    }

    private func installCaptureProfile() {
        if let url = model.captureProfileInstallURL() { openURL(url) }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private var localDeviceTitle: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
    }

    private var localDeviceNoun: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func stopCapture() {
        startGateReadiness = nil
        vpn.disable()
        model.endCaptureSession()
        model.stopCaptureMonitor()
    }

    /// The single combined status (tunnel phase + Mac/engine health) for the banner.
    private var liveStatus: CaptureLiveStatus {
        CaptureHealthCheck.liveStatus(
            vpn: vpn.phase,
            targetIsRemote: model.captureTarget.remoteHostPort != nil,
            health: model.captureHealth,
            engineLive: model.captureEngineLive)
    }

    // MARK: - Banner

    @ViewBuilder
    private var captureBanner: some View {
        if vpn.isActive, let info = bannerInfo {
            bannerRow(info.text, system: info.system, color: info.color)
                .padding(8).frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .background(Theme.color.surface.opacity(0.85))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.color.hairline).frame(height: 1) }
        }
    }

    /// Banner copy for the current live status, or nil when no banner is needed
    /// (healthy on-device capture — the control bar already shows REC/Listening).
    private var bannerInfo: (text: String, system: String, color: Color)? {
        let label = model.captureTarget.label
        switch liveStatus {
        case .capturingLocal, .stopped:
            return nil
        case .capturingRemote:
            return ("Routing to \(label) — flows are recorded on that Mac.",
                    "checkmark.circle.fill", Theme.color.green)
        case .starting:
            return ("Starting capture to \(label)…",
                    "arrow.triangle.2.circlepath", Theme.color.textMuted)
        case .reconnecting:
            return ("Network changed — reconnecting the capture tunnel…",
                    "arrow.triangle.2.circlepath", Theme.color.textMuted)
        case .macUnreachable:
            return ("Can't reach \(label). Check the Mac is running & Started, on the same Wi-Fi, and not firewalled. You can also set this device's Wi-Fi proxy manually.",
                    "exclamationmark.triangle.fill", Theme.color.red)
        case .macUntrusted:
            return ("HTTPS isn't validating. Make sure this \(localDeviceNoun) has the HTTrail certificate installed and trusted (Settings ▸ General ▸ VPN & Device Management, and Certificate Trust Settings).",
                    "lock.trianglebadge.exclamationmark", Theme.color.red)
        case .extensionStalled:
            return ("Capture engine isn't responding. Tap Stop, then Start again.",
                    "exclamationmark.triangle.fill", Theme.color.red)
        }
    }

    private func bannerRow(_ text: String, system: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(Theme.color.textDim)
            Spacer()
        }.padding(.horizontal, 8)
    }

    // MARK: - Sessions list

    private var sessionsList: some View {
        Group {
            if model.sessions.isEmpty {
                Spacer()
                ContentUnavailableView("No sessions yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Press Start to record a capture session."))
                Spacer()
            } else {
                List {
                    ForEach(model.sessions) { session in
                        NavigationLink(value: session) { SessionRow(session: session) }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { model.deleteSession(session.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { renameText = session.name; renaming = session } label: {
                                    Label("Rename", systemImage: "pencil")
                                }.tint(Theme.color.accent)
                                Button { harURL = model.exportHAR(sessionID: session.id) } label: {
                                    Label("HAR", systemImage: "square.and.arrow.up")
                                }.tint(.gray)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func sessionFlows(_ session: CaptureSession) -> some View {
        VStack(spacing: 0) {
            ResourceFilterBar(selection: $model.resourceTypeFilter).padding(.vertical, 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                TextField("Filter host, path or method", text: $model.filterText)
                    .textFieldStyle(.plain).autocorrectionDisabled()
                    .font(Theme.mono(13)).foregroundStyle(Theme.color.textBright)
            }
            .padding(.horizontal, 11).padding(.vertical, 8).htField()
            .padding(.horizontal).padding(.bottom, 8)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    Group {
                        if editMode == .active {
                            FlowRow(flow: flow).tag(flow.id)
                        } else {
                            NavigationLink { FlowInspector(flow: flow) } label: { FlowRow(flow: flow) }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.color.hairline)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
        .background(Theme.appBackground)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.viewSession(session.id) }
        .onDisappear { editMode = .inactive }
        .toolbar {
            if editMode == .active {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allFlowsSelected ? "Deselect All" : "Select All") {
                        if allFlowsSelected { model.selectedFlowIDs = [] }
                        else { model.selectAllVisibleFlows() }
                    }
                    .disabled(model.filteredFlows.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.selectedFlowIDs.isEmpty {
                        Button { harURL = model.exportHAR(flowIDs: model.selectedFlowIDs) } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Export selected as HAR")
                        Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                            Image(systemName: "trash")
                        }
                    }
                    Button("Done") { editMode = .inactive; model.selectedFlowIDs = [] }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { editMode = .active; model.selectedFlowIDs = [] }
                }
            }
        }
    }

    /// True when every visible (filtered) flow is in the current selection.
    private var allFlowsSelected: Bool {
        !model.filteredFlows.isEmpty
            && model.selectedFlowIDs.count == model.filteredFlows.count
    }
}

struct FlowRow: View {
    let flow: Flow
    var body: some View {
        HStack(spacing: 11) {
            // Secure flows get a green dot, plaintext a faint one (design uses a
            // 9px coloured dot rather than a lock glyph here).
            Circle()
                .fill(flow.secure ? Color(hex: "#34D399") : Theme.color.textFaint)
                .frame(width: 9, height: 9)
            Text(flow.isWebSocket ? "WS" : flow.request.method.uppercased())
                .font(Theme.mono(10, .bold))
                .foregroundStyle(flow.isWebSocket ? Theme.color.cyan : Theme.methodColor(flow.request.method))
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.request.host).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright).lineLimit(1).truncationMode(.tail)
                Text(flow.request.path).font(Theme.mono(11))
                    .foregroundStyle(Theme.color.textMuted).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                StatusIndicator(state: statusState)
                if flow.isWebSocket {
                    Text("\(flow.webSocketMessages?.count ?? 0) msg")
                        .font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
                } else if let ms = flow.durationMS {
                    Text("\(ms) ms").font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var statusState: StatusIndicator.State {
        switch flow.state {
        case .pending: return .pending
        case .failed: return .error
        case .completed: return flow.statusCode.map { .code($0) } ?? .none
        }
    }
}

/// Detail inspector for a selected flow: request & response, header/body/preview.
struct FlowInspector: View {
    @EnvironmentObject var model: AppModel
    let flow: Flow
    @State private var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case request = "Request", response = "Response", messages = "Messages"
        var id: String { rawValue }
    }

    init(flow: Flow) {
        self.flow = flow
        _tab = State(initialValue: flow.isWebSocket ? .messages : .response)
    }

    /// Re-read the live flow from the model by id so a streaming WebSocket's
    /// frames keep updating while this inspector is open.
    private var current: Flow { model.displayedFlows.first { $0.id == flow.id } ?? flow }
    private var tabs: [Tab] { current.isWebSocket ? [.request, .messages] : [.request, .response] }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(8)
            switch tab {
            case .request:
                MessageView(headers: current.request.headers, bodyData: current.request.body,
                            contentType: current.request.header("Content-Type"),
                            baseURL: URL(string: current.request.url))
            case .response:
                if let response = current.response {
                    MessageView(headers: response.headers, bodyData: response.body,
                                contentType: response.contentType, baseURL: URL(string: current.request.url))
                } else {
                    ContentUnavailableView("No response", systemImage: "tray",
                                           description: Text(current.error ?? "Request still in flight"))
                }
            case .messages:
                WebSocketMessagesView(messages: current.webSocketMessages ?? [])
            }
        }
        .background(Theme.appBackground)
        .navigationTitle(flow.request.host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit & Resend (Compose)") { model.composeFromFlow(flow) }
                    Button("Copy as cURL") {
                        let req = APIRequest(method: flow.request.method, url: flow.request.url,
                                             headers: flow.request.headers.map { KeyValueItem(name: $0.name, value: $0.value) })
                        UIPasteboard.general.string = CurlConverter().exportCommand(req)
                    }
                } label: { Image(systemName: "square.and.pencil") }
            }
        }
    }
}

/// Tabbed headers/body/preview viewer shared by request & response.
struct MessageView: View {
    let headers: [HeaderPair]
    let bodyData: Data
    let contentType: String?
    var baseURL: URL?
    @State private var section: Section = .body

    enum Section: String, CaseIterable, Identifiable {
        case headers = "Headers", body = "Body", preview = "Preview"
        var id: String { rawValue }
    }
    private var isHTML: Bool { (contentType ?? "").lowercased().contains("html") }
    private var isImage: Bool { ImageSniffer.isImage(data: bodyData, contentType: contentType) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 8).padding(.bottom, 6)
            switch section {
            case .headers:
                HeaderTable(headers: headers)
            case .body:
                BodyViewer(data: bodyData, contentType: contentType)
            case .preview:
                Group {
                    if isHTML, let html = String(data: bodyData, encoding: .utf8) {
                        WebPreview(html: html, baseURL: baseURL)
                    } else if isImage {
                        ImagePreview(data: bodyData, contentType: contentType)
                    } else {
                        ContentUnavailableView("No preview", systemImage: "eye.slash",
                            description: Text("Preview supports HTML and images. Content-Type: \(contentType ?? "unknown")"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.appBackground)
    }
}

/// UIKit share sheet wrapper for exporting files (HAR, CA, profile).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Explains Local Network usage before HTTrail browses for Macs via Bonjour.
struct LocalNetworkInfoSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Network Access", systemImage: "wifi").font(.headline)
            Text("To capture to a Mac, HTTrail discovers Macs running HTTrail on your local network using Bonjour, then routes this device's traffic to the one you pick. iOS will ask for permission to find devices on your local network.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Captured traffic goes only to the Mac you choose. HTTrail does not sell, use, or disclose captured data to third parties.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") { dismiss(); onContinue() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }
}

/// Manual proxy host/port entry sheet.
struct ManualProxySheet: View {
    @Binding var host: String
    @Binding var port: Int
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac proxy") {
                    TextField("Host (e.g. 192.168.1.50)", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Manual Proxy")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") {
                        if let p = Int(portText) { port = p }
                        dismiss(); onUse()
                    }.disabled(host.isEmpty)
                }
            }
            .onAppear { portText = String(port) }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
