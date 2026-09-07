import Foundation
import HTTrailCore

public final class PurelineAntiBotCompatibilityStore: @unchecked Sendable {
    public static let shared = PurelineAntiBotCompatibilityStore()
    public static let defaultTTL: TimeInterval = 60 * 60
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = AppPaths.supportDirectory.appendingPathComponent("pureline-antibot-bypasses.json")) { self.url = url }

    public func load(now: Date = Date()) -> [CompatibilityBypassInfo] {
        lock.lock(); defer { lock.unlock() }
        let values = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CompatibilityBypassInfo].self, from: $0) } ?? [])
            .filter { $0.expiresAt > now }
        writeLocked(values); return values
    }

    public func add(host: String, now: Date = Date(), ttl: TimeInterval = defaultTTL) -> CompatibilityBypassInfo {
        lock.lock(); defer { lock.unlock() }
        var values = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CompatibilityBypassInfo].self, from: $0) } ?? [])
            .filter { $0.expiresAt > now && $0.host.caseInsensitiveCompare(host) != .orderedSame }
        let info = CompatibilityBypassInfo(host: host, reason: "antiBotIncompatible", expiresAt: now.addingTimeInterval(min(max(ttl, 60), 24 * 60 * 60)))
        values.append(info); writeLocked(values); return info
    }

    private func writeLocked(_ values: [CompatibilityBypassInfo]) {
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
    }
}

public enum PurelineAntiBotChallengeDetector {
    public static func isStrongChallenge(_ response: CapturedResponse) -> Bool {
        guard response.statusCode == 403 else { return false }
        let server = response.header("Server")?.lowercased() ?? ""
        let ray = response.header("CF-Ray")
        let type = response.header("CF-Mitigated")?.lowercased()
        let body = String(decoding: response.body.prefix(64 * 1_024), as: UTF8.self).lowercased()
        let marker = body.contains("just a moment") || body.contains("cf-chl-") || body.contains("challenge-platform")
        let headerSignals = (server.contains("cloudflare") ? 1 : 0) + (ray == nil ? 0 : 1) + (type == "challenge" ? 1 : 0)
        return headerSignals >= 2 && marker
    }
}
