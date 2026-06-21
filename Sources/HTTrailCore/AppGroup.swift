import Foundation

/// Shared container used so the iOS app and its Packet Tunnel network extension
/// (two separate processes) can agree on the **same root CA** and exchange
/// captured flows. The extension runs the MITM proxy in the background; the app
/// only renders. Both must read the identical CA so leaf certs chain to the root
/// the user trusted on the device.
public enum AppGroup {
    /// Keep in sync with the `com.apple.security.application-groups` entitlement
    /// in `iosapp/HTTrailiOS.entitlements` and `iosapp/PacketTunnel/*.entitlements`.
    public static let identifier = "group.com.1moby.httrail"

    /// The shared group container, or `nil` when the entitlement is absent
    /// (e.g. on macOS or in unit tests) — callers fall back to per-app storage.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Newline-delimited JSON file the extension appends captured `Flow`s to and
    /// the app tails. Lives in the shared container so it survives app suspension.
    public static func capturedFlowsURL() -> URL? {
        containerURL()?.appendingPathComponent("captured-flows.ndjson")
    }
}
