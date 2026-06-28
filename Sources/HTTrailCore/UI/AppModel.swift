import Foundation
import SwiftUI
import Crypto
import Combine

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Bridges the proxy's `FlowSink` (called from NIO event-loop threads) onto the
/// main actor where SwiftUI can observe it.
final class FlowBridge: FlowSink, @unchecked Sendable {
    var onFlow: (@Sendable (Flow) -> Void)?
    func record(_ flow: Flow) {
        let handler = onFlow
        DispatchQueue.main.async { handler?(flow) }
    }
}

/// The single, shared application model used **identically** by the macOS and
/// iOS apps. Keeping it in `HTTrailCore` guarantees both platforms expose the
/// same feature set; only the platform-native affordances (system proxy, Finder
/// reveal) are conditionally compiled.
@MainActor
public final class AppModel: ObservableObject {
    nonisolated public static let defaultComposeURL = APIRequest.defaultURL
    nonisolated public static let defaultWebSocketURL = "wss://echo.websocket.org"
    nonisolated private static let legacyDefaultWebSocketURLs: Set<String> = [
        "wss://echo.websocket.events"
    ]

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case capture = "Capture"
        case compose = "Compose"
        case rules = "Rules"
        case realtime = "Realtime"
        case setup = "Setup"
        public var id: String { rawValue }
        public var systemImage: String {
            switch self {
            case .capture: return "dot.radiowaves.left.and.right"
            case .compose: return "paperplane"
            case .rules: return "slider.horizontal.3"
            case .realtime: return "bolt.horizontal"
            case .setup: return "gearshape"
            }
        }
        /// The four primary modes shown in the rail's main cluster; `setup` is
        /// pinned separately at the bottom of the rail.
        public static var primary: [Mode] { [.capture, .compose, .rules, .realtime] }
    }

    @Published public var mode: Mode = .capture {
        didSet {
            // iOS uses a TabView bound to `selectedTab`; mirror mode changes onto
            // it so model-driven navigation (Edit & Resend, import, load request)
            // actually switches tabs.
            #if os(iOS)
            switch mode {
            case .capture: selectedTab = 0
            case .compose: selectedTab = 1
            case .rules: selectedTab = 2
            case .realtime: selectedTab = 3
            case .setup: selectedTab = 4
            }
            #endif
        }
    }

    #if os(iOS)
    /// Selected TabView index (0 Capture · 1 Compose · 2 Rules · 3 Realtime · 4 Setup).
    @Published public var selectedTab: Int = 0
    #endif

    // Proxy / capture
    @Published public var flows: [Flow] = []
    @Published public var selectedFlowIDs: Set<Flow.ID> = []
    /// Navigation path for the iOS Capture tab (drilling into a session's flows).
    /// Empty in normal use; the demo seam can push a session for screenshots.
    @Published public var capturePath: [CaptureSession] = []
    @Published public var isProxyRunning = false
    @Published public var proxyPort: Int = 9090
    @Published public var systemProxyEnabled = false
    /// Whether the HTTrail root CA is present/trusted (System keychain on macOS,
    /// loopback TLS probe on iOS).
    @Published public var caTrusted = false
    /// True while a CA-trust check is running (drives a spinner in Setup).
    @Published public var caCheckInProgress = false
    @Published public var statusMessage: String = "Idle"
    @Published public var filterText: String = ""
    @Published public var deviceIP: String = "—"

    // Capture sessions
    @Published public var sessions: [CaptureSession] = []
    /// The session currently being recorded into (nil when not capturing).
    @Published public var activeSessionID: UUID?
    /// Which session the flow list is showing (nil = the Sessions list itself).
    @Published public var viewingSessionID: UUID?
    /// Selected resource-type buckets; empty = show all.
    @Published public var resourceTypeFilter: Set<ResourceType> = []
    /// Flows of a non-active session being viewed (loaded on demand).
    // @Published so live appends (e.g. a paired device's session streaming in)
    // refresh the flow list — `displayedFlows` reads this for non-active sessions.
    @Published private var viewingFlows: [Flow] = []

    /// macOS: advertise the running proxy over Bonjour for iOS discovery.
    @Published public var bonjourEnabled = false
    /// macOS: human label shown to discovering devices.
    @Published public var bonjourDeviceName = ""
    /// Number of iPhones currently paired and capturing to this Mac.
    @Published public private(set) var pairedDeviceCount = 0
    /// Latest Bonjour publish state, surfaced in the status bar.
    @Published public var bonjourPublishState: BonjourPublishState?

    #if os(iOS)
    /// iOS: where capture is sent. Drives the VPN's proxy target.
    @Published public var captureTarget: CaptureTarget = .thisDevice
    /// iOS: discovered Macs (populated while browsing).
    @Published public var discoveredProxies: [DiscoveredProxy] = []
    /// iOS: manual fallback fields.
    @Published public var manualProxyHost: String = ""
    @Published public var manualProxyPort: Int = 9090
    /// iOS: health of the current remote capture path.
    @Published public var captureHealth: CaptureHealth = .unknown
    /// One-time Local Network disclosure shown before the OS prompt. Persisted so
    /// it appears only once across launches.
    @Published public var bonjourDisclosureShown = UserDefaults.standard.bool(forKey: "httrail.bonjourDisclosureShown") {
        didSet { UserDefaults.standard.set(bonjourDisclosureShown, forKey: "httrail.bonjourDisclosureShown") }
    }
    #endif

    // API client (compose)
    @Published public var requests: [APIRequest] = [APIRequest()]
    @Published public var selectedRequestID: APIRequest.ID?
    @Published public var responsesByRequest: [APIRequest.ID: APIResponse] = [:]
    @Published public var isSending = false

    // Workspace: environments, collections, history
    @Published public var environments: [RequestEnvironment] = []
    @Published public var activeEnvironmentID: UUID?
    @Published public var collections: [RequestCollection] = []
    @Published public var history: [HistoryEntry] = []

    // Rules (Charles)
    @Published public var rules: [InterceptRule] = []
    @Published public var selectedRuleID: InterceptRule.ID?
    /// Host globs that are MITM-decrypted (Charles "SSL Proxying" list). Empty =
    /// decrypt everything. Managed as a list in the UI.
    @Published public var sslAllowlist: [String] = []
    /// Bound to the "add host" field in the allowlist editor.
    @Published public var newAllowlistEntry: String = ""

    // Certificate-pinning auto-detection
    @Published public var pinningDetectionEnabled: Bool = true
    @Published public var detectedPinnedHosts: [PinnedHostInfo] = []
    /// Hosts the user forced back into decryption despite detection.
    @Published public var forcedDecryptHosts: [String] = []
    /// iOS: what the capture extension's engine is actually running (lets the
    /// Setup screen confirm rules/allowlist are live in the background process).
    @Published public var captureEngineStatus: EngineStatus?

    // Code generation & import
    @Published public var codeTarget: CodeGenerator.Target = .curl
    @Published public var importCurlText: String = ""
    @Published public var showImportSheet = false
    /// The v2 ⌘K command palette overlay (macOS).
    @Published public var showCommandPalette = false

    // Scripting
    @Published public var scriptOutputs: [UUID: ScriptOutput] = [:]

    // Shareable artifacts (CA + iOS profile) — primarily for iOS share sheets.
    @Published public var caFileURL: URL?
    @Published public var profileFileURL: URL?
    /// CA-only `.mobileconfig` (no proxy payload) — used for the on-device VPN
    /// capture flow, where the Packet Tunnel supplies the proxy itself.
    @Published public var caProfileFileURL: URL?

    // Realtime
    public enum RealtimeProtocol: String, CaseIterable, Identifiable, Sendable {
        case webSocket = "WebSocket"
        case socketIO = "Socket.IO"
        case sse = "SSE"
        case mqtt = "MQTT"
        public var id: String { rawValue }
        /// SSE is a receive-only stream; the message composer is hidden for it.
        public var canSend: Bool { self != .sse }
        /// Protocols configured by a single URL field (vs MQTT's host/port/topic).
        public var usesURL: Bool { self != .mqtt }
    }
    @Published public var rtProtocol: RealtimeProtocol = .webSocket {
        // Keep the endpoint fields pointed at the local test server when it's on.
        didSet {
            guard oldValue != rtProtocol else { return }
            if testServerRunning {
                applyLocalTestEndpoints()
            } else {
                applyDefaultRealtimeEndpoint(afterSwitchingFrom: oldValue)
            }
        }
    }
    @Published public var wsURL: String = AppModel.defaultWebSocketURL
    @Published public var wsConnected = false
    @Published public var wsMessages: [RealtimeMessage] = []
    @Published public var wsOutgoing: String = ""
    @Published public var sioEvent: String = "message"
    @Published public var mqttHost: String = "broker.hivemq.com"
    @Published public var mqttPort: Int = 1883
    @Published public var mqttTopic: String = "httrail/test"
    /// Whether the in-process realtime test server (echo + datetime) is running.
    @Published public var testServerRunning = false
    /// True while the local realtime server is starting or stopping on a background task.
    @Published public var testServerBusy = false

    // Breakpoints
    @Published public var pendingBreakpoint: BreakpointEvent?
    @Published public var breakpointBody: String = ""
    private var breakpointContinuation: CheckedContinuation<BreakpointEdit?, Never>?

    /// macOS can flip the system-wide HTTP proxy; iOS cannot, so the UI hides
    /// that control and shows manual Wi-Fi proxy guidance instead.
    public var systemProxyAvailable: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    public let ca: CertificateAuthority
    public let engine = InterceptEngine()
    private let configStore = SharedConfigStore()
    private let bridge = FlowBridge()
    private var proxy: ProxyServer?
    private let runner = RequestRunner()
    private let workspace: Workspace
    private let sessionStore: CaptureSessionStore
    private let scriptRunner = ScriptRunner()
    private var webSocket: WebSocketClient?
    private var socketIO: SocketIOClient?
    private var mqtt: MQTTClient?
    private var sseTask: Task<Void, Never>?
    private var testServer: RealtimeTestServer?
    private var testServerHTTPPort = 0
    private var testServerMQTTPort = 0
    /// Saved realtime endpoints to restore when the test server is turned off.
    private var savedRealtimeEndpoints: (wsURL: String, mqttHost: String, mqttPort: Int)?
    #if os(macOS)
    private let systemProxy = SystemProxyController()
    private let bonjourAdvertiser = BonjourAdvertiser()
    private var pairingServer: PairingServer?
    private var pairingPort: Int = 0
    private struct DeviceCapture {
        let ca: CertificateAuthority
        let proxy: ProxyServer
        let port: Int
        let sessionID: UUID
        let bridge: FlowBridge
    }
    private var deviceProxies: [String: DeviceCapture] = [:]
    #endif
    #if os(iOS)
    /// Flows captured by the Packet Tunnel extension (background) are read from
    /// the shared App Group store and merged into `flows`.
    private let sharedStore = SharedFlowStore()
    private let bonjourBrowser = BonjourBrowser()
    private var bonjourBrowserCancellable: AnyCancellable?
    private var pendingRemoteEndpoint: (host: String, port: Int)?
    /// Continuous health/heartbeat poll while a capture is active (see
    /// `startCaptureMonitor`). Cancelled when capture stops.
    private var captureMonitorTask: Task<Void, Never>?
    #endif

    /// True when running inside the XCTest harness, so launch-time side effects
    /// (e.g. auto-starting the proxy from saved config) can be skipped.
    private static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public init(sessionStore: CaptureSessionStore = CaptureSessionStore(),
                workspace: Workspace = Workspace()) {
        self.sessionStore = sessionStore
        self.workspace = workspace
        if let ca = try? CertificateAuthority.loadOrCreate(in: AppPaths.certificatesDirectory) {
            self.ca = ca
        } else {
            self.ca = (try? CertificateAuthority.create()) ?? (try! CertificateAuthority.create())
        }

        environments = workspace.environments
        activeEnvironmentID = workspace.activeEnvironmentID
        collections = workspace.collections
        sessions = sessionStore.allSessions()
        history = workspace.history
        selectedRequestID = requests.first?.id
        deviceIP = LocalNetwork.primaryIPv4() ?? "127.0.0.1"

        bridge.onFlow = { [weak self] flow in
            MainActor.assumeIsolated { self?.ingest(flow) }
        }
        engine.breakpointHandler = { [weak self] event in
            await self?.awaitBreakpoint(event) ?? nil
        }

        // Restore persisted rules / allowlist / port / pinning and mirror them
        // into the engine (and, on iOS, the shared file the extension reads).
        if let saved = configStore.load() {
            rules = saved.rules
            sslAllowlist = saved.sslAllowlist
            proxyPort = saved.proxyPort
            pinningDetectionEnabled = saved.pinningEnabled
            forcedDecryptHosts = saved.forcedDecryptHosts
            bonjourEnabled = saved.bonjourEnabled
        }
        #if os(macOS)
        bonjourDeviceName = Host.current().localizedName ?? "Mac"
        #endif
        pushRulesToEngine()   // apply to engine + ensure the shared file exists

        writeArtifacts()
        #if os(macOS)
        refreshCATrust()
        #endif
        handleLaunchArguments()
        #if os(macOS)
        // If the user left "Discoverable over Bonjour" on, resume being a capture
        // target on launch: start the proxy (whose success path re-advertises and
        // brings the PairingServer back up). Without this the Mac silently isn't
        // discoverable after a relaunch even though the toggle reads "on".
        // Skipped under XCTest so the suite doesn't spin up real listeners.
        if bonjourEnabled, proxy == nil, !Self.isRunningUnitTests { startProxy() }
        #endif
        Task { await checkCATrust() }
    }

    /// Supports headless/automated launch: `--autostart` boots the proxy on the
    /// LAN, `--export-profile` writes the CA + iOS .mobileconfig and prints paths.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        if args.contains("--export-profile") {
            writeDeviceArtifacts()
        }
        if args.contains("--autostart") {
            startProxy()
        }
    }

    /// Writes the root CA (PEM) + iOS profile to support dir and records URLs
    /// (used by the iOS share sheet and the macOS reveal commands).
    public func writeArtifacts() {
        let caURL = AppPaths.exportedCACertificate
        try? ca.caCertificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        caFileURL = caURL
        let host = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
        let generator = ProfileGenerator()
        if let data = try? generator.makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: host, proxyPort: proxyPort) {
            let url = AppPaths.supportDirectory.appendingPathComponent("HTTrail.mobileconfig")
            try? data.write(to: url)
            profileFileURL = url
        }
        // CA-only variant for the on-device VPN capture flow.
        if let data = try? generator.makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: host, proxyPort: proxyPort,
            includeProxyPayload: false) {
            let url = AppPaths.supportDirectory.appendingPathComponent("HTTrail-CA.mobileconfig")
            try? data.write(to: url)
            caProfileFileURL = url
        }
    }

    /// Writes the root CA (PEM) and the iOS profile and prints their absolute
    /// paths to stdout (for `--export-profile` automation on macOS).
    public func writeDeviceArtifacts() {
        let caURL = AppPaths.exportedCACertificate
        try? ca.caCertificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        let host = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
        if let data = try? ProfileGenerator().makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: host, proxyPort: proxyPort) {
            let url = AppPaths.supportDirectory.appendingPathComponent("HTTrail.mobileconfig")
            try? data.write(to: url)
            print("HTTRAIL_PROFILE=\(url.path)")
            print("HTTRAIL_CA=\(caURL.path)")
            print("HTTRAIL_PROXY=\(host):\(proxyPort)")
        }
    }

    private func ingest(_ flow: Flow) {
        var flow = flow
        if let activeSessionID { flow.sessionID = activeSessionID }
        let isNew = !flows.contains { $0.id == flow.id }
        if let idx = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[idx] = flow
        } else {
            flows.insert(flow, at: 0)
        }
        if let activeSessionID {
            sessionStore.record(flow, in: activeSessionID)
            if isNew, let i = sessions.firstIndex(where: { $0.id == activeSessionID }) {
                sessions[i].recordCount += 1
            }
        }
    }

    #if DEBUG
    /// Test seam: feed a flow through the normal ingest path.
    public func ingestForTesting(_ flow: Flow) { ingest(flow) }
    public func sessionStoreFlowCountForTesting(_ id: UUID) -> Int { sessionStore.flows(in: id).count }
    #endif

    /// The flows the list should display: live `flows` for the active/own session,
    /// otherwise the loaded `viewingFlows` of a past session.
    public var displayedFlows: [Flow] {
        if let viewingSessionID, viewingSessionID != activeSessionID { return viewingFlows }
        return flows
    }

    public var filteredFlows: [Flow] {
        displayedFlows.filter { flow in
            let matchesText = filterText.isEmpty
                || flow.request.url.lowercased().contains(filterText.lowercased())
                || flow.request.host.lowercased().contains(filterText.lowercased())
                || flow.request.method.lowercased().contains(filterText.lowercased())
            let matchesType = resourceTypeFilter.isEmpty
                || resourceTypeFilter.contains(ResourceType.classify(flow))
            return matchesText && matchesType
        }
    }

    public var selectedFlow: Flow? {
        guard selectedFlowIDs.count == 1, let id = selectedFlowIDs.first else { return nil }
        return displayedFlows.first { $0.id == id }
    }

    public func toggleResourceType(_ type: ResourceType) {
        if resourceTypeFilter.contains(type) { resourceTypeFilter.remove(type) }
        else { resourceTypeFilter.insert(type) }
    }

    /// Show a session's flows (nil returns to the Sessions list).
    public func viewSession(_ id: UUID?) {
        viewingSessionID = id
        selectedFlowIDs = []
        if let id, id != activeSessionID {
            viewingFlows = sessionStore.flows(in: id)
        } else {
            viewingFlows = []
        }
    }

    // MARK: - Capture session lifecycle

    /// Establish the recording target: a brand-new session, or resume an existing
    /// one (reopening it and loading its prior flows so captures append).
    public func beginCaptureSession(resuming sessionID: UUID? = nil) {
        flows.removeAll()
        selectedFlowIDs.removeAll()
        #if os(iOS)
        sharedStore?.clear()
        #endif
        if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
            sessionStore.reopen(sessionID)
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i].endedAt = nil }
            activeSessionID = sessionID
            flows = sessionStore.flows(in: sessionID)
        } else {
            let session = sessionStore.createSession(name: CaptureSession.defaultName(for: Date()),
                                                     startedAt: Date())
            sessions.insert(session, at: 0)
            activeSessionID = session.id
        }
        viewingSessionID = activeSessionID
        viewingFlows = []
    }

    /// Mark the active session ended and stop recording into it.
    public func endCaptureSession() {
        guard let id = activeSessionID else { return }
        let now = Date()
        sessionStore.endSession(id, at: now)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].endedAt = now }
        activeSessionID = nil
    }

    // MARK: - Session editing

    public func renameSession(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionStore.rename(id, to: trimmed)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].name = trimmed }
    }

    public func setSessionNotes(_ id: UUID, _ notes: String) {
        sessionStore.setNotes(id, notes)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].notes = notes }
    }

    public func deleteSession(_ id: UUID) {
        // Deleting the session we're actively recording into would leave newly
        // captured flows with nowhere to go. Detect that and immediately open a
        // fresh session so capture continues uninterrupted.
        let wasRecording = (activeSessionID == id)
        sessionStore.deleteSession(id)
        sessions.removeAll { $0.id == id }
        if activeSessionID == id { activeSessionID = nil; flows.removeAll() }
        if viewingSessionID == id { viewingSessionID = nil; viewingFlows = [] }
        selectedFlowIDs.removeAll()
        if wasRecording { beginCaptureSession() }
    }

    /// Select every currently-visible (filtered) flow — backs a "Select All"
    /// affordance in the capture flow list.
    public func selectAllVisibleFlows() {
        selectedFlowIDs = Set(filteredFlows.map { $0.id })
    }

    /// Delete the currently-selected rows from the session being viewed/recorded.
    public func deleteSelectedFlows() {
        let target = viewingSessionID ?? activeSessionID
        guard let target, !selectedFlowIDs.isEmpty else { return }
        sessionStore.deleteFlows(selectedFlowIDs, in: target)
        if target == activeSessionID {
            flows.removeAll { selectedFlowIDs.contains($0.id) }
        } else {
            viewingFlows.removeAll { selectedFlowIDs.contains($0.id) }
        }
        if let i = sessions.firstIndex(where: { $0.id == target }) {
            sessions[i].recordCount = max(0, sessions[i].recordCount - selectedFlowIDs.count)
        }
        selectedFlowIDs.removeAll()
    }

    public var resolvedEnvironment: [String: String] {
        environments.first { $0.id == activeEnvironmentID }?.resolved ?? [:]
    }

    // MARK: - Proxy lifecycle

    public func toggleProxy() { isProxyRunning ? stopProxy() : startProxy() }

    public func startProxy(resuming sessionID: UUID? = nil) {
        guard !isProxyRunning else { return }
        beginCaptureSession(resuming: sessionID)
        pushRulesToEngine()
        let server = ProxyServer(port: proxyPort, certificateAuthority: ca, sink: bridge, engine: engine)
        self.proxy = server
        statusMessage = "Starting proxy on \(deviceIP):\(proxyPort)…"
        Task {
            do {
                try await server.start()
                self.isProxyRunning = true
                self.deviceIP = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
                self.statusMessage = "Proxy listening on \(self.deviceIP):\(self.proxyPort)"
                #if os(macOS)
                self.refreshBonjour()
                #endif
            } catch {
                self.statusMessage = "Failed to start proxy: \(error.localizedDescription)"
                self.proxy = nil
                self.endCaptureSession()
            }
        }
    }

    public func stopProxy() {
        guard let proxy else { return }
        statusMessage = "Stopping proxy…"
        Task {
            try? await proxy.stop()
            self.proxy = nil
            self.isProxyRunning = false
            self.endCaptureSession()
            self.statusMessage = "Proxy stopped"
            #if os(macOS)
            self.refreshBonjour()
            #endif
        }
    }

    public func clearFlows() {
        flows.removeAll(); selectedFlowIDs.removeAll()
        #if os(iOS)
        sharedStore?.clear()
        #endif
    }

    #if os(iOS)
    /// Pulls any new/updated flows the background extension captured into the UI.
    /// Call on a timer while the capture VPN is active.
    public func refreshSharedFlows() {
        guard let sharedStore else { return }
        // `readAll()` is newest-first; ingest oldest-first so order is preserved.
        for flow in sharedStore.readAll().reversed() { ingest(flow) }
    }

    /// Whether the extension published its engine status within the last few
    /// seconds — i.e. the capture engine is alive and applying config right now.
    public var captureEngineLive: Bool {
        guard let status = captureEngineStatus else { return false }
        return Date().timeIntervalSince(status.updatedAt) < 6
    }

    /// Pull the extension's published engine status into the UI (iOS timer).
    public func refreshCaptureStatus() {
        let status = configStore.loadEngineStatus()
        if status != captureEngineStatus { captureEngineStatus = status }
    }

    private var profileServer: ProfileHTTPServer?

    /// Builds the combined **VPN + root-CA** capture profile and serves it from a
    /// loopback HTTP server so iOS can install it. Returns the URL the app should
    /// open in Safari to kick off the *Settings ▸ Profile* install flow (the user
    /// then approves both the CA and the VPN there). Returns `nil` on failure.
    public func captureProfileInstallURL() -> URL? {
        let appID = Bundle.main.bundleIdentifier ?? "com.1moby.httrail"
        let providerID = appID + ".PacketTunnel"
        guard let data = try? ProfileGenerator().makeCaptureProfile(
            caCertificateDER: ca.caCertificateDER, appBundleID: appID,
            providerBundleID: providerID, proxyPort: proxyPort) else {
            statusMessage = "Could not build capture profile"; return nil
        }
        profileServer?.stop()
        let server = ProfileHTTPServer(payload: data)
        do {
            let port = try server.start()
            profileServer = server
            statusMessage = "Opening profile installer — approve it in Settings ▸ Profile"
            return URL(string: "http://127.0.0.1:\(port)/HTTrail.mobileconfig")
        } catch {
            statusMessage = "Could not start profile installer: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Bonjour browsing + capture target (iOS only)

    /// Begin browsing for Macs; mirrors the browser's results into `discoveredProxies`.
    public func startBonjourBrowsing() {
        bonjourBrowserCancellable = bonjourBrowser.$found
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.discoveredProxies = $0 }
        bonjourBrowser.start()
    }

    public func stopBonjourBrowsing() {
        bonjourBrowser.stop()
        bonjourBrowserCancellable?.cancel()
        bonjourBrowserCancellable = nil
    }

    /// Upload this iPhone's CA (certificate AND private key) to a discovered Mac
    /// so the Mac can decrypt this device's traffic with a CA the iPhone already
    /// trusts — nothing is installed on the Mac. NOTE: the private key is sent
    /// over plaintext HTTP; acceptable here because pairing is LAN-only on a
    /// network the user controls (same posture as Charles/Proxyman). Returns the
    /// Mac's dedicated proxy port, or nil on failure.
    public func pairWithMac(_ proxy: DiscoveredProxy) async -> Int? {
        guard proxy.pairPort > 0 else { return nil }
        let deviceName = UIDevice.current.name
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let req = PairRequest(deviceName: deviceName, deviceID: deviceID,
                              caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM)
        guard let body = try? JSONEncoder().encode(req),
              let url = URL(string: "http://\(proxy.host):\(proxy.pairPort)/pair") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        // LAN control traffic — must reach the Mac directly. Bypass any system/VPN
        // proxy so a still-active capture tunnel from a previous run can't divert
        // the CA upload, which would silently break pairing.
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, resp) = try? await session.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PairResponse.self, from: data) else { return nil }
        return decoded.proxyPort
    }

    /// Publish the selected capture target into SharedConfig so the PacketTunnel
    /// extension routes correctly, then return the (host, port) for health checks
    /// (nil for on-device). For a discovered Mac this first pairs (uploading our
    /// CA) and uses the dedicated proxy port the Mac returns.
    @discardableResult
    public func applyCaptureTargetForStart() async -> (host: String, port: Int)? {
        switch captureTarget {
        case .thisDevice:
            pushCaptureTargetConfig(nil)
            return nil
        case .manual(let host, let port):
            pushCaptureTargetConfig((host, port))
            return (host, port)
        case .remote(let proxy):
            guard let port = await pairWithMac(proxy) else {
                statusMessage = "Couldn't pair with \(proxy.name)"
                pushCaptureTargetConfig(nil)
                return nil
            }
            let endpoint = (proxy.host, port)
            pushCaptureTargetConfig(endpoint)
            return endpoint
        }
    }

    private func pushCaptureTargetConfig(_ endpoint: (host: String, port: Int)?) {
        pendingRemoteEndpoint = endpoint
        pushRulesToEngine()
    }

    /// Start continuously monitoring capture health while a session is active.
    /// Pass the remote endpoint for a Mac/manual target, or `nil` for on-device
    /// capture. Keeps `captureHealth` fresh so the banner reflects reality for the
    /// whole session (e.g. a Mac that drops, or a CA that isn't trusted).
    ///
    /// Trust is judged by the **local** `CATrustProbe` — does *this device* trust
    /// our CA? — not by round-tripping HTTPS through the tunnel. This is
    /// authoritative and deterministic for BYO-CA capture: the Mac signs leaves
    /// with the exact CA this device uploaded, so if the device trusts that CA,
    /// MITM here validates. It also can't be misled by tunnel-setup timing or a
    /// probe host's own pinning. Two dimensions:
    ///   - reachability/heartbeat: is the Mac proxy (or on-device engine) alive?
    ///   - trust: is our CA installed & trusted on this device?
    ///
    /// Cadence: reachability/heartbeat every ~5s (cheap); the CA-trust probe every
    /// ~15s (cached between), evaluated immediately on the first tick.
    public func startCaptureMonitor(remote: (host: String, port: Int)?) {
        captureMonitorTask?.cancel()
        captureHealth = .unknown
        captureMonitorTask = Task { [weak self] in
            var tick = 0
            var trusted = false
            while !Task.isCancelled {
                guard let self else { return }
                // Refresh the authoritative local CA-trust verdict periodically.
                if tick % 3 == 0 {
                    let t = await CATrustProbe.check(ca: self.ca, timeout: 4)
                    if Task.isCancelled { return }
                    trusted = t
                    if self.caTrusted != t { self.caTrusted = t }
                }

                let newHealth: CaptureHealth
                if let remote {
                    let reachable = await CaptureHealthCheck.reachable(host: remote.host, port: remote.port, timeout: 3)
                    if Task.isCancelled { return }
                    newHealth = !reachable ? .unreachable : (trusted ? .healthy : .tlsUntrusted)
                } else {
                    // On-device: the extension must be alive AND our CA trusted.
                    self.refreshCaptureStatus()
                    newHealth = !self.captureEngineLive ? .unreachable : (trusted ? .healthy : .tlsUntrusted)
                }
                if self.captureHealth != newHealth { self.captureHealth = newHealth }

                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Stop the capture health monitor and reset to a neutral state.
    public func stopCaptureMonitor() {
        captureMonitorTask?.cancel()
        captureMonitorTask = nil
        captureHealth = .unknown
    }
    #endif

    // MARK: - System proxy (macOS only)

    #if os(macOS)
    public func toggleSystemProxy() {
        guard SystemProxyController.canManageSystem else {
            statusMessage = "Sandboxed build: set the system proxy to 127.0.0.1:\(proxyPort) "
                + "manually in System Settings → Network → Proxies (Web + Secure Web)."
            return
        }
        guard let service = systemProxy.primaryNetworkService() else {
            statusMessage = "No active network service found"; return
        }
        if systemProxyEnabled {
            if systemProxy.disableProxy(service: service) {
                systemProxyEnabled = false; statusMessage = "System proxy disabled on \(service)"
            }
        } else {
            if systemProxy.enableProxy(service: service, host: "127.0.0.1", port: proxyPort) {
                systemProxyEnabled = true
                statusMessage = "System proxy enabled on \(service) → 127.0.0.1:\(proxyPort)"
            } else {
                statusMessage = "Could not change system proxy (permission denied?)"
            }
        }
    }

    /// Re-reads whether our root CA is installed in the System keychain.
    public func refreshCATrust() {
        caTrusted = systemProxy.isCertificateInSystemKeychain(commonName: CertificateAuthority.caCommonName)
    }

    /// One-click: write the root CA to disk and add it to the System keychain as
    /// an always-trusted root (admin-prompted). This is what makes macOS HTTPS
    /// capture work without manually fiddling in Keychain Access.
    public func installCACertificate() {
        let url = AppPaths.exportedCACertificate
        do {
            try ca.caCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "Could not write CA: \(error.localizedDescription)"; return
        }
        caFileURL = url
        guard SystemProxyController.canManageSystem else {
            // Sandboxed Mac App Store build can't touch the System keychain. Reveal
            // the exported .pem so the user can trust it in Keychain Access.
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
            statusMessage = "Sandboxed build: open the revealed HTTrailCA.pem in Keychain Access "
                + "and set it to Always Trust to enable HTTPS capture."
            return
        }
        statusMessage = "Requesting admin to trust the HTTrail root CA…"
        if systemProxy.installTrustedRootCA(pemPath: url.path) {
            caTrusted = true
            statusMessage = "Root CA installed & trusted in the System keychain"
        } else {
            refreshCATrust()
            statusMessage = caTrusted ? "Root CA already trusted" : "CA trust cancelled or failed"
        }
    }

    /// Removes our root CA from the System keychain (admin-prompted).
    public func uninstallCACertificate() {
        let url = AppPaths.exportedCACertificate
        if systemProxy.removeTrustedRootCA(pemPath: url.path) {
            statusMessage = "Root CA removed from the System keychain"
        } else {
            statusMessage = "Could not remove CA (not present?)"
        }
        refreshCATrust()
    }

    /// Reconstruct an uploaded CA, start a dedicated proxy for that device on an
    /// ephemeral port, and create a session to record its flows into. The CA is
    /// held in memory only — never written to disk or the Mac keychain.
    public func pairDevice(_ req: PairRequest) async -> PairResponse? {
        if deviceProxies[req.deviceID] != nil { await unpairDevice(req.deviceID) }
        guard let ca = try? CertificateAuthority.from(certificatePEM: req.caCertPEM, keyPEM: req.caKeyPEM) else {
            return nil
        }
        let name = "\(req.deviceName) \(CaptureSession.defaultName(for: Date()))"
        let session = sessionStore.createSession(name: name, startedAt: Date())
        sessions = sessionStore.allSessions()

        let bridge = FlowBridge()
        let sid = session.id
        bridge.onFlow = { [weak self] flow in
            MainActor.assumeIsolated { self?.ingestDeviceFlow(flow, sessionID: sid) }
        }
        let proxy = ProxyServer(port: 0, certificateAuthority: ca, sink: bridge, engine: engine)
        proxy.bindHost = "0.0.0.0"
        do {
            try await proxy.start()
        } catch {
            statusMessage = "Failed to start device proxy: \(error.localizedDescription)"
            return nil
        }
        let port = proxy.boundPort
        deviceProxies[req.deviceID] = DeviceCapture(ca: ca, proxy: proxy, port: port, sessionID: sid, bridge: bridge)
        pairedDeviceCount = deviceProxies.count
        // Switch the Mac UI straight to this device's session so its traffic shows
        // up live as it arrives (the user asked for it to flip to live capture).
        viewingSessionID = sid
        viewingFlows = []
        selectedFlowIDs = []
        statusMessage = "Capturing \(req.deviceName) → \(name)"
        return PairResponse(proxyPort: port, sessionName: name)
    }

    public func unpairDevice(_ deviceID: String) async {
        guard let device = deviceProxies.removeValue(forKey: deviceID) else { return }
        try? await device.proxy.stop()
        pairedDeviceCount = deviceProxies.count
    }

    private func tearDownAllDeviceProxies() {
        let devices = deviceProxies
        deviceProxies.removeAll()
        pairedDeviceCount = 0
        for (_, d) in devices { Task { try? await d.proxy.stop() } }
    }

    /// Record a flow captured for a paired device into that device's session,
    /// without touching the Mac's own active capture session.
    public func ingestDeviceFlow(_ flow: Flow, sessionID: UUID) {
        var flow = flow
        flow.sessionID = sessionID
        sessionStore.record(flow, in: sessionID)   // store dedupes by id + maintains count
        if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].recordCount = sessionStore.flowCount(in: sessionID)
        }
        // Live feed: if this device's session is on screen, append/replace in place
        // (newest-first) rather than reloading the whole session per flow.
        if viewingSessionID == sessionID, viewingSessionID != activeSessionID {
            if let idx = viewingFlows.firstIndex(where: { $0.id == flow.id }) {
                viewingFlows[idx] = flow
            } else {
                viewingFlows.insert(flow, at: 0)
            }
        }
    }

    /// Advertise over Bonjour whenever the toggle is on (auto-starting the proxy
    /// if needed) and run the PairingServer so iPhones can upload their CA.
    public func refreshBonjour() {
        if bonjourEnabled && isProxyRunning {
            if pairingServer == nil {
                let server = PairingServer()
                server.onPair = { [weak self] req in await self?.pairDevice(req) }
                server.onUnpair = { [weak self] id in await self?.unpairDevice(id) }
                pairingPort = (try? server.start(bindHost: "0.0.0.0")) ?? 0
                pairingServer = server
            }
            bonjourAdvertiser.onState = { [weak self] state in
                MainActor.assumeIsolated {
                    self?.bonjourPublishState = state
                    if case .failed(let msg) = state { self?.statusMessage = msg }
                }
            }
            bonjourAdvertiser.start(name: bonjourDeviceName, port: proxyPort,
                                    caPort: 0, caFP: "", pairPort: pairingPort)
            statusMessage = "Proxy on \(deviceIP):\(proxyPort) · Discoverable as \"\(bonjourDeviceName)\""
        } else {
            bonjourAdvertiser.stop()
            bonjourPublishState = nil
            tearDownAllDeviceProxies()
            pairingServer?.stop(); pairingServer = nil; pairingPort = 0
        }
    }

    public func setBonjourEnabled(_ enabled: Bool) {
        bonjourEnabled = enabled
        pushRulesToEngine()
        if enabled && !isProxyRunning {
            startProxy()
        } else {
            refreshBonjour()
        }
    }
    #endif

    // MARK: - CA export / profiles

    /// Returns the on-disk CA URL; on macOS it also reveals it in Finder.
    @discardableResult
    public func revealCACertificate() -> URL? {
        let url = AppPaths.exportedCACertificate
        try? ca.caCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
        caFileURL = url
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        return url
    }

    @discardableResult
    public func exportiOSProfile() -> URL? {
        let host = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
        guard let data = try? ProfileGenerator().makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: host, proxyPort: proxyPort) else {
            statusMessage = "Failed to build profile"; return nil
        }
        let url = AppPaths.supportDirectory.appendingPathComponent("HTTrail.mobileconfig")
        try? data.write(to: url)
        profileFileURL = url
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        statusMessage = "iOS profile written (proxy host \(host):\(proxyPort))"
        return url
    }

    @discardableResult
    public func exportHAR(sessionID: UUID? = nil) -> URL? {
        let target = sessionID ?? viewingSessionID ?? activeSessionID
        let source: [Flow]
        if let target, target != activeSessionID {
            source = sessionStore.flows(in: target)
        } else {
            source = flows
        }
        guard !source.isEmpty, let data = try? HARExporter().export(source.reversed()) else {
            statusMessage = "Nothing to export"; return nil
        }
        let label = sessions.first { $0.id == target }?.name ?? "session"
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
        let url = AppPaths.supportDirectory
            .appendingPathComponent("HTTrail-\(safe)-\(Int(Date().timeIntervalSince1970)).har")
        try? data.write(to: url)
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        statusMessage = "Exported \(source.count) flows to HAR"
        return url
    }

    /// Export an explicit set of flows (e.g. the multi-selected rows) to a HAR
    /// file. Used by the capture list's batch "Export selected" action.
    public func exportHAR(flowIDs: Set<Flow.ID>) -> URL? {
        let source = displayedFlows.filter { flowIDs.contains($0.id) }
        guard !source.isEmpty, let data = try? HARExporter().export(source.reversed()) else {
            statusMessage = "Nothing to export"; return nil
        }
        let label = sessions.first { $0.id == (viewingSessionID ?? activeSessionID) }?.name ?? "selection"
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
        let url = AppPaths.supportDirectory
            .appendingPathComponent("HTTrail-\(safe)-\(source.count)flows-\(Int(Date().timeIntervalSince1970)).har")
        try? data.write(to: url)
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        statusMessage = "Exported \(source.count) flows to HAR"
        return url
    }

    // MARK: - API client

    nonisolated public static func composeRequestTitle(for request: APIRequest) -> String {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != "New Request" {
            return name
        }
        if let host = composeHostname(from: request.url) {
            return host
        }
        let url = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty || url == "https://" ? "New Request" : url
    }

    nonisolated public static func composeHistoryTitle(for entry: HistoryEntry) -> String {
        composeHistoryTitle(for: entry, timestampText: composeHistoryTimestamp(for: entry.timestamp))
    }

    nonisolated public static func composeHistoryTitle(for entry: HistoryEntry, timestampText: String) -> String {
        let host = composeHostname(from: entry.request.url) ?? composeRequestTitle(for: entry.request)
        let timestamp = timestampText.trimmingCharacters(in: .whitespacesAndNewlines)
        return timestamp.isEmpty ? host : "\(host) · \(timestamp)"
    }

    nonisolated public static func composeHistoryTimestamp(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated public static func composeHostname(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = hostFromComponents(trimmed) {
            return host
        }
        if !trimmed.contains("://"), let host = hostFromComponents("https://\(trimmed)") {
            return host
        }
        return hostFromAuthorityFallback(trimmed)
    }

    nonisolated private static func hostFromComponents(_ string: String) -> String? {
        guard let host = URLComponents(string: string)?.host, !host.isEmpty else { return nil }
        return host
    }

    nonisolated private static func hostFromAuthorityFallback(_ string: String) -> String? {
        let afterScheme: Substring
        if let scheme = string.range(of: "://") {
            afterScheme = string[scheme.upperBound...]
        } else {
            afterScheme = string[...]
        }
        guard let authority = afterScheme.split(whereSeparator: { "/?#".contains($0) }).first else {
            return nil
        }
        let userless = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? authority
        guard !userless.isEmpty else { return nil }
        if userless.hasPrefix("[") {
            guard let end = userless.firstIndex(of: "]") else { return nil }
            return String(userless[userless.startIndex...end])
        }
        return String(userless.split(separator: ":", maxSplits: 1).first ?? userless)
    }

    public var selectedRequestIndex: Int? { requests.firstIndex { $0.id == selectedRequestID } }

    public func newRequest() {
        let req = APIRequest()
        requests.append(req)
        selectedRequestID = req.id
    }

    public func prepareComposeURLFieldForEditing(at index: Int) {
        guard requests.indices.contains(index) else { return }
        if requests[index].url.trimmingCharacters(in: .whitespacesAndNewlines) == Self.defaultComposeURL {
            requests[index].url = ""
        }
    }

    @discardableResult
    public func normalizeComposeURLIfNeeded(_ text: String, at index: Int) -> Bool {
        guard requests.indices.contains(index),
              let normalized = Self.normalizedComposeURL(from: text),
              normalized != requests[index].url else { return false }
        requests[index].url = normalized
        return true
    }

    nonisolated static func normalizedComposeURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSchemeEnd = trimmed.range(of: "://")?.upperBound else { return nil }
        let afterFirstScheme = trimmed[firstSchemeEnd...]
        guard let secondSchemeSeparator = afterFirstScheme.range(of: "://") else { return nil }

        let pastedScheme = String(afterFirstScheme[..<secondSchemeSeparator.lowerBound]).lowercased()
        guard ["http", "https", "ws", "wss"].contains(pastedScheme) else { return nil }
        return String(afterFirstScheme)
    }

    public func sendSelectedRequest() {
        guard let idx = selectedRequestIndex else { return }
        let request = requests[idx]
        var env = resolvedEnvironment
        isSending = true
        statusMessage = "Sending \(request.method) \(request.url)…"

        // Pre-request script can mutate the request + environment.
        var effectiveRequest = request
        var output = ScriptOutput()
        if !request.preRequestScript.isEmpty {
            let pre = scriptRunner.runPreRequest(request.preRequestScript, request: request, environment: env)
            effectiveRequest = pre.request
            env = pre.environment
            output.logs += pre.consoleLog
            if let err = pre.error { output.logs.append("⚠️ pre-request: \(err)") }
            applyEnvironmentUpdates(env)
        }

        let finalRequest = effectiveRequest
        let finalEnv = env
        let testScript = request.testScript
        Task {
            let response = await runner.send(finalRequest, environment: finalEnv)
            self.responsesByRequest[request.id] = response

            if !testScript.isEmpty {
                let result = self.scriptRunner.runTests(testScript, request: finalRequest,
                                                        response: response, environment: finalEnv)
                output.logs += result.consoleLog
                output.tests = result.tests.map { ($0.name, $0.passed, $0.message) }
                self.applyEnvironmentUpdates(result.environment)
                if let err = result.error { output.logs.append("⚠️ tests: \(err)") }
            }
            self.scriptOutputs[request.id] = output

            self.isSending = false
            let passed = output.tests.filter { $0.passed }.count
            let testSummary = output.tests.isEmpty ? "" : " · tests \(passed)/\(output.tests.count)"
            self.statusMessage = response.error.map { "Request failed: \($0)" }
                ?? "\(response.statusCode) · \(response.durationMS) ms · \(response.body.count) bytes\(testSummary)"

            let entry = HistoryEntry(request: request, statusCode: response.statusCode,
                                     durationMS: response.durationMS, timestamp: Date(),
                                     response: response)
            self.workspace.addHistory(entry)
            self.history = self.workspace.history
        }
    }

    private func applyEnvironmentUpdates(_ updated: [String: String]) {
        guard let id = activeEnvironmentID, let idx = environments.firstIndex(where: { $0.id == id }) else { return }
        for (key, value) in updated {
            if let vIdx = environments[idx].variables.firstIndex(where: { $0.name == key }) {
                environments[idx].variables[vIdx].value = value
            } else {
                environments[idx].variables.append(KeyValueItem(name: key, value: value))
            }
        }
        persistEnvironments()
    }

    // MARK: - Importers

    public func importCollection(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { statusMessage = "Could not read file"; return }
        if let imported = OpenAPIImporter().importDocument(data) ?? PostmanImporter().importDocument(data) {
            applyImportedCollection(imported)
            return
        }
        do {
            let backup = try PostmanBackupImporter().importBackup(data)
            applyPostmanBackupImport(backup, sourceName: url.lastPathComponent)
        } catch {
            statusMessage = "Unrecognized OpenAPI/Postman file"
        }
    }

    public func importLatestPostmanBackup() {
        guard let url = PostmanBackupLocator().latestBackupFile() else {
            statusMessage = "No Postman backup found in ~/Library/Application Support/Postman"
            return
        }
        importPostmanBackup(from: url)
    }

    public func importPostmanBackup(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let backup = try PostmanBackupImporter().importBackup(data)
            applyPostmanBackupImport(backup, sourceName: url.lastPathComponent)
        } catch {
            statusMessage = "Could not import Postman backup: \(error.localizedDescription)"
        }
    }

    private func applyImportedCollection(_ collection: RequestCollection) {
        collections.append(collection)
        workspace.setCollections(collections)
        mode = .compose
        statusMessage = "Imported “\(collection.name)” (\(collection.requests.count) requests)"
    }

    private func applyPostmanBackupImport(_ imported: PostmanBackupImport, sourceName: String) {
        collections.append(contentsOf: imported.collections)
        workspace.setCollections(collections)
        if !imported.environments.isEmpty {
            environments.append(contentsOf: imported.environments)
            activeEnvironmentID = imported.environments.first?.id
            persistEnvironments()
        }
        mode = .compose
        let requestCount = imported.collections.reduce(0) { $0 + Self.requestCount(in: $1) }
        let environmentPart = imported.environments.isEmpty ? "" : " · \(imported.environments.count) environments"
        statusMessage = "Imported Postman backup “\(sourceName)” "
            + "(\(imported.collections.count) collections, \(requestCount) requests\(environmentPart))"
    }

    nonisolated private static func requestCount(in collection: RequestCollection) -> Int {
        collection.requests.count + collection.folders.reduce(0) { $0 + requestCount(in: $1) }
    }

    public func generatedCode() -> String {
        guard let idx = selectedRequestIndex else { return "" }
        return CodeGenerator().generate(requests[idx], target: codeTarget, environment: resolvedEnvironment)
    }

    public func importCurl() {
        guard let request = CurlConverter().importCommand(importCurlText) else {
            statusMessage = "Could not parse cURL command"; return
        }
        requests.append(request)
        selectedRequestID = request.id
        showImportSheet = false
        importCurlText = ""
        mode = .compose
        statusMessage = "Imported request"
    }

    /// Detects a pasted cURL command (e.g. into the URL field) and, if found,
    /// parses it into the request at `index` in place. Returns true if applied.
    ///
    /// Works even when the command isn't at the very front of the field — pasting
    /// into a field that already has text, or with the cursor mid-string, yields a
    /// value like `…oldcurl …`; we locate the embedded `curl …` and import it,
    /// discarding the surrounding junk.
    @discardableResult
    public func applyCurlIfDetected(_ text: String, at index: Int) -> Bool {
        guard requests.indices.contains(index) else { return false }
        guard let command = Self.extractCurlCommand(from: text),
              let parsed = CurlConverter().importCommand(command),
              !parsed.url.isEmpty else { return false }
        var updated = parsed
        updated.id = requests[index].id          // keep list identity/selection
        if !requests[index].name.isEmpty { updated.name = requests[index].name }
        requests[index] = updated
        statusMessage = "Imported cURL"
        return true
    }

    /// Extracts a `curl …` invocation from arbitrary text. Returns the command
    /// substring (from the `curl` token to the end) or nil if none looks real.
    ///
    /// A bare URL that merely contains the letters "curl" must NOT match, so we
    /// require `curl` to be followed by whitespace and the remainder to carry a
    /// flag (` -…`) or a URL scheme (`://`) — the unmistakable shape of a command.
    nonisolated static func extractCurlCommand(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTrimmed = trimmed.lowercased()
        // Fast path: the whole field is the command (the common, cursor-at-front case).
        if lowerTrimmed == "curl" { return nil }   // "curl" alone has no URL — ignore
        if lowerTrimmed.hasPrefix("curl ") || lowerTrimmed.hasPrefix("curl\t") || lowerTrimmed.hasPrefix("curl\n") {
            return trimmed
        }
        // Otherwise scan for an embedded `curl` token followed by whitespace.
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while let r = lower.range(of: "curl", range: searchStart..<lower.endIndex) {
            searchStart = r.upperBound
            guard r.upperBound < lower.endIndex, lower[r.upperBound].isWhitespace else { continue }
            let candidate = String(text[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let candLower = candidate.lowercased()
            guard candLower.contains(" -") || candLower.contains("://") else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - Collections / environments

    public func saveRequestToCollection() {
        guard let idx = selectedRequestIndex else { return }
        let request = requests[idx]
        if collections.isEmpty {
            collections = [RequestCollection(name: "My Collection", requests: [request])]
        } else {
            collections[0].requests.append(request)
        }
        workspace.setCollections(collections)
        statusMessage = "Saved “\(request.name)” to \(collections[0].name)"
    }

    public func loadRequest(_ request: APIRequest) {
        var copy = request
        copy.id = UUID()
        requests.append(copy)
        selectedRequestID = copy.id
        mode = .compose
    }

    /// Reopen a past send from history: restore the exact request *and* its
    /// response so the response pane shows the old result. Reuses the request's
    /// original id so repeat clicks reselect the open request instead of piling
    /// up duplicate copies.
    public func loadHistory(_ entry: HistoryEntry) {
        let request = entry.request
        if !requests.contains(where: { $0.id == request.id }) {
            requests.append(request)
        }
        selectedRequestID = request.id
        if let response = entry.response {
            responsesByRequest[request.id] = response
        }
        mode = .compose
    }

    public func addEnvironment() {
        let env = RequestEnvironment(name: "Environment \(environments.count + 1)",
                                     variables: [KeyValueItem(name: "baseUrl", value: "https://")])
        environments.append(env)
        activeEnvironmentID = env.id
        persistEnvironments()
    }

    public func persistEnvironments() {
        workspace.setEnvironments(environments)
        workspace.activeEnvironmentID = activeEnvironmentID
    }

    public func clearHistory() { workspace.clearHistory(); history = [] }

    // MARK: - Rules

    public var selectedRuleIndex: Int? { rules.firstIndex { $0.id == selectedRuleID } }

    public func addRule() {
        var rule = InterceptRule()
        rule.name = "Rule \(rules.count + 1)"
        rules.append(rule)
        selectedRuleID = rule.id
        pushRulesToEngine()
    }

    public func deleteSelectedRule() {
        rules.removeAll { $0.id == selectedRuleID }
        selectedRuleID = nil
        pushRulesToEngine()
    }

    /// Snapshot of the persistable / cross-process proxy configuration.
    private func currentConfig() -> SharedConfig {
        var config = SharedConfig()
        config.rules = rules
        config.sslAllowlist = sslAllowlist
        config.proxyPort = proxyPort
        config.pinningEnabled = pinningDetectionEnabled
        config.forcedDecryptHosts = forcedDecryptHosts
        config.bonjourEnabled = bonjourEnabled
        #if os(iOS)
        config.remoteProxyHost = pendingRemoteEndpoint?.host
        config.remoteProxyPort = pendingRemoteEndpoint?.port
        #endif
        return config
    }

    /// The single sync point: applies the current config to the in-process engine
    /// and writes it to the shared store (persistence on macOS; the bridge the
    /// iOS extension reads so rules/allowlist/pinning actually take effect there).
    public func pushRulesToEngine() {
        let config = currentConfig()
        engine.apply(config)
        configStore.save(config)
    }

    // MARK: SSL allowlist editing

    /// Add a host glob from `newAllowlistEntry` (or an explicit value).
    public func addAllowlistEntry(_ raw: String? = nil) {
        let value = (raw ?? newAllowlistEntry).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !sslAllowlist.contains(value) else { newAllowlistEntry = ""; return }
        sslAllowlist.append(value)
        newAllowlistEntry = ""
        pushRulesToEngine()
    }

    public func removeAllowlist(at offsets: IndexSet) {
        sslAllowlist.remove(atOffsets: offsets)
        pushRulesToEngine()
    }

    public func removeAllowlistEntry(_ value: String) {
        sslAllowlist.removeAll { $0 == value }
        pushRulesToEngine()
    }

    // MARK: Proxy port

    /// Update the listen port (clamped to a sane range). Ignored while running —
    /// stop the proxy/capture first, then restart so the new port takes effect.
    public func setProxyPort(_ port: Int) {
        let clamped = min(65535, max(1024, port))
        guard clamped != proxyPort else { return }
        proxyPort = clamped
        pushRulesToEngine()   // persist + publish to the extension
        writeArtifacts()      // regenerate the profile with the new port
    }

    // MARK: Certificate-pinning detection

    /// Toggle auto-detection. Turning it off also drops any hosts already in
    /// tunnel mode so they're decrypted again on the next connection.
    public func setPinningDetection(_ enabled: Bool) {
        pinningDetectionEnabled = enabled
        if !enabled { engine.clearAllPinned() }
        pushRulesToEngine()
        refreshPinnedHosts()
    }

    /// Pull the auto-detected pinned hosts into the UI. On macOS the proxy shares
    /// our engine; on iOS the extension publishes them to the shared store.
    public func refreshPinnedHosts() {
        #if os(iOS)
        let hosts = configStore.loadPinnedHosts().sorted()
        if hosts != detectedPinnedHosts.map(\.host) {
            detectedPinnedHosts = hosts.map { PinnedHostInfo(host: $0, expiresAt: Date()) }
        }
        #else
        let hosts = engine.detectedPinnedHosts()
        if hosts != detectedPinnedHosts { detectedPinnedHosts = hosts }
        #endif
    }

    // MARK: - CA trust status

    /// Re-evaluates whether the HTTrail root CA is installed and trusted. macOS
    /// queries the System keychain directly; iOS can't, so it runs a loopback
    /// TLS probe (``CATrustProbe``) that only succeeds when the OS trusts the CA.
    public func checkCATrust() async {
        caCheckInProgress = true
        defer { caCheckInProgress = false }
        #if os(macOS)
        refreshCATrust()
        #else
        let trusted = await CATrustProbe.check(ca: ca)
        caTrusted = trusted
        statusMessage = trusted ? "Root CA is installed & trusted"
                                : "Root CA not trusted yet — install the profile and enable full trust"
        #endif
    }

    /// Force a detected host back into decryption (user trusts the CA there).
    /// Persisted in the shared config so it also reaches the iOS extension.
    public func forceDecryptHost(_ host: String) {
        if !forcedDecryptHosts.contains(host) { forcedDecryptHosts.append(host) }
        engine.clearPinned(host: host)
        pushRulesToEngine()
        refreshPinnedHosts()
    }

    /// Drop a host's detection so interception is retried on its next connection.
    public func retryPinnedHost(_ host: String) {
        forcedDecryptHosts.removeAll { $0 == host }
        engine.clearPinned(host: host)
        pushRulesToEngine()
        refreshPinnedHosts()
    }

    public func composeFromFlow(_ flow: Flow) {
        var request = APIRequest(name: flow.request.host, method: flow.request.method, url: flow.request.url)
        request.headers = flow.request.headers.map { KeyValueItem(name: $0.name, value: $0.value) }
        if !flow.request.body.isEmpty {
            request.rawBody = String(data: flow.request.body, encoding: .utf8) ?? ""
            request.bodyMode = .raw
        }
        requests.append(request)
        selectedRequestID = request.id
        mode = .compose
        statusMessage = "Composed request from captured flow"
    }

    // MARK: - Breakpoints

    private func awaitBreakpoint(_ event: BreakpointEvent) async -> BreakpointEdit? {
        await withCheckedContinuation { continuation in
            self.pendingBreakpoint = event
            self.breakpointBody = String(data: (event.phase == .response ? event.response?.body : event.request.body) ?? Data(), encoding: .utf8) ?? ""
            self.breakpointContinuation = continuation
        }
    }

    public func resolveBreakpoint(apply: Bool) {
        guard let event = pendingBreakpoint else { return }
        var edit: BreakpointEdit?
        if apply {
            if event.phase == .request {
                var req = event.request
                req.body = Data(breakpointBody.utf8)
                edit = BreakpointEdit(request: req)
            } else if var resp = event.response {
                resp.body = Data(breakpointBody.utf8)
                edit = BreakpointEdit(response: resp)
            }
        }
        pendingBreakpoint = nil
        breakpointContinuation?.resume(returning: edit)
        breakpointContinuation = nil
    }

    // MARK: - Realtime

    private func log(_ direction: RealtimeMessage.Direction, _ text: String) {
        wsMessages.append(RealtimeMessage(direction: direction, text: text))
    }

    public func connectRealtime() {
        wsMessages.removeAll()
        switch rtProtocol {
        case .webSocket: connectWebSocket()
        case .socketIO: connectSocketIO()
        case .sse: connectSSE()
        case .mqtt: connectMQTT()
        }
    }

    private func connectSSE() {
        guard let url = URL(string: wsURL) else { statusMessage = "Invalid SSE URL"; return }
        let client = SSEClient()
        sseTask = Task {
            self.wsConnected = true
            self.log(.system, "Connected (receive-only)")
            do {
                for try await event in client.connect(to: url) {
                    self.log(.incoming, event.event == "message" ? event.data : "\(event.event): \(event.data)")
                }
                self.log(.system, "Stream ended")
            } catch {
                self.log(.system, "Error: \(error.localizedDescription)")
            }
            self.wsConnected = false
        }
    }

    private func connectWebSocket() {
        guard let url = URL(string: wsURL) else { statusMessage = "Invalid WebSocket URL"; return }
        let client = WebSocketClient()
        self.webSocket = client
        Task {
            for await event in client.connect(to: url) {
                switch event {
                case .connected: self.wsConnected = true; self.log(.system, "Connected")
                case .text(let t): self.log(.incoming, t)
                case .binary(let d): self.log(.incoming, "<\(d.count) bytes binary>")
                case .disconnected: self.wsConnected = false; self.log(.system, "Disconnected")
                case .error(let m): self.wsConnected = false; self.log(.system, "Error: \(m)")
                }
            }
            self.wsConnected = false
        }
    }

    private func connectSocketIO() {
        guard let url = URL(string: wsURL) else { statusMessage = "Invalid Socket.IO URL"; return }
        let client = SocketIOClient()
        self.socketIO = client
        Task {
            for await event in client.connect(to: url) {
                switch event {
                case .connected: self.wsConnected = true; self.log(.system, "Connected")
                case .message(let name, let payload): self.log(.incoming, "\(name): \(payload)")
                case .disconnected: self.wsConnected = false; self.log(.system, "Disconnected")
                case .error(let m): self.wsConnected = false; self.log(.system, "Error: \(m)")
                }
            }
            self.wsConnected = false
        }
    }

    private func connectMQTT() {
        let client = MQTTClient()
        self.mqtt = client
        let topic = mqttTopic
        Task {
            for await event in client.connect(host: mqttHost, port: mqttPort) {
                switch event {
                case .connected:
                    self.wsConnected = true
                    self.log(.system, "Connected — subscribing to \(topic)")
                    client.subscribe(topic: topic)
                case .message(let t, let p): self.log(.incoming, "[\(t)] \(p)")
                case .disconnected: self.wsConnected = false; self.log(.system, "Disconnected")
                case .error(let m): self.wsConnected = false; self.log(.system, "Error: \(m)")
                }
            }
            self.wsConnected = false
        }
    }

    public func sendRealtimeMessage() {
        guard !wsOutgoing.isEmpty else { return }
        switch rtProtocol {
        case .webSocket:
            webSocket?.send(text: wsOutgoing)
            log(.outgoing, wsOutgoing)
        case .socketIO:
            socketIO?.emit(event: sioEvent, payload: wsOutgoing)
            log(.outgoing, "\(sioEvent): \(wsOutgoing)")
        case .sse:
            log(.system, "SSE is receive-only")
        case .mqtt:
            mqtt?.publish(topic: mqttTopic, message: wsOutgoing)
            log(.outgoing, "[\(mqttTopic)] \(wsOutgoing)")
        }
        wsOutgoing = ""
    }

    public func disconnectRealtime() {
        webSocket?.close(); webSocket = nil
        socketIO?.close(); socketIO = nil
        mqtt?.close(); mqtt = nil
        sseTask?.cancel(); sseTask = nil
        wsConnected = false
    }

    // MARK: - Local test server

    /// Human-readable endpoint hint shown while the test server is running.
    public var testServerHint: String {
        guard testServerRunning else { return "" }
        switch rtProtocol {
        case .mqtt: return "echo + ping/date/uptime · 127.0.0.1:\(testServerMQTTPort)"
        default: return "echo + ping/date/uptime · \(wsURL)"
        }
    }

    public func toggleTestServer() {
        guard !testServerBusy else { return }
        testServerRunning ? stopTestServer() : startTestServer()
    }

    private func startTestServer() {
        testServerBusy = true
        savedRealtimeEndpoints = (wsURL, mqttHost, mqttPort)
        statusMessage = "Starting local realtime test server..."

        Task { [weak self] in
            let server = RealtimeTestServer()
            do {
                let ports = try await Task.detached(priority: .userInitiated) {
                    try server.start()
                }.value
                guard let self else {
                    Task.detached(priority: .utility) { server.stop() }
                    return
                }
                self.testServer = server
                self.testServerHTTPPort = ports.httpPort
                self.testServerMQTTPort = ports.mqttPort
                self.testServerRunning = true
                self.testServerBusy = false
                self.applyLocalTestEndpoints()
                self.statusMessage = "Local realtime test server started on 127.0.0.1"
            } catch {
                self?.testServerBusy = false
                self?.savedRealtimeEndpoints = nil
                self?.statusMessage = "Test server failed: \(error.localizedDescription)"
            }
        }
    }

    private func stopTestServer() {
        let server = testServer
        disconnectRealtime()
        testServerBusy = true
        testServer = nil
        testServerRunning = false
        if let saved = savedRealtimeEndpoints {
            wsURL = saved.wsURL
            mqttHost = saved.mqttHost
            mqttPort = saved.mqttPort
            savedRealtimeEndpoints = nil
        }
        statusMessage = "Stopping local realtime test server..."

        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                server?.stop()
            }.value
            self?.testServerBusy = false
            self?.statusMessage = "Local realtime test server stopped"
        }
    }

    /// Point the current protocol's endpoint field(s) at the local test server.
    private func applyLocalTestEndpoints() {
        guard testServerRunning else { return }
        switch rtProtocol {
        case .webSocket: wsURL = "ws://127.0.0.1:\(testServerHTTPPort)/ws"
        case .socketIO:  wsURL = "http://127.0.0.1:\(testServerHTTPPort)"
        case .sse:       wsURL = "http://127.0.0.1:\(testServerHTTPPort)/sse"
        case .mqtt:      mqttHost = "127.0.0.1"; mqttPort = testServerMQTTPort
        }
    }

    private func applyDefaultRealtimeEndpoint(afterSwitchingFrom oldProtocol: RealtimeProtocol) {
        switch rtProtocol {
        case .webSocket:
            if wsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                wsURL = Self.defaultWebSocketURL
            }
        case .socketIO:
            let trimmed = wsURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldProtocol == .webSocket,
               trimmed == Self.defaultWebSocketURL || Self.legacyDefaultWebSocketURLs.contains(trimmed) {
                wsURL = ""
            }
        case .sse, .mqtt:
            break
        }
    }
}

public struct ScriptOutput {
    public var logs: [String] = []
    public var tests: [(name: String, passed: Bool, message: String?)] = []
    public init() {}
}

public struct RealtimeMessage: Identifiable {
    public enum Direction { case incoming, outgoing, system }
    public let id = UUID()
    public let direction: Direction
    public let text: String
    public let timestamp = Date()
    public init(direction: Direction, text: String) {
        self.direction = direction
        self.text = text
    }
}

#if DEBUG
public extension AppModel {
    /// Populate the model with rich, realistic sample data so the App Store
    /// screenshots show a working app. Invoked only behind the `-htDemo 1`
    /// launch argument (see the iOS `RootTabView`); never runs in normal use.
    func seedDemoData() {
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

        // MARK: Capture — a session of decrypted HTTPS flows
        func flow(_ method: String, _ urlString: String, status: Int, type: String,
                  reqBody: String = "", respBody: String, ms: Int,
                  secure: Bool = true, t: TimeInterval, sid: UUID) -> Flow {
            let url = URL(string: urlString)!
            let host = url.host ?? ""
            let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
            var reqHeaders = [
                HeaderPair(name: "Host", value: host),
                HeaderPair(name: "Accept", value: "application/json"),
                HeaderPair(name: "User-Agent", value: "MyApp/2.4 (iPhone; iOS 18.5)"),
            ]
            if !reqBody.isEmpty {
                reqHeaders.append(HeaderPair(name: "Content-Type", value: "application/json"))
                reqHeaders.append(HeaderPair(name: "Authorization", value: "Bearer eyJhbGci••••••"))
            }
            let req = CapturedRequest(
                method: method, url: urlString, scheme: url.scheme ?? "https",
                host: host, port: url.port ?? (secure ? 443 : 80), path: path,
                httpVersion: "HTTP/2", headers: reqHeaders,
                body: Data(reqBody.utf8), timestamp: ago(t))
            let resp = CapturedResponse(
                statusCode: status, reasonPhrase: "", httpVersion: "HTTP/2",
                headers: [
                    HeaderPair(name: "Content-Type", value: type),
                    HeaderPair(name: "Content-Length", value: "\(respBody.utf8.count)"),
                    HeaderPair(name: "Server", value: "cloudflare"),
                    HeaderPair(name: "Cache-Control", value: "no-store"),
                ],
                body: Data(respBody.utf8), timestamp: ago(t - Double(ms) / 1000))
            return Flow(request: req, response: resp, state: .completed,
                        startedAt: ago(t), endedAt: ago(t - Double(ms) / 1000),
                        secure: secure, sessionID: sid)
        }

        let sid = UUID()
        let demoFlows: [Flow] = [
            flow("POST", "https://api.stripe.com/v1/payment_intents", status: 200,
                 type: "application/json", reqBody: "amount=4200&currency=usd",
                 respBody: #"{"id":"pi_3Pk2","status":"succeeded","amount":4200}"#, ms: 312, t: 2, sid: sid),
            flow("GET", "https://api.github.com/user/repos?per_page=30", status: 200,
                 type: "application/json",
                 respBody: #"[{"name":"htrail","stars":214},{"name":"core","stars":88}]"#, ms: 142, t: 6, sid: sid),
            flow("POST", "https://api.openai.com/v1/chat/completions", status: 200,
                 type: "application/json", reqBody: #"{"model":"gpt-5.5"}"#,
                 respBody: #"{"id":"chatcmpl-9","choices":[{"message":{"role":"assistant"}}]}"#, ms: 884, t: 11, sid: sid),
            flow("GET", "https://api.spotify.com/v1/me/player", status: 401,
                 type: "application/json",
                 respBody: #"{"error":{"status":401,"message":"The access token expired"}}"#, ms: 73, t: 17, sid: sid),
            flow("PUT", "https://graph.facebook.com/v19.0/me/photos", status: 200,
                 type: "application/json", respBody: #"{"id":"10239","post_id":"10239_55"}"#, ms: 421, t: 23, sid: sid),
            flow("GET", "https://cdn.jsdelivr.net/npm/chart.js/dist/chart.min.js", status: 200,
                 type: "application/javascript", respBody: "/*! Chart.js v4.4 */ ...", ms: 58, t: 29, sid: sid),
            flow("GET", "https://api.weather.gov/points/37.77,-122.41", status: 404,
                 type: "application/json", respBody: #"{"status":404,"detail":"Not found"}"#, ms: 96, t: 34, sid: sid),
            flow("POST", "https://www.googleapis.com/oauth2/v4/token", status: 200,
                 type: "application/json", reqBody: "grant_type=refresh_token",
                 respBody: #"{"access_token":"ya29.a0","expires_in":3599}"#, ms: 188, t: 41, sid: sid),
        ]
        let session = CaptureSession(id: sid, name: "Capture 2026-06-22 10:55:58",
                                     startedAt: ago(120), endedAt: nil, recordCount: demoFlows.count)
        sessions = [session]
        activeSessionID = sid
        viewingSessionID = sid
        flows = demoFlows
        deviceIP = "192.168.1.24"
        proxyPort = 9090
        capturePath = [session]
        #if os(iOS)
        // Suppress the Local Network disclosure sheet so it never overlays shots.
        bonjourDisclosureShown = true
        #endif

        // MARK: Compose — a worked API request + response + history
        var req = APIRequest(
            name: "Create payment", method: "POST",
            url: "https://api.stripe.com/v1/payment_intents",
            queryParams: [],
            headers: [KeyValueItem(name: "Idempotency-Key", value: "a1b2c3d4")],
            bodyMode: .json,
            rawBody: "{\n  \"amount\": 4200,\n  \"currency\": \"usd\",\n  \"description\": \"Order #1042\"\n}",
            contentType: "application/json")
        req.auth = AuthConfig(); req.auth.type = .bearer; req.auth.token = "sk_live_51H••••••"
        requests = [req]
        selectedRequestID = req.id
        responsesByRequest[req.id] = APIResponse(
            statusCode: 200,
            headers: [HeaderPair(name: "Content-Type", value: "application/json"),
                      HeaderPair(name: "Request-Id", value: "req_3Pk2N9")],
            body: Data(#"{"id":"pi_3Pk2N9","object":"payment_intent","amount":4200,"currency":"usd","status":"succeeded","created":1718000000}"#.utf8),
            durationMS: 312)
        history = [
            HistoryEntry(request: req, statusCode: 200, durationMS: 312, timestamp: ago(40)),
            HistoryEntry(request: APIRequest(name: "List repos", method: "GET",
                url: "https://api.github.com/user/repos"), statusCode: 200, durationMS: 142, timestamp: ago(220)),
            HistoryEntry(request: APIRequest(name: "Refresh token", method: "POST",
                url: "https://www.googleapis.com/oauth2/v4/token"), statusCode: 200, durationMS: 188, timestamp: ago(600)),
        ]

        // MARK: Realtime — a live WebSocket session
        rtProtocol = .webSocket
        wsURL = "wss://stream.example.com/v1/ticker"
        wsConnected = true
        wsMessages = [
            RealtimeMessage(direction: .system, text: "Connected to wss://stream.example.com/v1/ticker"),
            RealtimeMessage(direction: .outgoing, text: #"{"action":"subscribe","channel":"BTC-USD"}"#),
            RealtimeMessage(direction: .incoming, text: #"{"type":"ack","channel":"BTC-USD"}"#),
            RealtimeMessage(direction: .incoming, text: #"{"price":"67421.50","ts":1718000041}"#),
            RealtimeMessage(direction: .incoming, text: #"{"price":"67430.10","ts":1718000043}"#),
            RealtimeMessage(direction: .outgoing, text: #"{"action":"ping"}"#),
            RealtimeMessage(direction: .incoming, text: #"{"type":"pong"}"#),
        ]

        // MARK: Rules — a representative intercept rule set
        func rule(_ name: String, _ kind: RuleKind, _ pattern: String,
                  enabled: Bool = true) -> InterceptRule {
            var r = InterceptRule(); r.name = name; r.kind = kind
            r.urlPattern = pattern; r.enabled = enabled; return r
        }
        var blockRule = rule("Block analytics", .block, "*://*.google-analytics.com/*")
        blockRule.blockStatus = 403
        var mapRule = rule("Staging API", .mapRemote, "*://api.example.com/*")
        mapRule.remoteHost = "staging.example.com"
        var throttleRule = rule("Slow 3G", .throttle, "*", enabled: false)
        throttleRule.throttleMS = 400; throttleRule.bytesPerSecond = 50_000
        rules = [blockRule, mapRule,
                 rule("Mock /me", .mapLocal, "*://api.example.com/me"),
                 throttleRule]
        sslAllowlist = ["api.stripe.com", "api.github.com", "*.openai.com"]
    }
}
#endif
