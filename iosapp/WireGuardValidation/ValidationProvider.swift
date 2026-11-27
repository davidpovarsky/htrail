import NetworkExtension

/// Focused host for the exact production remote adapter. It does not include
/// HTTrail/CoreML and is identified as a validation app in its build receipt.
final class PurelineWGValidationProvider: NEPacketTunnelProvider {
    private var remote: PurelineWireGuardTunnel?
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let engine = PurelineWireGuardTunnel(provider: self)
        remote = engine
        engine.start(completion: completionHandler)
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        guard let engine = remote else { completionHandler(); return }
        remote = nil
        engine.stop(completion: completionHandler)
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let engine = remote else { completionHandler?(nil); return }
        engine.message(messageData, completion: completionHandler)
    }
}
