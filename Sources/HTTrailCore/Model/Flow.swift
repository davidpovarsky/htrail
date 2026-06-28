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

/// One captured WebSocket frame on an upgraded connection. Text frames carry
/// UTF-8 in `data`; binary frames are rendered as hex. Control frames
/// (ping/pong/close) are captured too, mirroring Chrome DevTools' frame list.
public struct WebSocketMessage: Sendable, Codable, Identifiable {
    public enum Direction: String, Sendable, Codable {
        case sent       // client → server
        case received   // server → client
    }
    public enum Kind: String, Sendable, Codable {
        case text, binary, ping, pong, close
    }
    public let id: UUID
    public let direction: Direction
    public let kind: Kind
    public let data: Data
    public let timestamp: Date
    /// True when `data` holds only a prefix of the frame (large frame capped to
    /// bound memory). The frame was still forwarded to the peer in full.
    public var truncated: Bool

    public init(id: UUID = UUID(), direction: Direction, kind: Kind, data: Data,
                timestamp: Date, truncated: Bool = false) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.data = data
        self.timestamp = timestamp
        self.truncated = truncated
    }

    /// UTF-8 rendering for text frames (nil if the bytes aren't valid UTF-8).
    public var text: String? { String(data: data, encoding: .utf8) }
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
    /// Frames captured on an upgraded WebSocket connection, in arrival order.
    /// Optional so older persisted flows decode unchanged; nil for normal HTTP.
    public var webSocketMessages: [WebSocketMessage]?

    public init(id: UUID = UUID(), request: CapturedRequest, response: CapturedResponse? = nil,
                state: FlowState = .pending, error: String? = nil, startedAt: Date,
                endedAt: Date? = nil, secure: Bool, sessionID: UUID? = nil,
                webSocketMessages: [WebSocketMessage]? = nil) {
        self.id = id
        self.request = request
        self.response = response
        self.state = state
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.secure = secure
        self.sessionID = sessionID
        self.webSocketMessages = webSocketMessages
    }

    public var durationMS: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }

    public var statusCode: Int? { response?.statusCode }

    /// True once this flow has been upgraded to WebSocket (101) or has frames.
    public var isWebSocket: Bool {
        webSocketMessages != nil || response?.statusCode == 101
    }
}

/// Sink the proxy emits flows to. Implemented by the UI store. Sendable so the
/// NIO event loops can call it from any thread.
public protocol FlowSink: Sendable {
    func record(_ flow: Flow)
}
