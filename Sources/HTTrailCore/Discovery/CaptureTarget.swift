import Foundation

/// Where iOS capture is decrypted/recorded.
public enum CaptureTarget: Hashable, Sendable {
    case thisDevice
    case remote(DiscoveredProxy)
    case manual(host: String, port: Int)

    /// The remote proxy endpoint, or nil for on-device capture.
    public var remoteHostPort: (host: String, port: Int)? {
        switch self {
        case .thisDevice: return nil
        case .remote(let p): return (p.host, p.port)
        case .manual(let host, let port): return (host, port)
        }
    }

    public var label: String {
        switch self {
        case .thisDevice: return "This Device"
        case .remote(let p): return p.name
        case .manual(let host, let port): return "Manual \(host):\(port)"
        }
    }
}
