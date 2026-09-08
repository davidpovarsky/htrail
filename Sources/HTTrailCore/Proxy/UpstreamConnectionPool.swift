import Foundation
import NIOCore

/// Neutral opt-in HTTP/1.1 connection reuse. HTTrail's default remains one
/// connection per request; constrained downstreams may install bounded limits.
public struct UpstreamConnectionPoolConfiguration: Sendable, Equatable {
    public var maximumConnectionsPerOrigin: Int
    public var maximumConnectionsTotal: Int
    public var idleTimeout: TimeInterval

    public init(maximumConnectionsPerOrigin: Int = 2, maximumConnectionsTotal: Int = 8,
                idleTimeout: TimeInterval = 15) {
        self.maximumConnectionsPerOrigin = max(1, maximumConnectionsPerOrigin)
        self.maximumConnectionsTotal = max(1, maximumConnectionsTotal)
        self.idleTimeout = max(1, idleTimeout)
    }
}

final class UpstreamConnectionPool: @unchecked Sendable {
    struct Key: Hashable { let tls: Bool; let host: String; let port: Int }
    private struct Entry { let channel: Channel; let returnedAt: Date }
    private let configuration: UpstreamConnectionPoolConfiguration
    private let lock = NSLock()
    private var entries: [Key: [Entry]] = [:]

    init(configuration: UpstreamConnectionPoolConfiguration) { self.configuration = configuration }

    func checkout(target: UpstreamTarget, events: (@Sendable (ProxyRuntimeEvent) -> Void)?) -> Channel? {
        let key = Key(tls: target.tls, host: target.host.lowercased(), port: target.port)
        var stale: [(Channel, String)] = []
        var selected: Channel?
        lock.lock()
        let now = Date()
        var candidates = entries.removeValue(forKey: key) ?? []
        while let entry = candidates.popLast() {
            if now.timeIntervalSince(entry.returnedAt) > configuration.idleTimeout {
                stale.append((entry.channel, "idle-timeout"))
            } else if !entry.channel.isActive {
                stale.append((entry.channel, "inactive-on-checkout"))
            } else { selected = entry.channel; break }
        }
        if !candidates.isEmpty { entries[key] = candidates }
        lock.unlock()
        stale.forEach { channel, reason in
            channel.close(promise: nil)
            events?(ProxyRuntimeEvent(kind: .upstreamPoolEviction, host: target.host, detail: reason))
        }
        events?(ProxyRuntimeEvent(kind: selected == nil ? .upstreamPoolMiss : .upstreamPoolHit,
                                  host: target.host, detail: selected == nil ? "new connection required" : "HTTP/1.1 connection reused"))
        return selected
    }

    func release(_ channel: Channel, target: UpstreamTarget,
                 events: (@Sendable (ProxyRuntimeEvent) -> Void)?) {
        guard channel.isActive else { discard(channel, target: target, reason: "inactive", events: events); return }
        let key = Key(tls: target.tls, host: target.host.lowercased(), port: target.port)
        var evicted: [Channel] = []
        lock.lock()
        var origin = entries[key] ?? []
        if origin.count >= configuration.maximumConnectionsPerOrigin {
            evicted.append(origin.removeFirst().channel)
        }
        origin.append(Entry(channel: channel, returnedAt: Date())); entries[key] = origin
        while entries.values.reduce(0, { $0 + $1.count }) > configuration.maximumConnectionsTotal {
            guard let oldest = entries.flatMap({ pair in pair.value.map { (pair.key, $0) } })
                .min(by: { $0.1.returnedAt < $1.1.returnedAt }) else { break }
            let oldestID = ObjectIdentifier(oldest.1.channel)
            entries[oldest.0]?.removeAll { ObjectIdentifier($0.channel) == oldestID }
            if entries[oldest.0]?.isEmpty == true { entries.removeValue(forKey: oldest.0) }
            evicted.append(oldest.1.channel)
        }
        lock.unlock()
        evicted.forEach { $0.close(promise: nil) }
        if !evicted.isEmpty { events?(ProxyRuntimeEvent(kind: .upstreamPoolEviction, host: target.host, detail: "bounded-capacity")) }
    }

    func discard(_ channel: Channel, target: UpstreamTarget, reason: String,
                 events: (@Sendable (ProxyRuntimeEvent) -> Void)?) {
        channel.close(promise: nil)
        events?(ProxyRuntimeEvent(kind: .upstreamPoolEviction, host: target.host, detail: reason))
    }

    func shutdown() {
        lock.lock(); let channels = entries.values.flatMap { $0.map(\.channel) }; entries.removeAll(); lock.unlock()
        channels.forEach { $0.close(promise: nil) }
    }
}
