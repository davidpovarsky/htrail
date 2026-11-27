import Foundation
import NetworkExtension
import WireGuardKit

/// Separate from HTTrail's proxy-only path. This mode actually encrypts packets
/// to the selected remote server; it never starts local ML or capture logging.
final class PurelineWireGuardTunnel {
    private let provider: NEPacketTunnelProvider
    private lazy var adapter = WireGuardAdapter(with: provider) { _, _ in
        // Upstream logs can contain peer/network details. Expose sanitized
        // lifecycle errors and counters only, never the raw backend messages.
    }

    init(provider: NEPacketTunnelProvider) { self.provider = provider }

    static func isSelected(_ configuration: NEVPNProtocol) -> Bool {
        guard let proto = configuration as? NETunnelProviderProtocol else { return false }
        return proto.providerConfiguration?[PurelineWGContract.modeKey] as? String == PurelineWGContract.remoteMode
    }

    func start(completion: @escaping (Error?) -> Void) {
        #if targetEnvironment(simulator)
        completion(Self.failure("An iOS Simulator cannot run a packet-tunnel VPN. Use the isolated Mac test route or a physical device."))
        #else
        do {
            guard let proto = provider.protocolConfiguration as? NETunnelProviderProtocol,
                  let reference = proto.passwordReference else {
                throw Self.failure("The secure WireGuard profile reference is missing.")
            }
            let profile = try PurelineWGProfile.parse(PurelineWGKeychain.load(reference))
            adapter.start(tunnelConfiguration: profile.tunnel) { error in
                guard let error else { completion(nil); return }
                switch error {
                case .cannotLocateTunnelFileDescriptor:
                    completion(Self.failure("The system did not provide a packet-tunnel interface."))
                case .dnsResolution:
                    completion(Self.failure("The VPN server endpoint could not be resolved."))
                case .setNetworkSettings:
                    completion(Self.failure("iOS could not apply the WireGuard network settings."))
                case .startWireGuardBackend:
                    completion(Self.failure("The WireGuard backend could not start."))
                case .invalidState:
                    completion(Self.failure("WireGuard is already changing state."))
                }
            }
        } catch { completion(error) }
        #endif
    }

    func stop(completion: @escaping () -> Void) {
        #if targetEnvironment(simulator)
        completion()
        #else
        adapter.stop { _ in completion() }
        #endif
    }

    func message(_ data: Data, completion: ((Data?) -> Void)?) {
        guard data == PurelineWGContract.statisticsMessage else { completion?(nil); return }
        #if targetEnvironment(simulator)
        completion?(nil)
        #else
        adapter.getRuntimeConfiguration { runtime in
            guard let runtime else { completion?(nil); return }
            completion?(try? JSONEncoder().encode(PurelineWGStatistics.parse(runtime)))
        }
        #endif
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Pureline.WireGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
