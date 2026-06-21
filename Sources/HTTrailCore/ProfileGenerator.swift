import Foundation

/// Builds an Apple `.mobileconfig` configuration profile that (a) installs the
/// HTTrail root CA as a trusted root and (b) points the device's HTTP/HTTPS
/// proxy at this Mac. AirDrop / email it to an iPhone, install, then trust the
/// CA under Settings → General → About → Certificate Trust Settings.
public struct ProfileGenerator: Sendable {
    public init() {}

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
        let host = ProcessInfo.processInfo.hostName
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(host)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        let hex = String(format: "%016llX", h)
        // Format as a UUID-ish string.
        let p = Array(hex)
        return "\(String(p[0..<8]))-\(String(p[8..<12]))-\(String(p[12..<16]))-HTTR-AILPROXY000".prefix(36).description
    }
}
