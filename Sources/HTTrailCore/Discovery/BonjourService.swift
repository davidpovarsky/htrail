import Foundation
import Combine

/// A Mac running HTTrail, discovered on the LAN via Bonjour.
public struct DiscoveredProxy: Identifiable, Hashable, Sendable {
    public var id: String       // Bonjour service name (unique on the LAN)
    public var name: String     // human label (device name)
    public var host: String     // resolved host / IPv4
    public var port: Int        // proxy port
    public var caPort: Int      // LAN CA-profile HTTP port (0 if absent)
    public var caFP: String     // short CA fingerprint ("" if absent)
    public var pairPort: Int    // Mac PairingServer port (0 if absent)

    public init(id: String, name: String, host: String, port: Int, caPort: Int, caFP: String, pairPort: Int) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.caPort = caPort; self.caFP = caFP; self.pairPort = pairPort
    }
}

/// The Bonjour service type HTTrail advertises/browses.
public enum BonjourConfig {
    public static let serviceType = "_httrail._tcp."
    public static let domain = "local."
}

/// TXT-record (de)serialisation. Kept pure for deterministic unit testing.
public enum BonjourTXT {
    public static func encode(name: String, port: Int, caPort: Int, caFP: String, pairPort: Int) -> [String: Data] {
        [
            "name": Data(name.utf8),
            "port": Data(String(port).utf8),
            "caPort": Data(String(caPort).utf8),
            "caFP": Data(caFP.utf8),
            "pairPort": Data(String(pairPort).utf8),
        ]
    }

    /// Decodes a TXT dictionary. Takes `[String: Any]` (not `[String: Data]`)
    /// deliberately: `NetService.dictionary(fromTXTRecord:)` returns `NSNull` —
    /// not empty `Data` — for a key advertised with an empty value, and reading
    /// such a value through a `[String: Data]` dictionary force-bridges
    /// `NSNull → Data` and traps. Guarding `as? Data` tolerates it safely.
    public static func decode(_ txt: [String: Any]) -> (name: String?, port: Int?, caPort: Int?, caFP: String?, pairPort: Int?) {
        func str(_ key: String) -> String? {
            guard let data = txt[key] as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return (str("name"), str("port").flatMap(Int.init), str("caPort").flatMap(Int.init), str("caFP"), str("pairPort").flatMap(Int.init))
    }
}

/// Result of attempting to advertise over Bonjour.
public enum BonjourPublishState: Sendable, Equatable {
    case publishing
    case published
    case failed(String)
}

/// Advertises the running proxy (used by the Mac).
public final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    /// Reports publish success/failure so the UI can surface it.
    public var onState: ((BonjourPublishState) -> Void)?

    public func start(name: String, port: Int, caPort: Int, caFP: String, pairPort: Int) {
        stop()
        let svc = NetService(domain: BonjourConfig.domain, type: BonjourConfig.serviceType,
                             name: name, port: Int32(port))
        svc.delegate = self
        svc.setTXTRecord(NetService.data(fromTXTRecord: BonjourTXT.encode(
            name: name, port: port, caPort: caPort, caFP: caFP, pairPort: pairPort)))
        onState?(.publishing)
        svc.publish()
        service = svc
    }

    public func stop() {
        service?.stop()
        service = nil
    }

    public func netServiceDidPublish(_ sender: NetService) {
        onState?(.published)
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        onState?(.failed("Bonjour publish failed (error \(code)). Check System Settings ▸ Privacy ▸ Local Network."))
    }
}

/// Browses for HTTrail Macs on the LAN (used by iOS). `found` is published for
/// SwiftUI; callbacks are delivered on the main runloop.
public final class BonjourBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published public private(set) var found: [DiscoveredProxy] = []
    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        found = []
        browser.searchForServices(ofType: BonjourConfig.serviceType, inDomain: BonjourConfig.domain)
    }

    public func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    // MARK: NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Cancel any in-flight resolve so a late didResolve can't re-add a ghost.
        if let pending = resolving.remove(service) { pending.stop() }
        found.removeAll { $0.id == service.name }
    }

    // MARK: NetServiceDelegate

    public func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = service.hostName else { return }
        // Go via NSDictionary → [String: Any] so empty-valued TXT keys (which
        // arrive as NSNull) are never force-bridged to Data — see BonjourTXT.decode.
        let txt: [String: Any] = service.txtRecordData()
            .map { (NetService.dictionary(fromTXTRecord: $0) as NSDictionary) as? [String: Any] ?? [:] } ?? [:]
        let fields = BonjourTXT.decode(txt)
        let proxy = DiscoveredProxy(
            id: service.name,
            name: fields.name ?? service.name,
            host: host.hasSuffix(".") ? String(host.dropLast()) : host,
            port: fields.port ?? (service.port > 0 ? service.port : 9090),
            caPort: fields.caPort ?? 0,
            caFP: fields.caFP ?? "",
            pairPort: fields.pairPort ?? 0)
        if let idx = found.firstIndex(where: { $0.id == proxy.id }) { found[idx] = proxy }
        else { found.append(proxy) }
        resolving.remove(service)
    }

    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(service)
    }
}
