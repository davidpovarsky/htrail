import Foundation
import WireGuardKit

/// Downstream-only parser: rejects executable wg-quick hooks and never includes
/// configuration values (especially keys) in errors.
struct PurelineWGProfile {
    let tunnel: TunnelConfiguration
    let source: String

    var endpoint: String { tunnel.peers.first?.endpoint?.stringRepresentation ?? "" }
    var routesIPv6: Bool {
        tunnel.peers.contains { $0.allowedIPs.contains { $0.stringRepresentation == "::/0" } }
    }

    enum ProfileError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    static func parse(_ source: String) throws -> PurelineWGProfile {
        guard source.utf8.count <= 65_536 else { throw ProfileError.invalid("The profile is too large.") }
        enum Section { case none, interface, peer }
        var section = Section.none
        var interfaceFields: [String: String] = [:]
        var peerFields: [[String: String]] = []
        var sawInterface = false
        let interfaceKeys: Set<String> = ["privatekey", "address", "dns", "listenport", "mtu"]
        let peerKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]
        let repeated: Set<String> = ["address", "dns", "allowedips"]

        for raw in source.split(whereSeparator: \.isNewline) {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.lowercased() == "[interface]" {
                guard !sawInterface, peerFields.isEmpty else {
                    throw ProfileError.invalid("The profile must contain one Interface section before its peers.")
                }
                sawInterface = true
                section = .interface
                continue
            }
            if line.lowercased() == "[peer]" {
                guard sawInterface, peerFields.count < 4 else {
                    throw ProfileError.invalid("The profile must contain an Interface and between one and four peers.")
                }
                peerFields.append([:])
                section = .peer
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ProfileError.invalid("A profile line is not a key/value pair.")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw ProfileError.invalid("A profile field is empty.") }
            switch section {
            case .none:
                throw ProfileError.invalid("A profile field occurs outside a section.")
            case .interface:
                guard interfaceKeys.contains(key) else {
                    throw ProfileError.invalid("The Interface contains an unsupported option. Shell hooks are not supported.")
                }
                try insert(value, key: key, into: &interfaceFields, repeated: repeated)
            case .peer:
                guard peerKeys.contains(key) else { throw ProfileError.invalid("A peer contains an unsupported option.") }
                try insert(value, key: key, into: &peerFields[peerFields.count - 1], repeated: repeated)
            }
        }
        guard let privateText = interfaceFields["privatekey"], let privateKey = PrivateKey(base64Key: privateText) else {
            throw ProfileError.invalid("The Interface private key is missing or invalid.")
        }
        var interface = InterfaceConfiguration(privateKey: privateKey)
        let addressTexts = values(interfaceFields["address"])
        guard !addressTexts.isEmpty else { throw ProfileError.invalid("The profile needs an Interface address.") }
        interface.addresses = try addressTexts.map {
            guard let address = IPAddressRange(from: $0) else { throw ProfileError.invalid("An Interface address is invalid.") }
            return address
        }
        let dnsTexts = values(interfaceFields["dns"])
        guard !dnsTexts.isEmpty else { throw ProfileError.invalid("The profile needs a DNS server for remote filtering.") }
        interface.dns = try dnsTexts.map {
            guard let server = DNSServer(from: $0) else { throw ProfileError.invalid("A DNS server address is invalid.") }
            return server
        }
        if let text = interfaceFields["listenport"] {
            guard let port = UInt16(text) else { throw ProfileError.invalid("The listen port is invalid.") }
            interface.listenPort = port
        }
        if let text = interfaceFields["mtu"] {
            guard let mtu = UInt16(text), (1280...1500).contains(mtu) else {
                throw ProfileError.invalid("MTU must be between 1280 and 1500.")
            }
            interface.mtu = mtu
        }
        guard !peerFields.isEmpty else { throw ProfileError.invalid("The profile needs a server peer.") }
        var seenKeys = Set<PublicKey>()
        let peers: [PeerConfiguration] = try peerFields.map { fields in
            guard let text = fields["publickey"], let key = PublicKey(base64Key: text), seenKeys.insert(key).inserted else {
                throw ProfileError.invalid("A server public key is missing, invalid, or duplicated.")
            }
            var peer = PeerConfiguration(publicKey: key)
            if let text = fields["presharedkey"] {
                guard let key = PreSharedKey(base64Key: text) else { throw ProfileError.invalid("A preshared key is invalid.") }
                peer.preSharedKey = key
            }
            guard let endpointText = fields["endpoint"], let endpoint = Endpoint(from: endpointText) else {
                throw ProfileError.invalid("A server endpoint is missing or invalid.")
            }
            peer.endpoint = endpoint
            let allowed = values(fields["allowedips"])
            guard !allowed.isEmpty else { throw ProfileError.invalid("A peer needs AllowedIPs.") }
            peer.allowedIPs = try allowed.map {
                guard let range = IPAddressRange(from: $0) else { throw ProfileError.invalid("An allowed IP range is invalid.") }
                return range
            }
            if let text = fields["persistentkeepalive"] {
                guard let seconds = UInt16(text) else { throw ProfileError.invalid("PersistentKeepalive is invalid.") }
                peer.persistentKeepAlive = seconds
            }
            return peer
        }
        guard peers.contains(where: { $0.allowedIPs.contains { $0.stringRepresentation == "0.0.0.0/0" } }) else {
            throw ProfileError.invalid("Remote filtering requires the IPv4 default route (0.0.0.0/0).")
        }
        return PurelineWGProfile(tunnel: TunnelConfiguration(name: "Pureline Remote", interface: interface, peers: peers), source: source)
    }

    private static func values(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func insert(_ value: String, key: String, into fields: inout [String: String], repeated: Set<String>) throws {
        if let old = fields[key] {
            guard repeated.contains(key) else { throw ProfileError.invalid("A profile field is duplicated.") }
            fields[key] = old + "," + value
        } else { fields[key] = value }
    }
}

struct PurelineWGStatistics: Codable, Equatable {
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    var latestHandshake: TimeInterval = 0

    /// The backend response also contains secrets. Consume only these counters;
    /// never log, persist, or send the original response to the app.
    static func parse(_ runtime: String) -> PurelineWGStatistics {
        var result = PurelineWGStatistics()
        for line in runtime.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "rx_bytes":
                if let value = UInt64(parts[1]) {
                    let (sum, overflow) = result.receivedBytes.addingReportingOverflow(value)
                    result.receivedBytes = overflow ? UInt64.max : sum
                }
            case "tx_bytes":
                if let value = UInt64(parts[1]) {
                    let (sum, overflow) = result.sentBytes.addingReportingOverflow(value)
                    result.sentBytes = overflow ? UInt64.max : sum
                }
            case "last_handshake_time_sec":
                if let value = TimeInterval(parts[1]), value.isFinite, value >= 0 {
                    result.latestHandshake = max(result.latestHandshake, value)
                }
            default: break
            }
        }
        return result
    }
}

enum PurelineWGContract {
    static let modeKey = "purelineTransport"
    static let remoteMode = "wireguardRemote"
    static let providerID = "com.davidpovarsky.pureline.PacketTunnel"
    static let appGroup = "group.com.davidpovarsky.pureline"
    static let statisticsMessage = Data("pureline-wg-stats-v1".utf8)
}
