import Foundation

/// Downstream-only switch shared by the iOS host app and Packet Tunnel process.
/// Defaults to off so adding the image-filter integration does not change the
/// behavior or memory footprint of an existing HTTrail capture session until the
/// user explicitly opts in.
public enum DirectImageFilterSettings {
    private static let enabledKey = "downstream.directImageFilteringEnabled"

    public static var isEnabled: Bool {
        get { sharedDefaults.bool(forKey: enabledKey) }
        set { sharedDefaults.set(newValue, forKey: enabledKey) }
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }
}
