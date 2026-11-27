import Foundation
import NetworkExtension

/// Remote-build entry point. The official WireGuard adapter owns transport;
/// legacy local-capture profiles are rejected instead of silently passing data.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnel: PurelineWireGuardTunnel?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard PurelineWireGuardTunnel.isSelected(protocolConfiguration) else {
            completionHandler(NSError(
                domain: "Pureline.Remote", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "This edition requires a remote WireGuard profile. Open Image Filter and import the profile supplied by your filtering server."]
            ))
            return
        }
        let remote = PurelineWireGuardTunnel(provider: self)
        tunnel = remote
        remote.start(completion: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        guard let tunnel else { completionHandler(); return }
        tunnel.stop { [weak self] in
            self?.tunnel = nil
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        guard let tunnel else { completionHandler?(nil); return }
        tunnel.message(messageData, completion: completionHandler)
    }
}
