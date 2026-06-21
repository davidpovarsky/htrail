import Foundation

/// The proxy configuration that must survive app relaunch **and** cross the iOS
/// process boundary between the app (which the user configures) and the Packet
/// Tunnel extension (which actually runs the MITM proxy). On macOS the proxy
/// runs in-process, so this is "just" persistence; on iOS it's the bridge that
/// makes interception rules, the SSL allowlist, the port, and pinning detection
/// configured in the UI actually take effect inside the extension's engine.
public struct SharedConfig: Codable, Sendable, Equatable {
    public var rules: [InterceptRule] = []
    public var sslAllowlist: [String] = []
    public var proxyPort: Int = 9090
    public var pinningEnabled: Bool = true
    /// Hosts the user forced back into decryption despite pinning detection.
    public var forcedDecryptHosts: [String] = []
    /// macOS: advertise this running proxy over Bonjour for iOS discovery.
    public var bonjourEnabled: Bool = false
    /// iOS extension: when non-nil, forward to this remote proxy (a Mac) instead
    /// of running a local on-device proxy.
    public var remoteProxyHost: String?
    public var remoteProxyPort: Int?
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([InterceptRule].self, forKey: .rules) ?? []
        sslAllowlist = try c.decodeIfPresent([String].self, forKey: .sslAllowlist) ?? []
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 9090
        pinningEnabled = try c.decodeIfPresent(Bool.self, forKey: .pinningEnabled) ?? true
        forcedDecryptHosts = try c.decodeIfPresent([String].self, forKey: .forcedDecryptHosts) ?? []
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? false
        remoteProxyHost = try c.decodeIfPresent(String.self, forKey: .remoteProxyHost)
        remoteProxyPort = try c.decodeIfPresent(Int.self, forKey: .remoteProxyPort)
    }
}

/// What the capture engine is actually running right now. The iOS proxy lives in
/// the extension (another process), so the app can't introspect its engine
/// directly — the extension publishes this snapshot and the app displays it to
/// confirm rules/allowlist are live ("are my rules wired?").
public struct EngineStatus: Codable, Sendable, Equatable {
    public var ruleCount = 0
    public var allowlistCount = 0
    public var pinnedCount = 0
    public var port = 0
    public var updatedAt = Date()
    public init() {}
}

/// Reads/writes ``SharedConfig`` (and the back-channels of auto-detected pinned
/// hosts + engine status) as JSON in the shared support directory. On iOS
/// `AppPaths` resolves to the App Group container, so the app and extension see
/// the same files.
public final class SharedConfigStore: @unchecked Sendable {
    private let configURL: URL
    private let pinnedURL: URL
    private let statusURL: URL
    private let queue = DispatchQueue(label: "com.httrail.sharedconfig")

    public init() {
        let dir = AppPaths.supportDirectory
        configURL = dir.appendingPathComponent("shared-config.json")
        pinnedURL = dir.appendingPathComponent("pinned-hosts.json")
        statusURL = dir.appendingPathComponent("engine-status.json")
    }

    // MARK: Config

    public func load() -> SharedConfig? {
        queue.sync {
            guard let data = try? Data(contentsOf: configURL) else { return nil }
            return try? JSONDecoder().decode(SharedConfig.self, from: data)
        }
    }

    public func save(_ config: SharedConfig) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(config) else { return }
            try? data.write(to: configURL, options: .atomic)
        }
    }

    // MARK: Pinned-host back-channel (extension → app)

    /// The extension publishes the hosts its engine has auto-tunneled so the app
    /// (a different process on iOS) can display them.
    public func savePinnedHosts(_ hosts: [String]) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(hosts) else { return }
            try? data.write(to: pinnedURL, options: .atomic)
        }
    }

    public func loadPinnedHosts() -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: pinnedURL) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
    }

    // MARK: Engine status back-channel (extension → app)

    public func saveEngineStatus(_ status: EngineStatus) {
        queue.sync {
            guard let data = try? JSONEncoder().encode(status) else { return }
            try? data.write(to: statusURL, options: .atomic)
        }
    }

    public func loadEngineStatus() -> EngineStatus? {
        queue.sync {
            guard let data = try? Data(contentsOf: statusURL) else { return nil }
            return try? JSONDecoder().decode(EngineStatus.self, from: data)
        }
    }
}
