import Foundation

public enum RuleKind: String, Codable, Sendable, CaseIterable {
    case block            // short-circuit with a status code
    case mapLocal         // serve a local file
    case mapRemote        // redirect to a different host/port
    case rewriteRequest   // mutate outgoing headers / body
    case rewriteResponse  // mutate incoming headers / body / status
    case throttle         // delay the response
    case breakpoint       // pause for manual editing (request and/or response)

    public var label: String {
        switch self {
        case .block: return "Block"
        case .mapLocal: return "Map Local"
        case .mapRemote: return "Map Remote"
        case .rewriteRequest: return "Rewrite Request"
        case .rewriteResponse: return "Rewrite Response"
        case .throttle: return "Throttle"
        case .breakpoint: return "Breakpoint"
        }
    }
}

/// A single Charles-style interception rule. One flat struct keeps persistence
/// and the UI simple; only the fields relevant to `kind` are used.
public struct InterceptRule: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var name: String = "New Rule"
    public var enabled: Bool = true
    public var kind: RuleKind = .block

    /// Glob match (`*` wildcard) against the full request URL. Empty = match all.
    public var urlPattern: String = ""

    // block
    public var blockStatus: Int = 403
    // mapLocal
    public var localFilePath: String = ""
    public var localContentType: String = "application/json"
    // mapRemote
    public var remoteHost: String = ""
    public var remotePort: Int = 443
    public var remoteTLS: Bool = true
    // rewrite (request or response)
    public var setHeaders: [KeyValueItem] = []
    public var removeHeaders: [String] = []
    public var findText: String = ""
    public var replaceText: String = ""
    public var setStatus: Int = 0   // 0 = leave unchanged
    // throttle
    public var throttleMS: Int = 1000
    public var bytesPerSecond: Int = 0   // 0 = unlimited (only a latency delay)
    // breakpoint
    public var breakRequest: Bool = true
    public var breakResponse: Bool = false

    public init() {}
}

/// Latency + bandwidth simulation applied to a forwarded flow.
public struct ThrottleConfig: Sendable {
    public var delayMS: Int = 0
    public var bytesPerSecond: Int = 0
    public var isActive: Bool { delayMS > 0 || bytesPerSecond > 0 }
}

/// Tuning for automatic certificate-pinning detection.
public struct PinningConfig: Sendable {
    /// Master switch. When off, hosts are never auto-tunneled on handshake failure.
    public var enabled: Bool = true
    /// Consecutive MITM handshake failures before a host is treated as pinned.
    public var failureThreshold: Int = 1
    /// How long an auto-detected host stays in tunnel mode before being retried.
    public var ttl: TimeInterval = 3600
    /// Require one successful MITM handshake first, so an untrusted CA (which
    /// fails identically) isn't mistaken for pinning and used to blind every host.
    public var requirePriorSuccess: Bool = true
    public init() {}
    public init(enabled: Bool) { self.enabled = enabled }
}

/// A host that auto-detection has put into tunnel mode.
public struct PinnedHostInfo: Sendable, Identifiable, Equatable {
    public var id: String { host }
    public let host: String
    public let expiresAt: Date
    public init(host: String, expiresAt: Date) {
        self.host = host; self.expiresAt = expiresAt
    }
}

/// What the engine decided to do with an outgoing request.
public enum RequestOutcome: Sendable {
    case respond(CapturedResponse)                                 // block / map-local short circuit
    case forward(CapturedRequest, UpstreamTarget, ThrottleConfig)  // (possibly rewritten) request, target, throttle
}

/// A paused flow awaiting manual edit at a breakpoint.
public struct BreakpointEvent: Sendable, Identifiable {
    public enum Phase: Sendable { case request, response }
    public let id = UUID()
    public let phase: Phase
    public let request: CapturedRequest
    public let response: CapturedResponse?
}

/// The user's edit returned from a breakpoint (nil keeps things unchanged).
public struct BreakpointEdit: Sendable {
    public var request: CapturedRequest?
    public var response: CapturedResponse?
    public init(request: CapturedRequest? = nil, response: CapturedResponse? = nil) {
        self.request = request; self.response = response
    }
}

/// Holds the active rule set and applies it to flows passing through the proxy.
/// Thread-safe; consulted from NIO event-loop threads via async bridges.
public final class InterceptEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [InterceptRule] = []

    /// Optional allowlist — when non-empty, only these host globs are MITM
    /// decrypted (Charles "SSL Proxying" list). Others are still tunneled.
    private var sslAllowlist: [String] = []

    // MARK: Certificate-pinning auto-detection state

    /// Auto-detected pinned hosts → the time their tunnel-mode entry expires.
    private var autoPinned: [String: Date] = [:]
    /// Consecutive MITM handshake failures per host (cleared on success).
    private var pinFailureStreak: [String: Int] = [:]
    /// True once any host has completed a MITM handshake, which proves the CA is
    /// trusted — the signal that tells real pinning apart from a CA that simply
    /// hasn't been installed yet (both fail the handshake identically).
    private var globalMITMSucceeded = false
    /// Hosts the user has explicitly forced back into decryption despite detection.
    private var forceDecryptHosts: Set<String> = []
    private var pinningConfig = PinningConfig()

    /// Provided by the UI to handle breakpoints interactively.
    public var breakpointHandler: (@Sendable (BreakpointEvent) async -> BreakpointEdit?)?

    public init() {}

    public func setRules(_ rules: [InterceptRule]) {
        lock.lock(); self.rules = rules; lock.unlock()
    }

    public func setSSLAllowlist(_ patterns: [String]) {
        lock.lock(); self.sslAllowlist = patterns; lock.unlock()
    }

    /// Apply a whole ``SharedConfig`` at once — used by the iOS extension to pick
    /// up rules/allowlist/pinning the app configured in another process.
    public func apply(_ config: SharedConfig) {
        setRules(config.rules)
        setSSLAllowlist(config.sslAllowlist)
        setPinningConfig(PinningConfig(enabled: config.pinningEnabled))
        setForcedDecryptHosts(config.forcedDecryptHosts)
    }

    /// Replace the set of user-forced decrypt hosts (driven from the UI/config).
    public func setForcedDecryptHosts(_ hosts: [String]) {
        lock.lock(); forceDecryptHosts = Set(hosts); lock.unlock()
    }

    private func activeRules() -> [InterceptRule] {
        lock.lock(); defer { lock.unlock() }
        return rules.filter { $0.enabled }
    }

    public func shouldDecrypt(host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A user-forced host is always decrypted, overriding pinning + allowlist.
        if forceDecryptHosts.contains(host) { return true }
        // Auto-detected pinned hosts tunnel until their entry expires.
        if pinningConfig.enabled, let expiry = autoPinned[host], expiry > Date() {
            return false
        }
        guard !sslAllowlist.isEmpty else { return true }
        return sslAllowlist.contains { Glob.match($0, host) }
    }

    // MARK: Pinning detection

    public func setPinningConfig(_ config: PinningConfig) {
        lock.lock(); pinningConfig = config; lock.unlock()
    }

    /// Called when a MITM handshake with the client completes — the client
    /// accepted our forged leaf, so the CA is trusted and this host isn't pinned.
    public func recordMITMHandshakeSuccess(host: String) {
        lock.lock(); defer { lock.unlock() }
        globalMITMSucceeded = true
        pinFailureStreak[host] = nil
        autoPinned[host] = nil
    }

    /// Called when a MITM handshake dies before completing (fatal TLS alert or an
    /// abrupt close). Returns true if the host has now crossed the threshold and
    /// should be tunneled on its next connection.
    @discardableResult
    public func recordMITMHandshakeFailure(host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pinningConfig.enabled else { return false }
        let streak = (pinFailureStreak[host] ?? 0) + 1
        pinFailureStreak[host] = streak
        // Hold off until the CA is proven trusted; otherwise an untrusted-CA
        // failure (identical on the wire) would blind every host it touches.
        if pinningConfig.requirePriorSuccess && !globalMITMSucceeded { return false }
        guard streak >= pinningConfig.failureThreshold else { return false }
        autoPinned[host] = Date().addingTimeInterval(pinningConfig.ttl)
        return true
    }

    /// Hosts currently in auto-detected tunnel mode (expired entries pruned).
    public func detectedPinnedHosts() -> [PinnedHostInfo] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        autoPinned = autoPinned.filter { $0.value > now }
        return autoPinned
            .map { PinnedHostInfo(host: $0.key, expiresAt: $0.value) }
            .sorted { $0.host < $1.host }
    }

    /// Force a host back into decryption, overriding pinning detection. Useful
    /// when the user wants to inspect a host they know they can trust the CA on.
    public func forceDecrypt(host: String) {
        lock.lock(); defer { lock.unlock() }
        forceDecryptHosts.insert(host)
        autoPinned[host] = nil
        pinFailureStreak[host] = nil
    }

    /// Drop a host's auto-detected pinning so it's retried as MITM next time.
    public func clearPinned(host: String) {
        lock.lock(); defer { lock.unlock() }
        autoPinned[host] = nil
        pinFailureStreak[host] = nil
        forceDecryptHosts.remove(host)
    }

    public func clearAllPinned() {
        lock.lock(); defer { lock.unlock() }
        autoPinned.removeAll()
        pinFailureStreak.removeAll()
    }

    // MARK: Request side

    public func processRequest(_ request: CapturedRequest, target: UpstreamTarget) async -> RequestOutcome {
        var current = request
        var currentTarget = target
        var throttle = ThrottleConfig()

        for rule in activeRules() where Glob.match(rule.urlPattern.isEmpty ? "*" : rule.urlPattern, request.url) {
            switch rule.kind {
            case .block:
                return .respond(syntheticResponse(status: rule.blockStatus,
                                                  body: Data("Blocked by HTTrail".utf8),
                                                  contentType: "text/plain"))
            case .mapLocal:
                if let data = try? Data(contentsOf: URL(fileURLWithPath: rule.localFilePath)) {
                    return .respond(syntheticResponse(status: 200, body: data,
                                                      contentType: rule.localContentType))
                }
            case .mapRemote:
                if !rule.remoteHost.isEmpty {
                    currentTarget = UpstreamTarget(host: rule.remoteHost, port: rule.remotePort, tls: rule.remoteTLS)
                    current.host = rule.remoteHost
                    current.port = rule.remotePort
                    current.scheme = rule.remoteTLS ? "https" : "http"
                }
            case .rewriteRequest:
                current = applyRewrite(to: current, rule: rule)
            case .throttle:
                throttle.delayMS = max(throttle.delayMS, rule.throttleMS)
                if rule.bytesPerSecond > 0 {
                    throttle.bytesPerSecond = throttle.bytesPerSecond == 0
                        ? rule.bytesPerSecond : min(throttle.bytesPerSecond, rule.bytesPerSecond)
                }
            case .breakpoint where rule.breakRequest:
                if let handler = breakpointHandler {
                    let edit = await handler(BreakpointEvent(phase: .request, request: current, response: nil))
                    if let edited = edit?.request { current = edited }
                }
            default:
                break
            }
        }
        return .forward(current, currentTarget, throttle)
    }

    // MARK: Response side

    /// Whether any active rule matching this request needs the *entire* response
    /// body in hand — a `rewriteResponse` (mutates the body) or a response-phase
    /// `breakpoint` (presents it for manual editing). When false the proxy may
    /// stream the response straight through without buffering it. Throttle is
    /// handled separately by the caller via the returned `ThrottleConfig`.
    public func requiresBufferedResponse(for request: CapturedRequest) -> Bool {
        for rule in activeRules() where Glob.match(rule.urlPattern.isEmpty ? "*" : rule.urlPattern, request.url) {
            switch rule.kind {
            case .rewriteResponse: return true
            case .breakpoint where rule.breakResponse: return true
            default: break
            }
        }
        return false
    }

    public func processResponse(_ response: CapturedResponse, for request: CapturedRequest) async -> CapturedResponse {
        var current = response
        for rule in activeRules() where Glob.match(rule.urlPattern.isEmpty ? "*" : rule.urlPattern, request.url) {
            switch rule.kind {
            case .rewriteResponse:
                current = applyResponseRewrite(to: current, rule: rule)
            case .breakpoint where rule.breakResponse:
                if let handler = breakpointHandler {
                    let edit = await handler(BreakpointEvent(phase: .response, request: request, response: current))
                    if let edited = edit?.response { current = edited }
                }
            default:
                break
            }
        }
        return current
    }

    // MARK: Mutation helpers

    private func applyRewrite(to request: CapturedRequest, rule: InterceptRule) -> CapturedRequest {
        var req = request
        var headers = req.headers.filter { h in !rule.removeHeaders.contains { $0.caseInsensitiveCompare(h.name) == .orderedSame } }
        for item in rule.setHeaders where item.enabled && !item.name.isEmpty {
            headers.removeAll { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
            headers.append(HeaderPair(name: item.name, value: item.value))
        }
        req.headers = headers
        if !rule.findText.isEmpty, let body = String(data: req.body, encoding: .utf8) {
            req.body = Data(body.replacingOccurrences(of: rule.findText, with: rule.replaceText).utf8)
        }
        return req
    }

    private func applyResponseRewrite(to response: CapturedResponse, rule: InterceptRule) -> CapturedResponse {
        var resp = response
        var headers = resp.headers.filter { h in !rule.removeHeaders.contains { $0.caseInsensitiveCompare(h.name) == .orderedSame } }
        for item in rule.setHeaders where item.enabled && !item.name.isEmpty {
            headers.removeAll { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
            headers.append(HeaderPair(name: item.name, value: item.value))
        }
        resp.headers = headers
        if rule.setStatus > 0 { resp.statusCode = rule.setStatus }
        if !rule.findText.isEmpty, let body = String(data: resp.body, encoding: .utf8) {
            resp.body = Data(body.replacingOccurrences(of: rule.findText, with: rule.replaceText).utf8)
            // Content-Length will be wrong after a body edit; drop it so the
            // proxy re-frames the response.
            resp.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        }
        return resp
    }

    private func syntheticResponse(status: Int, body: Data, contentType: String) -> CapturedResponse {
        CapturedResponse(
            statusCode: status,
            reasonPhrase: HTTPStatus.reason(status),
            httpVersion: "HTTP/1.1",
            headers: [
                HeaderPair(name: "Content-Type", value: contentType),
                HeaderPair(name: "Content-Length", value: "\(body.count)"),
                HeaderPair(name: "X-HTTrail", value: "synthetic")
            ],
            body: body,
            timestamp: Date()
        )
    }
}

/// Minimal `*` glob matcher used for rule and allowlist patterns.
enum Glob {
    static func match(_ pattern: String, _ value: String) -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        let v = value.lowercased()
        let p = pattern.lowercased()
        if !p.contains("*") { return v.contains(p) }
        let parts = p.components(separatedBy: "*")
        var index = v.startIndex
        for (i, part) in parts.enumerated() where !part.isEmpty {
            guard let range = v.range(of: part, range: index..<v.endIndex) else { return false }
            if i == 0, !p.hasPrefix("*"), range.lowerBound != v.startIndex { return false }
            index = range.upperBound
        }
        if let last = parts.last, !last.isEmpty, !p.hasSuffix("*") {
            return v.hasSuffix(last)
        }
        return true
    }
}

enum HTTPStatus {
    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 418: return "I'm a teapot"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return ""
        }
    }
}
