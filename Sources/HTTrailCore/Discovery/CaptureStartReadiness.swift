import Foundation

/// A missing prerequisite that must be fixed before an iOS capture session starts.
public enum CaptureStartBlocker: Equatable, Sendable {
    case vpnProfileMissing
    case certificateUntrusted
}

/// Pure readiness result for the iOS capture start gate.
///
/// The Packet Tunnel configuration routes traffic through HTTrail; the trusted
/// CA lets HTTPS validate after interception. Starting without either one creates
/// a misleading "recording" state, so the UI must keep the user in setup first.
public struct CaptureStartReadiness: Equatable, Sendable {
    public var blockers: [CaptureStartBlocker]

    public init(blockers: [CaptureStartBlocker]) {
        self.blockers = blockers
    }

    public var canStart: Bool {
        blockers.isEmpty
    }

    public func contains(_ blocker: CaptureStartBlocker) -> Bool {
        blockers.contains(blocker)
    }

    public static func evaluate(vpnConfigurationInstalled: Bool,
                                certificateTrusted: Bool) -> CaptureStartReadiness {
        var blockers: [CaptureStartBlocker] = []
        if !vpnConfigurationInstalled { blockers.append(.vpnProfileMissing) }
        if !certificateTrusted { blockers.append(.certificateUntrusted) }
        return CaptureStartReadiness(blockers: blockers)
    }
}
