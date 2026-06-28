import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Builds an Apple `.mobileconfig` configuration profile that (a) installs the
/// HTTrail root CA as a trusted root and (b) points the device's HTTP/HTTPS
/// proxy at this Mac. AirDrop / email it to an iPhone, install, then trust the
/// CA under Settings → General → About → Certificate Trust Settings.
public struct ProfileGenerator: Sendable {
    private let hostIdentifier: String

    public init() {
        self.hostIdentifier = Self.localHostIdentifier()
    }

    init(hostIdentifier: String) {
        self.hostIdentifier = hostIdentifier
    }

    /// Returns the `.mobileconfig` XML plist bytes.
    public func makeProfile(caCertificateDER: Data, proxyHost: String, proxyPort: Int,
                            includeProxyPayload: Bool = true) throws -> Data {
        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.httrail.ca.\(stableUUID("ca"))",
            "PayloadUUID": stableUUID("ca-uuid"),
            "PayloadDisplayName": "HTTrail Root CA",
            "PayloadDescription": "Allows HTTrail to inspect encrypted HTTPS traffic.",
            "PayloadCertificateFileName": "HTTrail-CA.cer",
            "PayloadContent": caCertificateDER
        ]

        var payloads: [[String: Any]] = [certPayload]

        if includeProxyPayload {
            let proxyPayload: [String: Any] = [
                "PayloadType": "com.apple.proxy.http.global",
                "PayloadVersion": 1,
                "PayloadIdentifier": "com.httrail.proxy.\(stableUUID("proxy"))",
                "PayloadUUID": stableUUID("proxy-uuid"),
                "PayloadDisplayName": "HTTrail Proxy",
                "PayloadDescription": "Routes traffic through HTTrail at \(proxyHost):\(proxyPort).",
                "ProxyType": "Manual",
                "HTTPEnable": 1,
                "HTTPProxy": proxyHost,
                "HTTPPort": proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort
            ]
            payloads.append(proxyPayload)
        }

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.httrail.profile",
            "PayloadUUID": stableUUID("root"),
            "PayloadDisplayName": "HTTrail (Proxy + Root CA)",
            "PayloadDescription": "Installs the HTTrail certificate authority and proxy configuration.",
            "PayloadOrganization": "HTTrail",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": payloads
        ]

        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Builds the on-device capture profile: the root CA **plus** a VPN payload
    /// that references the HTTrail Packet Tunnel network extension. Installing
    /// (and approving) this single profile in *Settings ▸ Profile Downloaded*
    /// sets up both trust and the capture VPN at once — the manual, user-approved
    /// flow (as opposed to the programmatic `NETunnelProviderManager` prompt).
    public func makeCaptureProfile(caCertificateDER: Data, appBundleID: String,
                                   providerBundleID: String, proxyPort: Int) throws -> Data {
        let certPayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.httrail.ca.\(stableUUID("ca"))",
            "PayloadUUID": stableUUID("ca-uuid"),
            "PayloadDisplayName": "HTTrail Root CA",
            "PayloadDescription": "Allows HTTrail to inspect encrypted HTTPS traffic.",
            "PayloadCertificateFileName": "HTTrail-CA.cer",
            "PayloadContent": caCertificateDER
        ]

        let vpnPayload: [String: Any] = [
            "PayloadType": "com.apple.vpn.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.httrail.vpn.\(stableUUID("vpn"))",
            "PayloadUUID": stableUUID("vpn-uuid"),
            "PayloadDisplayName": "HTTrail Capture VPN",
            "PayloadDescription": "Routes this device's traffic through the on-device HTTrail proxy.",
            "UserDefinedName": "HTTrail Capture",
            "VPNType": "VPN",
            "VPNSubType": appBundleID,
            "VPN": [
                "RemoteAddress": "127.0.0.1",
                "AuthenticationMethod": "Password",
                "ProviderBundleIdentifier": providerBundleID,
                "ProviderType": "packet-tunnel",
                "OnDemandEnabled": 0
            ] as [String: Any],
            // Custom config forwarded to the provider as `providerConfiguration`.
            "VendorConfig": ["port": proxyPort]
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.httrail.capture.profile",
            "PayloadUUID": stableUUID("capture-root"),
            "PayloadDisplayName": "HTTrail Capture (VPN + Root CA)",
            "PayloadDescription": "Installs the HTTrail certificate authority and the on-device capture VPN.",
            "PayloadOrganization": "HTTrail",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [certPayload, vpnPayload]
        ]

        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Deterministic per-machine UUIDs so re-issuing the profile updates rather
    /// than stacking duplicates on the device.
    private func stableUUID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(hostIdentifier):\(seed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return String(
            format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }

    private static func localHostIdentifier() -> String {
        #if canImport(Darwin) || canImport(Glibc)
        var buffer = [CChar](repeating: 0, count: 256)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            gethostname(pointer.baseAddress, pointer.count)
        }
        buffer[buffer.count - 1] = 0
        if result == 0 {
            let host = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty { return host }
        }
        #endif
        return "HTTrail"
    }
}
