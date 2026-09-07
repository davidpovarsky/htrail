import Foundation
import HTTrailCore

/// Persistent Pureline compatibility bypasses. Entries expire automatically;
/// no domain is permanently or specially allowlisted.
public final class PurelineCompatibilityBypassStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("pureline-tls-bypasses.json")) {
        self.url = url
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(now: Date = Date()) -> (active: [PinnedHostInfo], expired: [PinnedHostInfo]) {
        lock.lock(); defer { lock.unlock() }
        let all = readLocked()
        let active = all.filter { $0.expiresAt > now }
        let expired = all.filter { $0.expiresAt <= now }
        if !expired.isEmpty { writeLocked(active) }
        return (active, expired)
    }

    public func save(_ entries: [PinnedHostInfo], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let active = Dictionary(grouping: entries.filter { $0.expiresAt > now }, by: { $0.host.lowercased() })
            .compactMap { $0.value.max { $0.expiresAt < $1.expiresAt } }
            .sorted { $0.host < $1.host }
        writeLocked(active)
    }

    private func readLocked() -> [PinnedHostInfo] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([PinnedHostInfo].self, from: data)) ?? []
    }

    private func writeLocked(_ entries: [PinnedHostInfo]) {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
