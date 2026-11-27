import Foundation
import NetworkExtension
import Combine

@MainActor
final class PurelineWGController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var endpoint = ""
    @Published private(set) var routesIPv6 = false
    @Published private(set) var hasProfile = false
    @Published private(set) var busy = false
    @Published private(set) var statistics = PurelineWGStatistics()
    @Published var error: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    static var supportsTunnel: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let self, connection === self.manager?.connection else { return }
                self.status = connection.status
                if connection.status != .connected { self.statistics = PurelineWGStatistics() }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isActive: Bool { [.connecting, .connected, .reasserting, .disconnecting].contains(status) }
    var statusLabel: String {
        guard Self.supportsTunnel else { return "Physical device required for VPN" }
        switch status {
        case .invalid: return "No remote profile"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "VPN connected"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        @unknown default: return "Unknown VPN state"
        }
    }

    func reload() async {
        guard Self.supportsTunnel else { return }
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first(where: Self.owns)
            status = manager?.connection.status ?? .invalid
            hasProfile = manager != nil
            let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol
            endpoint = proto?.serverAddress ?? ""
            routesIPv6 = proto?.providerConfiguration?["routesIPv6"] as? Bool ?? false
        } catch { self.error = "The saved VPN configuration could not be loaded. \(error.localizedDescription)" }
    }

    func install(_ source: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let profile = try PurelineWGProfile.parse(source)
            guard Self.supportsTunnel else {
                throw PurelineWGProfile.ProfileError.invalid("The profile is valid. Install it on a physical iPhone or iPad to enable the VPN.")
            }
            await reload()
            guard !isActive else { throw PurelineWGProfile.ProfileError.invalid("Disconnect the VPN before replacing its profile.") }
            let selected = manager ?? NETunnelProviderManager()
            let oldReference = (selected.protocolConfiguration as? NETunnelProviderProtocol)?.passwordReference
            let reference = try PurelineWGKeychain.save(profile.source)
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = PurelineWGContract.providerID
            proto.serverAddress = profile.endpoint
            proto.passwordReference = reference
            proto.disconnectOnSleep = false
            proto.providerConfiguration = [
                PurelineWGContract.modeKey: PurelineWGContract.remoteMode,
                "routesIPv6": profile.routesIPv6
            ]
            selected.protocolConfiguration = proto
            selected.localizedDescription = "Pureline Remote · WireGuard"
            selected.isEnabled = true
            selected.isOnDemandEnabled = false
            selected.onDemandRules = []
            var persisted = false
            do {
                try await selected.saveToPreferences()
                persisted = true
                try await selected.loadFromPreferences()
                manager = selected
                if let oldReference { PurelineWGKeychain.delete(oldReference) }
                await reload()
            } catch {
                // If the preferences save succeeded, the new reference is live
                // even when the subsequent reload fails.
                if !persisted { PurelineWGKeychain.delete(reference) }
                await reload()
                throw error
            }
        } catch { self.error = error.localizedDescription }
    }

    func connect() async {
        guard Self.supportsTunnel, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            await reload()
            guard let selected = manager else { throw PurelineWGProfile.ProfileError.invalid("Import a WireGuard profile first.") }
            // A local on-demand tunnel must not immediately reconnect over the
            // chosen remote one. Touch only this app's own local configuration.
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            for local in all where !Self.owns(local) {
                guard let proto = local.protocolConfiguration as? NETunnelProviderProtocol,
                      proto.providerBundleIdentifier == PurelineWGContract.providerID else { continue }
                if local.isOnDemandEnabled {
                    local.isOnDemandEnabled = false
                    local.onDemandRules = []
                    try await local.saveToPreferences()
                }
                if [.connecting, .connected, .reasserting].contains(local.connection.status) {
                    local.connection.stopVPNTunnel()
                    for _ in 0..<30 {
                        if [.invalid, .disconnected].contains(local.connection.status) { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard [.invalid, .disconnected].contains(local.connection.status) else {
                        throw PurelineWGProfile.ProfileError.invalid("Local capture is still stopping. Try again when it is disconnected.")
                    }
                }
            }
            try await selected.loadFromPreferences()
            selected.isEnabled = true
            selected.isOnDemandEnabled = false
            selected.onDemandRules = []
            try await selected.saveToPreferences()
            try await selected.loadFromPreferences()
            try selected.connection.startVPNTunnel()
            status = selected.connection.status
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let manager else { return }
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        do { try await manager.saveToPreferences() } catch { self.error = error.localizedDescription }
        manager.connection.stopVPNTunnel()
        status = manager.connection.status
        statistics = PurelineWGStatistics()
    }

    func refreshStatistics() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        status = session.status
        guard status == .connected else { return }
        do {
            try session.sendProviderMessage(PurelineWGContract.statisticsMessage) { [weak self] data in
                guard let data, let counters = try? JSONDecoder().decode(PurelineWGStatistics.self, from: data) else { return }
                Task { @MainActor in self?.statistics = counters }
            }
        } catch { self.error = "Tunnel counters are unavailable." }
    }

    private static func owns(_ manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == PurelineWGContract.providerID
            && proto.providerConfiguration?[PurelineWGContract.modeKey] as? String == PurelineWGContract.remoteMode
    }
}
