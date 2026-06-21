#if os(macOS)
import Foundation

/// Drives macOS' system HTTP/HTTPS proxy settings via `networksetup`, the way
/// Charles flips the OS proxy on/off when you start recording. Mutating the
/// settings requires admin rights, so writes run through `osascript` with a
/// privilege prompt; reads run directly.
public struct SystemProxyController: Sendable {
    public init() {}

    public struct ProxyState: Sendable {
        public var httpEnabled: Bool
        public var httpsEnabled: Bool
        public var host: String?
        public var port: Int?
    }

    /// The primary active network service (e.g. "Wi-Fi"), used as the target.
    public func primaryNetworkService() -> String? {
        guard let output = run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        // Skip the header line and disabled services (prefixed with '*').
        for line in lines.dropFirst() where !line.hasPrefix("*") {
            // Prefer Wi-Fi / Ethernet if present.
            if line.localizedCaseInsensitiveContains("Wi-Fi") || line.localizedCaseInsensitiveContains("Ethernet") {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return lines.dropFirst().first { !$0.hasPrefix("*") }?.trimmingCharacters(in: .whitespaces)
    }

    public func currentState(service: String) -> ProxyState {
        let http = run("/usr/sbin/networksetup", ["-getwebproxy", service]) ?? ""
        let https = run("/usr/sbin/networksetup", ["-getsecurewebproxy", service]) ?? ""
        return ProxyState(
            httpEnabled: http.contains("Enabled: Yes"),
            httpsEnabled: https.contains("Enabled: Yes"),
            host: value(in: http, key: "Server"),
            port: value(in: http, key: "Port").flatMap { Int($0) }
        )
    }

    /// Point the system HTTP & HTTPS proxy at `host:port`. Prompts for admin.
    public func enableProxy(service: String, host: String, port: Int) -> Bool {
        let script = """
        do shell script "/usr/sbin/networksetup -setwebproxy \\"\(service)\\" \(host) \(port) && \
        /usr/sbin/networksetup -setsecurewebproxy \\"\(service)\\" \(host) \(port) && \
        /usr/sbin/networksetup -setwebproxystate \\"\(service)\\" on && \
        /usr/sbin/networksetup -setsecurewebproxystate \\"\(service)\\" on" with administrator privileges
        """
        return run("/usr/bin/osascript", ["-e", script]) != nil
    }

    /// Turn the system HTTP & HTTPS proxy back off. Prompts for admin.
    public func disableProxy(service: String) -> Bool {
        let script = """
        do shell script "/usr/sbin/networksetup -setwebproxystate \\"\(service)\\" off && \
        /usr/sbin/networksetup -setsecurewebproxystate \\"\(service)\\" off" with administrator privileges
        """
        return run("/usr/bin/osascript", ["-e", script]) != nil
    }

    // MARK: - Root CA trust (the macOS equivalent of the iOS .mobileconfig)

    /// Whether a certificate with `commonName` is present in the System keychain.
    /// Used to reflect "CA installed & trusted" state in the UI without a prompt.
    public func isCertificateInSystemKeychain(commonName: String) -> Bool {
        run("/usr/bin/security",
            ["find-certificate", "-c", commonName, "/Library/Keychains/System.keychain"]) != nil
    }

    /// Adds the CA at `pemPath` to the System keychain as an *always-trusted*
    /// root (`-r trustRoot`). Prompts for admin — equivalent to dragging the cert
    /// into Keychain Access and marking it "Always Trust", but one click.
    public func installTrustedRootCA(pemPath: String) -> Bool {
        let escaped = pemPath.replacingOccurrences(of: "\"", with: "\\\\\"")
        let script = """
        do shell script "/usr/bin/security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain \\"\(escaped)\\"" with administrator privileges
        """
        return run("/usr/bin/osascript", ["-e", script]) != nil
    }

    /// Removes the trusted root CA (by file) from the System keychain. Prompts
    /// for admin. Best-effort: returns false if the cert wasn't present.
    public func removeTrustedRootCA(pemPath: String) -> Bool {
        let escaped = pemPath.replacingOccurrences(of: "\"", with: "\\\\\"")
        let script = """
        do shell script "/usr/bin/security remove-trusted-cert -d \\"\(escaped)\\" && \
        /usr/bin/security delete-certificate -c \\"\(CertificateAuthority.caCommonName)\\" \
        /Library/Keychains/System.keychain" with administrator privileges
        """
        return run("/usr/bin/osascript", ["-e", script]) != nil
    }

    // MARK: - Helpers

    private func value(in output: String, key: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#endif
