import Foundation

public enum ProxyRuntimeEventKind: String, Sendable {
    case upstreamTCPFailure
    case upstreamTLSFailure
    case upstreamCertificateFailure
    case upstreamTimeout
    case upstreamConnectTimeout
    case upstreamTLSHandshakeTimeout
    case upstreamReadTimeout
    case parserOrProtocolFailure
    case blindTunnelFailure
    case originHTTPStatus
    case upstreamPoolHit
    case upstreamPoolMiss
    case upstreamPoolEviction
    case upstreamTiming
    case benignTLSPeerClose
    case antiBotChallenge
}

public struct ProxyRuntimeEvent: Sendable {
    public let kind: ProxyRuntimeEventKind
    public let host: String?
    public let detail: String
    public let statusCode: Int?
    public init(kind: ProxyRuntimeEventKind, host: String? = nil, detail: String = "", statusCode: Int? = nil) {
        self.kind = kind; self.host = host; self.detail = detail; self.statusCode = statusCode
    }
}

enum ProxyFailureClassifier {
    static func event(error: Error, host: String?, tls: Bool) -> ProxyRuntimeEvent {
        let detail = String(describing: error)
        let lower = detail.lowercased()
        if lower.contains("timeout") || lower.contains("timed out") {
            if lower.contains("connect") { return ProxyRuntimeEvent(kind: .upstreamConnectTimeout, host: host, detail: detail) }
            if lower.contains("handshake") { return ProxyRuntimeEvent(kind: .upstreamTLSHandshakeTimeout, host: host, detail: detail) }
            return ProxyRuntimeEvent(kind: .upstreamTimeout, host: host, detail: detail)
        }
        if tls && (lower.contains("certificate") || lower.contains("cert verify") || lower.contains("unknown ca")) {
            return ProxyRuntimeEvent(kind: .upstreamCertificateFailure, host: host, detail: detail)
        }
        if tls && (lower.contains("tls") || lower.contains("ssl") || lower.contains("handshake") || lower.contains("alert")) {
            return ProxyRuntimeEvent(kind: .upstreamTLSFailure, host: host, detail: detail)
        }
        return ProxyRuntimeEvent(kind: .upstreamTCPFailure, host: host, detail: detail)
    }
}
