import Foundation
import Network

/// Result of probing a capture path.
public enum CaptureHealth: Equatable, Sendable {
    case healthy
    case unreachable    // can't open a TCP connection to the proxy
    case tlsUntrusted   // reachable, but HTTPS through it fails to validate (Mac CA not trusted)
    case unknown
}

/// Coarse VPN tunnel phase, decoupled from NetworkExtension so the status
/// combiner stays pure and testable in the cross-platform core.
public enum VPNPhase: Sendable, Equatable {
    case off          // disconnected / invalid
    case connecting   // connecting
    case connected    // connected
    case reconnecting // reasserting (network changed; tunnel re-establishing)
}

/// The single user-facing capture status, combining tunnel state with the
/// Mac-proxy / on-device-engine health. This is what the iPhone banner renders;
/// keeping the combination here (not in the view) makes the logic testable.
public enum CaptureLiveStatus: Equatable, Sendable {
    case stopped            // not capturing
    case starting           // tunnel coming up / first probe pending
    case reconnecting       // tunnel re-establishing after a network change
    case capturingLocal     // on-device capture, extension engine alive
    case capturingRemote    // remote Mac capture, healthy end-to-end
    case macUnreachable     // tunnel up but the Mac proxy can't be reached
    case macUntrusted       // Mac reachable but its CA isn't trusted (HTTPS fails)
    case extensionStalled   // on-device, tunnel up but the capture engine is silent
}

/// Lightweight reachability/health probing for a remote proxy target.
public enum CaptureHealthCheck {

    /// Fold the tunnel phase together with the proxy/engine health into the one
    /// status the UI shows. `targetIsRemote` selects the remote-Mac vs on-device
    /// interpretation of `health`/`engineLive`.
    public static func liveStatus(vpn: VPNPhase, targetIsRemote: Bool,
                                  health: CaptureHealth, engineLive: Bool) -> CaptureLiveStatus {
        switch vpn {
        case .off:
            return .stopped
        case .connecting:
            return .starting
        case .reconnecting:
            return .reconnecting
        case .connected:
            if targetIsRemote {
                switch health {
                case .healthy:       return .capturingRemote
                case .unreachable:   return .macUnreachable
                case .tlsUntrusted:  return .macUntrusted
                case .unknown:       return .starting
                }
            } else {
                if !engineLive { return .extensionStalled }
                // On-device MITM also needs our CA trusted on this device.
                return health == .tlsUntrusted ? .macUntrusted : .capturingLocal
            }
        }
    }

    /// True if a TCP connection to `host:port` becomes ready within `timeout`.
    public static func reachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var done = false
            func finish(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                conn.cancel()
                continuation.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Probes whether HTTPS works through the current network path (the VPN
    /// tunnel → remote proxy). A success means the remote proxy's CA is trusted;
    /// a TLS/cert error means it is reachable but untrusted; a connection error
    /// means it is unreachable. Used to confirm Mac-CA trust after starting a
    /// remote capture, instead of assuming reachability implies trust.
    public static func tlsProbe(
        url: URL = URL(string: "https://www.apple.com/library/test/success.html")!,
        timeout: TimeInterval
    ) async -> CaptureHealth {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            return response is HTTPURLResponse ? .healthy : .unknown
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .secureConnectionFailed, .clientCertificateRejected:
                return .tlsUntrusted
            case .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return .unreachable
            default:
                return .unknown
            }
        } catch {
            return .unknown
        }
    }
}
