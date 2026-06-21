import Foundation

/// Standard on-disk locations for HTTrail's persistent state.
public enum AppPaths {
    public static var supportDirectory: URL {
        // On iOS prefer the shared App Group container so the app and the Packet
        // Tunnel extension read/write the same CA + state. Falls back to the
        // per-app Application Support dir (macOS, tests, missing entitlement).
        #if os(iOS)
        if let shared = AppGroup.containerURL() {
            let dir = shared.appendingPathComponent("HTTrail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HTTrail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var certificatesDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("ca", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where we drop the CA so the user (or a generated profile) can grab it.
    public static var exportedCACertificate: URL {
        supportDirectory.appendingPathComponent("HTTrail-CA.pem")
    }
}
