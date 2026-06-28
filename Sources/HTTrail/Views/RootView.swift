import SwiftUI
import UniformTypeIdentifiers
import HTTrailCore

/// The v2 application shell: a custom translucent titlebar, a vertical activity
/// rail (Capture · Compose · Rules · Realtime, with Setup pinned at the bottom),
/// a resizable mode sidebar, the detail pane, a live status bar, and the ⌘K
/// command palette. The window's system titlebar is hidden (see `HTTrailApp`),
/// so the real traffic-light controls float over our custom bar.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showBonjourInfo = false
    @State private var setupSection: SetupSection = .certificate
    @AppStorage("v2SidebarWidth") private var sidebarWidth: Double = 308

    var body: some View {
        ZStack(alignment: .top) {
            Theme.appBackgroundV2
            VStack(spacing: 0) {
                TitleBar(showSettings: $showSettings, showBonjourInfo: $showBonjourInfo)
                Rectangle().fill(Theme.color.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    ActivityRail()
                    Rectangle().fill(Theme.color.hairline).frame(width: 1)
                    sidebar
                        .frame(width: sidebarWidth)
                        .background(Theme.color.base.opacity(0.55))
                    SidebarHandle(width: $sidebarWidth)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                statusBar
            }
            if model.showCommandPalette {
                CommandPaletteView(setupSection: $setupSection)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.showCommandPalette)
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
        case .setup: SetupSidebar(section: $setupSection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mode {
        case .capture:
            if let flow = model.selectedFlow {
                FlowInspector(flow: flow)
            } else {
                EmptyDetail(title: "Select a flow",
                            systemImage: "dot.radiowaves.left.and.right",
                            message: "Start the proxy and route traffic through 127.0.0.1:\(model.proxyPort)")
            }
        case .compose: RequestEditorView()
        case .rules: RuleEditorView()
        case .realtime: RealtimeView()
        case .setup: SetupDetailView(section: $setupSection,
                                     showSettings: $showSettings,
                                     showBonjourInfo: $showBonjourInfo)
        }
    }

    private var statusDot: some View {
        Text("·").font(.system(size: 11)).foregroundStyle(Color(hex: "#3A3C5E"))
    }

    private var statusBar: some View {
        let activeRules = model.rules.filter(\.enabled).count
        return HStack(spacing: 14) {
            HStack(spacing: 7) {
                ConnectionDot(status: model.isProxyRunning ? .live : .off)
                Text(model.statusMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isProxyRunning ? Theme.color.textSoft : Theme.color.textDim)
                    .lineLimit(1)
            }
            statusDot
            Text("\(model.displayedFlows.count) flows").font(Theme.mono(11)).foregroundStyle(Theme.color.textDim)
            statusDot
            Text("\(activeRules) rules active").font(Theme.mono(11)).foregroundStyle(Theme.color.textDim)
            statusDot
            Text("127.0.0.1:\(model.proxyPort)").font(Theme.mono(11)).foregroundStyle(Theme.color.textMuted)
            Spacer(minLength: 8)
            if model.bonjourEnabled {
                switch model.bonjourPublishState {
                case .published, .none:
                    Label(model.pairedDeviceCount > 0 ? "Bonjour · \(model.pairedDeviceCount) device\(model.pairedDeviceCount == 1 ? "" : "s")" : "Bonjour on",
                          systemImage: "wifi")
                        .font(Theme.mono(11)).foregroundStyle(Theme.color.textMuted)
                case .publishing:
                    Label("Bonjour…", systemImage: "wifi")
                        .font(Theme.mono(11)).foregroundStyle(Theme.color.textMuted)
                case .failed:
                    Label("Bonjour failed", systemImage: "wifi.exclamationmark")
                        .font(Theme.mono(11)).foregroundStyle(Theme.color.red)
                }
            } else {
                Text("Bonjour off").font(Theme.mono(11)).foregroundStyle(Theme.color.textFaint)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Theme.color.app.opacity(0.6))
        .overlay(Theme.color.hairline.frame(height: 1), alignment: .top)
    }
}

// MARK: - Title bar

/// The custom 48px window-chrome row. Leading space is reserved for the macOS
/// traffic-light controls (the window's system titlebar is hidden).
private struct TitleBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Binding var showBonjourInfo: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Reserve room for the real traffic-light buttons.
            Color.clear.frame(width: 68, height: 1)
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.primary)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(.white)
                    )
                Text("HTTrail")
                    .font(.system(size: 13.5, weight: .bold))
                    .tracking(-0.135)
                    .foregroundStyle(Theme.color.text)
            }
            .padding(.leading, 6)
            Rectangle().fill(Theme.color.border).frame(width: 1, height: 22)

            if model.mode == .compose { EnvironmentPicker() }

            Spacer()

            startStopControl
            systemProxyToggle
            setupMenu

            Rectangle().fill(Theme.color.border).frame(width: 1, height: 22)
            Button { model.showCommandPalette = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13))
                    Text("⌘K").font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
                }
                .foregroundStyle(Theme.color.textDim)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .htField(8)
            }
            .buttonStyle(.plain)
            .help("Command palette (⌘K)")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Theme.titlebar)
    }

    @ViewBuilder
    private var startStopControl: some View {
        if model.isProxyRunning {
            Button { model.toggleProxy() } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.color.red).frame(width: 9, height: 9)
                    Text("Stop")
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color(hex: "#FCA5A5"))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.color.red.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
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
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Theme.color.green)
                    Text("Start")
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color(hex: "#6EE7B7"))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Theme.color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.color.green.opacity(0.42), lineWidth: 1))
            } primaryAction: {
                model.startProxy()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var systemProxyToggle: some View {
        Button { model.toggleSystemProxy() } label: {
            HStack(spacing: 9) {
                Text("System Proxy")
                MiniSwitch(on: model.systemProxyEnabled)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.systemProxyEnabled ? Theme.color.text : Theme.color.textDim)
            .padding(.leading, 12).padding(.trailing, 11).padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.systemProxyEnabled ? Theme.color.accent.opacity(0.4) : Theme.color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Route this Mac's traffic through HTTrail")
    }

    private var setupMenu: some View {
        Menu {
            Button("Open Setup") { model.mode = .setup }
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
            Button("Import OpenAPI / Postman…") { importCollectionFile(model) }
            Button("Import from Postman App") { model.importLatestPostmanBackup() }
            Button("Export Captured Flows as HAR…") { model.exportHAR() }
            Divider()
            Button("Clear Flows", role: .destructive) { model.clearFlows() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.color.textDim)
                Text("Setup")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.color.textSoft)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.color.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A small iOS-style toggle switch used in the toolbar.
struct MiniSwitch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.color.raised))
            .frame(width: 34, height: 19)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.16), value: on)
    }
}

// MARK: - Activity rail

private struct ActivityRail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 3) {
            ForEach(AppModel.Mode.primary) { railButton($0) }
            Spacer()
            railButton(.setup)
        }
        .padding(.vertical, 10)
        .frame(width: 60)
        .background(Theme.color.app.opacity(0.5))
    }

    private func railButton(_ m: AppModel.Mode) -> some View {
        let active = model.mode == m
        return Button { model.mode = m } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.color.accent)
                    .frame(width: 3, height: 22)
                    .opacity(active ? 1 : 0)
                    .offset(x: -8)
                VStack(spacing: 3) {
                    Image(systemName: m.systemImage).font(.system(size: 18, weight: .regular))
                    Text(m.rawValue).font(.system(size: 8.5, weight: .bold)).tracking(0.17)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(active ? Theme.color.accent : Theme.color.textMuted)
            }
            .frame(width: 46, height: 50)
            .background(active ? AnyShapeStyle(Theme.color.accent.opacity(0.12)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: Theme.radius.lg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.rawValue)
    }
}

// MARK: - Draggable sidebar handle

private struct SidebarHandle: View {
    @Binding var width: Double
    @State private var hovering = false
    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.color.accent.opacity(0.5) : Theme.color.hairline)
            .frame(width: hovering ? 2 : 1)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering = $0; if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in width = min(460, max(248, width + v.translation.width)) })
    }
}

// MARK: - Empty detail

struct EmptyDetail: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.color.textFaint)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.color.textDim)
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Command palette

private struct CommandCmd: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let run: () -> Void
}

private struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @Binding var setupSection: SetupSection
    @State private var query = ""
    @FocusState private var focused: Bool

    private var commands: [CommandCmd] {
        var c: [CommandCmd] = [
            .init(title: "Go to Capture", subtitle: "Mode", systemImage: "dot.radiowaves.left.and.right") { model.mode = .capture },
            .init(title: "Go to Compose", subtitle: "Mode", systemImage: "paperplane") { model.mode = .compose },
            .init(title: "Go to Rules", subtitle: "Mode", systemImage: "slider.horizontal.3") { model.mode = .rules },
            .init(title: "Go to Realtime", subtitle: "Mode", systemImage: "bolt.horizontal") { model.mode = .realtime },
            .init(title: "Go to Setup", subtitle: "Mode", systemImage: "gearshape") { model.mode = .setup },
            .init(title: model.isProxyRunning ? "Stop Proxy" : "Start Proxy",
                  subtitle: "Proxy", systemImage: model.isProxyRunning ? "stop.circle" : "play.circle") { model.toggleProxy() },
            .init(title: "Toggle System Proxy", subtitle: "Proxy", systemImage: "network") { model.toggleSystemProxy() },
            .init(title: "New Request", subtitle: "Compose", systemImage: "plus") { model.mode = .compose; model.newRequest() },
            .init(title: "Import cURL…", subtitle: "Import", systemImage: "curlybraces") { model.showImportSheet = true },
            .init(title: "Export Flows as HAR…", subtitle: "Export", systemImage: "square.and.arrow.down") { model.exportHAR() },
            .init(title: model.caTrusted ? "Re-install Root CA…" : "Install & Trust Root CA…",
                  subtitle: "Certificate", systemImage: "checkmark.seal") { model.installCACertificate() },
            .init(title: "Export iOS Profile…", subtitle: "Certificate", systemImage: "iphone") { model.exportiOSProfile() },
            .init(title: "Clear Captured Flows", subtitle: "Danger", systemImage: "trash") { model.clearFlows() },
        ]
        // Saved requests jump straight into Compose.
        for r in model.requests.prefix(8) where !r.url.isEmpty {
            c.append(.init(title: r.name.isEmpty ? r.url : r.name,
                           subtitle: "Request · \(r.method)", systemImage: "paperplane.fill") {
                model.loadRequest(r); model.mode = .compose
            })
        }
        return c
    }

    private var results: [CommandCmd] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.showCommandPalette = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.color.textMuted)
                    TextField("Type a command or request…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.color.text)
                        .focused($focused)
                        .onSubmit { results.first?.run(); model.showCommandPalette = false }
                    Text("esc").font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Rectangle().fill(Theme.color.hairline).frame(height: 1)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(results) { cmd in
                            Button { cmd.run(); model.showCommandPalette = false } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: cmd.systemImage).font(.system(size: 13))
                                        .foregroundStyle(Theme.color.accent).frame(width: 18)
                                    Text(cmd.title).font(.system(size: 13)).foregroundStyle(Theme.color.text)
                                    Spacer()
                                    Text(cmd.subtitle).font(Theme.mono(10)).foregroundStyle(Theme.color.textFaint)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PaletteRowStyle())
                        }
                        if results.isEmpty {
                            Text("No matches").font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(Color(hex: "#12152E"), in: RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .padding(.top, 96)
        }
        .onAppear { focused = true }
        .onExitCommand { model.showCommandPalette = false }
    }
}

private struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.color.accent.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radius.sm))
    }
}

@MainActor
private func importCollectionFile(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "Select an OpenAPI 3, Postman Collection, or Postman backup JSON file"
    if panel.runModal() == .OK, let url = panel.url {
        model.importCollection(from: url)
    }
}

// MARK: - Setup (native macOS screen)

enum SetupSection: String, CaseIterable, Identifiable {
    case certificate = "Certificate Authority"
    case proxy = "Proxy"
    case connectivity = "Connectivity"
    case importExport = "Import / Export"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .certificate: return "checkmark.seal"
        case .proxy: return "network"
        case .connectivity: return "wifi"
        case .importExport: return "square.and.arrow.up.on.square"
        }
    }
}

struct SetupSidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var section: SetupSection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Setup").font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SetupSection.allCases) { s in
                        Button { section = s } label: {
                            HStack(spacing: 10) {
                                Image(systemName: s.systemImage).font(.system(size: 13)).frame(width: 18)
                                Text(s.rawValue).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(section == s ? Theme.color.text : Theme.color.textDim)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .background(section == s ? Theme.color.fill : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

struct SetupDetailView: View {
    @EnvironmentObject var model: AppModel
    @Binding var section: SetupSection
    @Binding var showSettings: Bool
    @Binding var showBonjourInfo: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
                case .certificate: certificateCard
                case .proxy: proxyCard
                case .connectivity: connectivityCard
                case .importExport: importExportCard
                }
            }
            .padding(22)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task { await model.checkCATrust() }
    }

    private var certificateCard: some View {
        SetupCard(title: "Certificate Authority",
                  subtitle: "HTTrail decrypts HTTPS only after its root CA is installed and fully trusted.") {
            let tint = model.caTrusted ? Theme.color.green : Theme.color.amber
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 46, height: 46)
                    if model.caCheckInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.caTrusted ? "checkmark.shield.fill" : "exclamationmark.shield")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(model.caTrusted ? Color(hex: "#34D399") : Theme.color.amber)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.caTrusted ? "Root CA installed & trusted" : "Root CA not trusted")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.color.textBright)
                    Text(model.caTrusted
                         ? "HTTrail CA · SHA-256. System keychain trust enabled."
                         : "Install & trust the CA to decrypt HTTPS traffic.")
                        .font(.system(size: 12)).foregroundStyle(Theme.color.textDim)
                }
                Spacer(minLength: 8)
                SetupButton("Re-check", icon: "arrow.clockwise") { Task { await model.checkCATrust() } }
            }
            .padding(16)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1))
            Divider().overlay(Theme.color.hairline)
            HStack(spacing: 10) {
                if model.caTrusted {
                    SetupButton("Re-install Root CA…", icon: "arrow.down.doc") { model.installCACertificate() }
                    SetupButton("Remove Trust…", icon: "trash", tint: Theme.color.red) { model.uninstallCACertificate() }
                } else {
                    SetupButton("Install & Trust Root CA…", icon: "checkmark.seal", primary: true) { model.installCACertificate() }
                }
                SetupButton("Reveal…", icon: "folder") { model.revealCACertificate() }
            }
            SetupButton("Export iOS Profile…", icon: "iphone") { model.exportiOSProfile() }
        }
    }

    private var proxyCard: some View {
        SetupCard(title: "Proxy",
                  subtitle: "HTTrail listens on this port. Stop the proxy to change it.") {
            HStack {
                Text("Listen port").font(.system(size: 13))
                Spacer()
                Text("127.0.0.1:\(model.proxyPort)").font(Theme.mono(13)).foregroundStyle(Theme.color.codeKey)
            }
            HStack {
                Text("System proxy").font(.system(size: 13))
                Spacer()
                Button { model.toggleSystemProxy() } label: { MiniSwitch(on: model.systemProxyEnabled) }
                    .buttonStyle(.plain)
            }
            Divider().overlay(Theme.color.hairline)
            SetupButton("Proxy Settings…", icon: "slider.horizontal.3") { showSettings = true }
        }
    }

    private var connectivityCard: some View {
        SetupCard(title: "Connectivity",
                  subtitle: "Advertise this Mac over Bonjour so an iPhone running HTTrail can route here.") {
            HStack {
                Text("Discoverable over Bonjour").font(.system(size: 13))
                Spacer()
                Button {
                    if !model.bonjourEnabled { showBonjourInfo = true } else { model.setBonjourEnabled(false) }
                } label: { MiniSwitch(on: model.bonjourEnabled) }
                    .buttonStyle(.plain)
            }
            if model.bonjourEnabled, model.pairedDeviceCount > 0 {
                Text("\(model.pairedDeviceCount) device\(model.pairedDeviceCount == 1 ? "" : "s") paired")
                    .font(.system(size: 12)).foregroundStyle(Theme.color.textDim)
            }
        }
    }

    private var importExportCard: some View {
        SetupCard(title: "Import / Export",
                  subtitle: "Bring requests in, or take captured traffic out.") {
            HStack(spacing: 10) {
                SetupButton("Import cURL…", icon: "curlybraces") { model.showImportSheet = true }
                SetupButton("Import OpenAPI / Postman…", icon: "tray.and.arrow.down") { importCollectionFile(model) }
            }
            SetupButton("Import from Postman App", icon: "externaldrive.badge.plus") { model.importLatestPostmanBackup() }
            SetupButton("Export Captured Flows as HAR…", icon: "square.and.arrow.down") { model.exportHAR() }
            Divider().overlay(Theme.color.hairline)
            SetupButton("Clear Captured Flows", icon: "trash", tint: Theme.color.red) { model.clearFlows() }
        }
    }
}

struct SetupCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(Theme.color.textFaint)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.color.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .htCard()
    }
}

struct SetupButton: View {
    let title: String
    let icon: String
    var primary = false
    var tint: Color? = nil
    let action: () -> Void
    init(_ title: String, icon: String, primary: Bool = false, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.primary = primary; self.tint = tint; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .buttonStyle(primary ? AnyButtonStyle(.htPrimary) : AnyButtonStyle(.htGhost))
        .tint(tint ?? Theme.color.accent)
    }
}

/// Tiny type-eraser so `SetupButton` can pick between button styles at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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

// MARK: - Compose sidebar

/// A sidebar section eyebrow: 9.5px monospaced, tracked, faint — matches the
/// design's `OPEN REQUESTS / COLLECTIONS / HISTORY` labels.
private struct SidebarEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(1.33)
            .foregroundStyle(Theme.color.textFaint)
    }
}

/// Shared hover/selection background for sidebar rows.
private struct SidebarRowBG: ViewModifier {
    var selected: Bool = false
    var radius: CGFloat = 8
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(
                selected ? AnyShapeStyle(Theme.color.accent.opacity(0.12))
                : (hover ? AnyShapeStyle(Color.white.opacity(0.05)) : AnyShapeStyle(Color.clear)),
                in: RoundedRectangle(cornerRadius: radius))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
private extension View {
    func sidebarRow(selected: Bool = false, radius: CGFloat = 8) -> some View {
        modifier(SidebarRowBG(selected: selected, radius: radius))
    }
}

/// Sidebar for compose mode: collections + history + saved requests.
struct ComposeSidebar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("composeOpenExpanded") private var openExpanded = true
    @AppStorage("composeCollectionsExpanded") private var collectionsExpanded = true
    @AppStorage("composeHistoryExpanded") private var historyExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Compose").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.color.text)
                Spacer()
                Button { model.newRequest() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.color.textDim)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("New request")
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // OPEN REQUESTS
                    sectionHeader("OPEN REQUESTS", expanded: $openExpanded)
                    if openExpanded {
                        ForEach(model.requests) { request in
                            let selected = model.selectedRequestID == request.id
                            Button { model.selectedRequestID = request.id } label: {
                                HStack(spacing: 9) {
                                    Text(request.method.uppercased())
                                        .font(Theme.mono(9.5, .bold))
                                        .foregroundStyle(Theme.methodColor(request.method))
                                        .frame(width: 42, alignment: .leading)
                                    Text(AppModel.composeRequestTitle(for: request))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(selected ? Theme.color.textBright : Theme.color.textSoft)
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .sidebarRow(selected: selected, radius: 8)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 2)
                        }
                    }

                    // COLLECTIONS
                    if !model.collections.isEmpty {
                        sectionHeader("COLLECTIONS", expanded: $collectionsExpanded)
                        if collectionsExpanded {
                            ForEach(model.collections) { collection in
                                CollectionOutline(collection: collection)
                                    .padding(.bottom, 3)
                            }
                        }
                    }

                    // HISTORY
                    if !model.history.isEmpty {
                        sectionHeader("HISTORY", expanded: $historyExpanded) {
                            Button { model.clearHistory() } label: {
                                Text("Clear")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Theme.color.textFaint)
                            }
                            .buttonStyle(.plain)
                            .help("Clear history")
                        }
                        if historyExpanded {
                            ForEach(model.history.prefix(20)) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
        }
    }

    /// Collapsible section header: a chevron + eyebrow that toggles `expanded`,
    /// with an optional trailing control (kept as a sibling button so taps don't
    /// conflict with the header button).
    @ViewBuilder
    private func sectionHeader<Trailing: View>(_ title: String, expanded: Binding<Bool>,
                                               @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.color.textFaint)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    SidebarEyebrow(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
    }

    /// One history row: the main area opens the request (with its old response);
    /// the trailing ↻ resends it immediately. Mirrors the iOS History screen.
    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 6) {
            Button { model.loadHistory(entry) } label: {
                HStack(spacing: 9) {
                    Text(entry.request.method.uppercased())
                        .font(Theme.mono(9, .bold))
                        .foregroundStyle(Theme.methodColor(entry.request.method))
                        .frame(width: 38, alignment: .leading)
                    Text(AppModel.composeHistoryTitle(for: entry))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.color.textDim)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("\(entry.statusCode)")
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(UIFormat.statusColor(entry.statusCode))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .sidebarRow(radius: 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open request + response")

            Button {
                model.loadHistory(entry)
                model.sendSelectedRequest()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.color.accent)
                    .frame(width: 24, height: 24)
                    .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Send again")
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
                Button { model.loadRequest(request) } label: {
                    HStack(spacing: 9) {
                        Text(request.method.uppercased())
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(Theme.methodColor(request.method))
                            .frame(width: 38, alignment: .leading)
                        Text(AppModel.composeRequestTitle(for: request))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.color.textSoft)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 13).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.color.blue)
                Text(collection.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textSoft)
            }
        }
        .tint(Theme.color.textFaint)
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
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.color.accent)
                Text(model.environments.first { $0.id == model.activeEnvironmentID }?.name ?? "No Environment")
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Theme.color.textFaint)
            }
            .foregroundStyle(Theme.color.text)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.color.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.color.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
