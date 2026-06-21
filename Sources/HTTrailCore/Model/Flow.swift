import Foundation

/// A single name/value header pair preserving order & duplicates (unlike a dict).
public struct HeaderPair: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(name): \(value)" }
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CapturedRequest: Sendable, Codable {
    public var method: String
    public var url: String
    public var scheme: String
    public var host: String
    public var port: Int
    public var path: String
    public var httpVersion: String
    public var headers: [HeaderPair]
    public var body: Data
    public var timestamp: Date

    public init(method: String, url: String, scheme: String, host: String, port: Int,
                path: String, httpVersion: String, headers: [HeaderPair], body: Data, timestamp: Date) {
        self.method = method
        self.url = url
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.timestamp = timestamp
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct CapturedResponse: Sendable, Codable {
    public var statusCode: Int
    public var reasonPhrase: String
    public var httpVersion: String
    public var headers: [HeaderPair]
    public var body: Data
    public var timestamp: Date
    /// True when `body` holds only a prefix of the real response (the proxy
    /// streamed the full body to the client but capped what it kept for capture
    /// to bound memory). Optional so older persisted flows decode unchanged.
    public var bodyTruncated: Bool?

    public init(statusCode: Int, reasonPhrase: String, httpVersion: String,
                headers: [HeaderPair], body: Data, timestamp: Date,
                bodyTruncated: Bool? = nil) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.timestamp = timestamp
        self.bodyTruncated = bodyTruncated
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var contentType: String? { header("Content-Type") }
}

public enum FlowState: String, Sendable, Codable {
    case pending
    case completed
    case failed
}

/// One captured request/response transaction, the row unit of the Charles-style
/// inspector. Value type so it crosses the actor boundary into the UI cleanly.
public struct Flow: Sendable, Codable, Identifiable {
    public let id: UUID
    public var request: CapturedRequest
    public var response: CapturedResponse?
    public var state: FlowState
    public var error: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// Whether this flow was decrypted via MITM (https) or plain http.
    public var secure: Bool
    /// The capture session this flow belongs to (nil for legacy/unsessioned flows).
    public var sessionID: UUID?

    public init(id: UUID = UUID(), request: CapturedRequest, response: CapturedResponse? = nil,
                state: FlowState = .pending, error: String? = nil, startedAt: Date,
                endedAt: Date? = nil, secure: Bool, sessionID: UUID? = nil) {
        self.id = id
        self.request = request
        self.response = response
        self.state = state
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.secure = secure
        self.sessionID = sessionID
    }

    public var durationMS: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }

    public var statusCode: Int? { response?.statusCode }
}

/// Sink the proxy emits flows to. Implemented by the UI store. Sendable so the
/// NIO event loops can call it from any thread.
public protocol FlowSink: Sendable {
    func record(_ flow: Flow)
}
