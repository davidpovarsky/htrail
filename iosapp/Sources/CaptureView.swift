import SwiftUI
import UIKit
import HTTrailCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var vpn: VPNController
    @State private var harURL: URL?
    @State private var editMode: EditMode = .inactive
    @State private var renaming: CaptureSession?
    @State private var renameText = ""
    @State private var showLocalNetInfo = false
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground
                VStack(spacing: 0) {
                    controlBar
                    discoveredMacsBar
                    Divider().overlay(Theme.color.hairline)
                    sessionsList
                }
            }
            .navigationTitle("Capture")
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
            .onAppear { startBrowsingIfDisclosed() }
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
                    Label("Start (This iPhone)", systemImage: "play.circle.fill").font(.headline)
                }.tint(Theme.color.green)
                Button { showManualEntry = true } label: {
                    Image(systemName: "square.and.pencil").font(.headline)
                }.tint(Theme.color.textDim)
                .accessibilityLabel("Manual proxy")
            }
            Spacer()
            if vpn.isActive {
                HStack(spacing: 6) {
                    ConnectionDot(status: .error)
                    Text("REC").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.color.red)
                }.padding(.trailing, 4)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(model.deviceIP):\(model.proxyPort)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color.textDim)
                Text(vpn.isActive ? "Listening" : "Stopped")
                    .font(.system(size: 10)).foregroundStyle(vpn.isActive ? Theme.color.green : Theme.color.textFaint)
            }
        }
        .padding()
    }

    /// Separate, always-visible list of Macs discovered over Bonjour, each with
    /// its own explicit "capture here" button (no hidden long-press menu). When
    /// none are found yet, a hint points at the usual culprits.
    @ViewBuilder
    private var discoveredMacsBar: some View {
        if !vpn.isActive {
            VStack(alignment: .leading, spacing: 8) {
                if !model.discoveredProxies.isEmpty {
                    Text("MACS ON YOUR NETWORK")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.color.textDim)
                    ForEach(model.discoveredProxies) { proxy in
                        Button { selectTarget(.remote(proxy)) } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Capture on \(proxy.name)").font(.subheadline.weight(.semibold))
                                    Text("\(proxy.host):\(proxy.port)")
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color.textDim)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.color.green)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.color.accent)
                    }
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

    /// Browse only after the user has seen the Local Network disclosure, so the
    /// OS permission prompt never appears before our explanation (App Store).
    private func startBrowsingIfDisclosed() {
        if model.bonjourDisclosureShown { model.startBonjourBrowsing() }
        else { showLocalNetInfo = true }
    }

    private func selectTarget(_ target: CaptureTarget) {
        model.captureTarget = target
        // A remote Mac can only have been discovered after browsing, which only
        // happens post-disclosure — so starting capture here needs no extra gate.
        if case .remote = target { startCapture() }
    }

    private func startCapture() {
        if case .thisDevice = model.captureTarget {
            model.beginCaptureSession()
        }
        Task {
            let endpoint = await model.applyCaptureTargetForStart()
            await vpn.startCapture(port: model.proxyPort)
            // Continuously monitor health (remote Mac probe, or on-device engine
            // heartbeat) so the banner reflects reality for the whole session.
            model.startCaptureMonitor(remote: endpoint)
        }
    }

    private func stopCapture() {
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
                .background(Theme.color.base.opacity(0.9))
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
            return ("HTTPS isn't validating. Make sure this iPhone has the HTTrail certificate installed and trusted (Settings ▸ General ▸ VPN & Device Management, and Certificate Trust Settings).",
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
                    .textFieldStyle(.plain).autocorrectionDisabled().font(.system(size: 13))
            }
            .padding(.horizontal, 11).padding(.vertical, 8).htField()
            .padding(.horizontal).padding(.bottom, 8)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    if editMode == .active {
                        FlowRow(flow: flow).tag(flow.id).listRowBackground(Color.clear)
                    } else {
                        NavigationLink { FlowInspector(flow: flow) } label: { FlowRow(flow: flow) }
                            .listRowBackground(Color.clear)
                    }
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
            ToolbarItem(placement: .topBarTrailing) {
                if editMode == .active && !model.selectedFlowIDs.isEmpty {
                    Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                        Image(systemName: "trash")
                    }
                } else {
                    Button(editMode == .active ? "Done" : "Select") {
                        editMode = editMode == .active ? .inactive : .active
                        model.selectedFlowIDs = []
                    }
                }
            }
        }
    }
}

struct FlowRow: View {
    let flow: Flow
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: flow.secure ? "lock.fill" : "lock.open")
                .font(.system(size: 10)).foregroundStyle(flow.secure ? Theme.color.green : Theme.color.textFaint)
            MethodBadge(method: flow.request.method)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.request.host).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright).lineLimit(1)
                Text(flow.request.path).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.color.textMuted).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                StatusIndicator(state: statusState)
                if let ms = flow.durationMS {
                    Text("\(ms) ms").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.color.textFaint)
                }
            }
        }
        .padding(.vertical, 3)
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
    @State private var tab: Tab = .response

    enum Tab: String, CaseIterable, Identifiable {
        case request = "Request", response = "Response"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(8)
            switch tab {
            case .request:
                MessageView(headers: flow.request.headers, bodyData: flow.request.body,
                            contentType: flow.request.header("Content-Type"),
                            baseURL: URL(string: flow.request.url))
            case .response:
                if let response = flow.response {
                    MessageView(headers: response.headers, bodyData: response.body,
                                contentType: response.contentType, baseURL: URL(string: flow.request.url))
                } else {
                    ContentUnavailableView("No response", systemImage: "tray",
                                           description: Text(flow.error ?? "Request still in flight"))
                }
            }
        }
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
    private var isImage: Bool { (contentType ?? "").lowercased().hasPrefix("image/") }

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
                        ImagePreview(data: bodyData)
                    } else {
                        ContentUnavailableView("No preview", systemImage: "eye.slash",
                            description: Text("Preview supports HTML and images. Content-Type: \(contentType ?? "unknown")"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
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
            Text("Nothing is sent outside your network; traffic goes only to the Mac you choose.")
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
