import Foundation
import NetworkExtension
import Combine
import HTTrailCore

/// App-side control of the HTTrail Packet Tunnel network extension: this is the
/// "VPN provisioning" surface. It loads/creates the `NETunnelProviderManager`,
/// saves it (which is what triggers the system "HTTrail would like to add VPN
/// configurations" consent prompt), and starts/stops the tunnel that funnels the
/// device's HTTP/HTTPS traffic through the on-device HTTrail proxy.
@MainActor
final class VPNController: ObservableObject {
    /// Must match the extension target's bundle identifier.
    static let providerBundleID = "com.1moby.httrail.PacketTunnel"

    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?
    @Published private(set) var hasConfiguration = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            Task { @MainActor in self?.status = conn.status }
        }
        Task { await reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pollTask?.cancel()
    }

    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }

    /// Coarse tunnel phase for the shared status combiner.
    var phase: VPNPhase {
        switch status {
        case .connected: return .connected
        case .connecting: return .connecting
        case .reasserting: return .reconnecting
        default: return .off
        }
    }

    /// Reconcile `status` from the live connection on a timer. NEVPNStatusDidChange
    /// can be missed while the app is suspended; this catches transitions (e.g. a
    /// background drop/reconnect) the moment the app is foregrounded and capturing.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let s = self?.manager?.connection.status, s != self?.status {
                    self?.status = s
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    var statusText: String {
        switch status {
        case .invalid: return "Not configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Capturing (VPN on)"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown"
        }
    }

    /// Loads the existing saved configuration, if any, and reflects its status.
    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            self.manager = managers.first
            self.hasConfiguration = managers.first != nil
            self.status = managers.first?.connection.status ?? .invalid
        } catch {
            self.manager = nil
            self.hasConfiguration = false
            self.status = .invalid
        }
    }

    /// Starts capture only from an existing user-approved tunnel configuration.
    /// The UI installs that configuration through the profile flow before this runs.
    @discardableResult
    func startCapture(port: Int) async -> Bool {
        lastError = nil
        await reload()
        if let manager {
            startPolling()
            do {
                try await manager.loadFromPreferences()
                // Keep the tunnel alive across app-switching / network blips: without
                // an on-demand "connect" rule iOS tears it down when the app is
                // backgrounded and nothing brings it back (the proxy "flaps").
                if !manager.isEnabled || !manager.isOnDemandEnabled || (manager.onDemandRules?.isEmpty ?? true) {
                    manager.isEnabled = true
                    manager.isOnDemandEnabled = true
                    manager.onDemandRules = [Self.connectRule()]
                    // Best-effort: a profile-managed config may reject app edits —
                    // proceed to start the tunnel regardless.
                    do {
                        try await manager.saveToPreferences()
                        try await manager.loadFromPreferences()
                    } catch {
                        // Profile-managed config rejected the edit; start anyway.
                    }
                }
                try manager.connection.startVPNTunnel()
                status = manager.connection.status
                return true
            } catch {
                lastError = error.localizedDescription
                return false
            }
        } else {
            lastError = "Install the HTTrail VPN + CA profile before starting capture."
            stopPolling()
            return false
        }
    }

    /// On-demand rule that keeps the capture tunnel connected on any interface.
    private static func connectRule() -> NEOnDemandRule {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        return rule
    }

    /// Saves (provisioning consent prompt) the tunnel config pointed at the
    /// on-device proxy port, then starts it.
    @discardableResult
    func enable(port: Int) async -> Bool {
        lastError = nil
        startPolling()
        let manager = self.manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "HTTrail (on-device)"
        proto.providerConfiguration = ["port": port]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "HTTrail Capture"
        manager.isEnabled = true
        // On-demand so the tunnel persists across app-switching / network changes.
        manager.isOnDemandEnabled = true
        manager.onDemandRules = [Self.connectRule()]

        do {
            try await manager.saveToPreferences()
            // Reload so the connection object is valid after the save round-trip.
            try await manager.loadFromPreferences()
            self.manager = manager
            self.hasConfiguration = true
            try manager.connection.startVPNTunnel()
            status = manager.connection.status
            return true
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
    }

    /// Stops the tunnel (leaves the configuration installed for next time). Must
    /// clear on-demand first, otherwise iOS immediately reconnects per the rule.
    func disable() {
        stopPolling()
        Task { @MainActor in
            if let manager {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = []
                try? await manager.saveToPreferences()
            }
            manager?.connection.stopVPNTunnel()
        }
    }
}
