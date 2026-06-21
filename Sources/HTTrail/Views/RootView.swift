import SwiftUI
import UniformTypeIdentifiers
import HTTrailCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showBonjourInfo = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ModeRail(mode: $model.mode)
                Divider().overlay(Theme.color.hairline)
                sidebar
            }
            .background(Theme.color.base.opacity(0.6))
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 480)
        } detail: {
            detail
                .background(Theme.appBackground)
        }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $model.showImportSheet) { ImportCurlSheet() }
        .sheet(isPresented: $showSettings) { ProxySettingsSheet() }
        .sheet(item: $model.pendingBreakpoint) { _ in BreakpointSheet() }
        .sheet(isPresented: $showBonjourInfo) {
            BonjourInfoSheet(onEnable: { model.setBonjourEnabled(true) })
        }
        .preferredColorScheme(.dark)
        .tint(Theme.color.accent)
    }

    @ViewBuilder
    private var sidebar: some View {
        switch model.mode {
        case .capture: FlowListView()
        case .compose: ComposeSidebar()
        case .rules: RulesListView()
        case .realtime: RealtimeSidebar()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mode {
        case .capture:
            if let flow = model.selectedFlow {
                FlowInspector(flow: flow)
            } else {
                ContentUnavailableView("Select a flow",
                                       systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Start the proxy and route traffic through 127.0.0.1:\(model.proxyPort)"))
            }
        case .compose: RequestEditorView()
        case .rules: RuleEditorView()
        case .realtime: RealtimeView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode == .compose {
                EnvironmentPicker()
            }
            if model.isProxyRunning {
                Button { model.toggleProxy() } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }.tint(.red)
            } else {
                Menu {
                    Button("New Session") { model.startProxy() }
                    if !model.sessions.isEmpty {
                        Divider()
                        ForEach(model.sessions.prefix(10)) { session in
                            Button("Resume \(session.name) · \(session.recordCount)") {
                                model.startProxy(resuming: session.id)
                            }
                        }
                    }
                } label: {
                    Label("Start", systemImage: "play.circle.fill")
                } primaryAction: {
                    model.startProxy()
                }
                .tint(.green)
            }

            Toggle(isOn: Binding(get: { model.systemProxyEnabled },
                                 set: { _ in model.toggleSystemProxy() })) {
                Label("System Proxy", systemImage: "network")
            }

            Menu {
                Button("Proxy Settings…") { showSettings = true }
                Divider()
                if model.caTrusted {
                    Label("Root CA trusted", systemImage: "checkmark.seal.fill")
                    Button("Re-install Root CA…") { model.installCACertificate() }
                    Button("Remove Root CA Trust…", role: .destructive) { model.uninstallCACertificate() }
                } else {
                    Button("Install & Trust Root CA…") { model.installCACertificate() }
                }
                Button("Check CA Trust") { Task { await model.checkCATrust() } }
                Button("Reveal Root CA…") { model.revealCACertificate() }
                Button("Export iOS Profile…") { model.exportiOSProfile() }
                Divider()
                Toggle("Discoverable over Bonjour", isOn: Binding(
                    get: { model.bonjourEnabled },
                    set: { newValue in
                        if newValue && !model.bonjourEnabled { showBonjourInfo = true }
                        else { model.setBonjourEnabled(false) }
                    }))
                Divider()
                Button("Import cURL…") { model.showImportSheet = true }
                Button("Import OpenAPI / Postman…") { importCollectionFile() }
                Button("Export Captured Flows as HAR…") { model.exportHAR() }
                Divider()
                Button("Clear Flows", role: .destructive) { model.clearFlows() }
            } label: {
                Label("Setup", systemImage: "shield.lefthalf.filled")
            }
        }
    }

    private func importCollectionFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select an OpenAPI 3 or Postman Collection JSON file"
        if panel.runModal() == .OK, let url = panel.url {
            model.importCollection(from: url)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            ConnectionDot(status: model.isProxyRunning ? .live : .off)
            Text(model.statusMessage)
                .font(.system(size: 11)).foregroundStyle(Theme.color.textDim).lineLimit(1)
            Spacer()
            if model.mode == .capture {
                Text("\(model.displayedFlows.count) flows")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color.textFaint)
            }
            if !model.rules.filter(\.enabled).isEmpty {
                Label("\(model.rules.filter(\.enabled).count)", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11)).foregroundStyle(Theme.color.textFaint)
            }
            Text("127.0.0.1:\(model.proxyPort)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color.textFaint)
            if model.bonjourEnabled {
                switch model.bonjourPublishState {
                case .published, .none:
                    Label(model.pairedDeviceCount > 0 ? "Bonjour · \(model.pairedDeviceCount) device\(model.pairedDeviceCount == 1 ? "" : "s")" : "Bonjour",
                          systemImage: "wifi")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .publishing:
                    Label("Bonjour…", systemImage: "wifi")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .failed:
                    Label("Bonjour failed", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.color.base.opacity(0.85))
        .overlay(Theme.color.hairline.frame(height: 1), alignment: .top)
    }
}

/// Explains Local Network usage before HTTrail advertises over Bonjour.
struct BonjourInfoSheet: View {
    let onEnable: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Network Access", systemImage: "wifi")
                .font(.headline)
            Text("HTTrail will advertise this Mac on your local network so an iPhone running HTTrail can route its traffic here. The iPhone uses its own certificate authority — nothing new is installed on this Mac, and the Mac never trusts the uploaded certificate. Your Mac is only discoverable while the proxy is running. No data leaves your network.")
                .font(.callout).foregroundStyle(.secondary)
            Text("macOS may ask for permission to access devices on your local network.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Enable") { onEnable(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 420)
    }
}

/// macOS proxy settings: listen port + root-CA trust status. Port is locked
/// while the proxy is running (stop to change it).
struct ProxySettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Proxy Settings").font(.headline)

            Form {
                Section {
                    HStack {
                        Text("Listen port")
                        Spacer()
                        TextField("9090", text: $portText)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .disabled(model.isProxyRunning)
                            .onSubmit { commitPort() }
                        Button("Apply") { commitPort() }
                            .disabled(model.isProxyRunning || Int(portText) == model.proxyPort || Int(portText) == nil)
                    }
                    if model.isProxyRunning {
                        Text("Stop the proxy to change the port.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("1024–65535. Restart the proxy after changing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Proxy") }

                Section {
                    HStack(spacing: 8) {
                        if model.caCheckInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: model.caTrusted ? "checkmark.seal.fill" : "xmark.seal")
                                .foregroundStyle(model.caTrusted ? Color.green : Color.orange)
                        }
                        Text(model.caTrusted ? "Root CA installed & trusted" : "Root CA not trusted")
                        Spacer()
                        Button("Re-check") { Task { await model.checkCATrust() } }
                            .disabled(model.caCheckInProgress)
                    }
                    if model.caTrusted {
                        Button("Remove Root CA Trust…", role: .destructive) { model.uninstallCACertificate() }
                    } else {
                        Button("Install & Trust Root CA…") { model.installCACertificate() }
                    }
                } header: { Text("Certificate Authority") }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { portText = "\(model.proxyPort)"; Task { await model.checkCATrust() } }
    }

    private func commitPort() {
        guard let port = Int(portText) else { portText = "\(model.proxyPort)"; return }
        model.setProxyPort(port)
        portText = "\(model.proxyPort)"
    }
}

/// The design's left "activity rail": one accent-barred icon per mode.
struct ModeRail: View {
    @Binding var mode: AppModel.Mode
    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Mode.allCases) { m in
                Button { mode = m } label: {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.color.accent)
                            .frame(width: 3, height: 20)
                            .opacity(mode == m ? 1 : 0)
                        VStack(spacing: 4) {
                            Image(systemName: m.systemImage)
                                .font(.system(size: 16, weight: .regular))
                            Text(m.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(mode == m ? Theme.color.accent : Theme.color.textMuted)
                    }
                    .padding(.vertical, 9)
                    .background(mode == m ? Theme.color.fill : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.radius.md))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }
}

/// Sidebar for compose mode: collections + history + saved requests.
struct ComposeSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(selection: $model.selectedRequestID) {
            Section("Open Requests") {
                ForEach(model.requests) { request in
                    HStack(spacing: 8) {
                        MethodBadge(method: request.method)
                        Text(request.name.isEmpty ? request.url : request.name).lineLimit(1)
                    }.tag(request.id)
                }
            }
            if !model.collections.isEmpty {
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        CollectionOutline(collection: collection)
                    }
                }
            }
            if !model.history.isEmpty {
                Section("History") {
                    ForEach(model.history.prefix(20)) { entry in
                        Button {
                            model.loadRequest(entry.request)
                        } label: {
                            HStack(spacing: 8) {
                                MethodBadge(method: entry.request.method)
                                Text(entry.request.url).lineLimit(1).font(.caption)
                                Spacer()
                                Text("\(entry.statusCode)").font(.caption2)
                                    .foregroundStyle(UIFormat.statusColor(entry.statusCode))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) {
            HStack {
                Button { model.newRequest() } label: { Label("New", systemImage: "plus") }
                Spacer()
                Button { model.clearHistory() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Clear history")
            }
            .padding(8)
            .background(Theme.color.base.opacity(0.7))
        }
    }
}

/// Recursive collection → folder → request tree (nested collections).
struct CollectionOutline: View {
    @EnvironmentObject var model: AppModel
    let collection: RequestCollection
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(collection.folders) { folder in
                CollectionOutline(collection: folder)
            }
            ForEach(collection.requests) { request in
                Button {
                    model.loadRequest(request)
                } label: {
                    HStack(spacing: 8) {
                        MethodBadge(method: request.method)
                        Text(request.name).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        } label: {
            Label(collection.name, systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
        }
    }
}

struct EnvironmentPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            Button("No Environment") { model.activeEnvironmentID = nil; model.persistEnvironments() }
            Divider()
            ForEach(model.environments) { env in
                Button(env.name) { model.activeEnvironmentID = env.id; model.persistEnvironments() }
            }
            Divider()
            Button("Add Environment…") { model.addEnvironment() }
        } label: {
            Label(model.environments.first { $0.id == model.activeEnvironmentID }?.name ?? "Env",
                  systemImage: "list.bullet.rectangle")
        }
    }
}
