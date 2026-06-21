import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal Socket.IO client (Engine.IO v4 over WebSocket): handshake, ping/pong
/// keepalive, namespace connect, and EVENT emit/receive — enough for the
/// Hoppscotch "Socket.IO" realtime tab.
public final class SocketIOClient: NSObject, @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case message(name: String, payload: String)
        case disconnected
        case error(String)
    }

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Event>.Continuation?
    private let lock = NSLock()

    public override init() { super.init() }

    /// `baseURL` may be http(s) or ws(s); the Socket.IO path/query is appended.
    public func connect(to baseURL: URL, namespace: String = "/") -> AsyncStream<Event> {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "http": components?.scheme = "ws"
        case "https": components?.scheme = "wss"
        default: break
        }
        if !(components?.path.contains("/socket.io") ?? false) {
            components?.path = "/socket.io/"
        }
        components?.queryItems = [URLQueryItem(name: "EIO", value: "4"),
                                  URLQueryItem(name: "transport", value: "websocket")]

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: components?.url ?? baseURL)
        lock.lock(); self.task = task; lock.unlock()

        return AsyncStream { continuation in
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
            task.resume()
            self.receiveLoop(task: task, namespace: namespace, continuation: continuation)
            continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, namespace: String,
                             continuation: AsyncStream<Event>.Continuation) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(packet: text, task: task, namespace: namespace, continuation: continuation)
                }
                self.receiveLoop(task: task, namespace: namespace, continuation: continuation)
            case .failure(let error):
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }
    }

    private func handle(packet: String, task: URLSessionWebSocketTask, namespace: String,
                        continuation: AsyncStream<Event>.Continuation) {
        guard let first = packet.first else { return }
        switch first {
        case "0": // Engine.IO open → connect to namespace
            let connectPacket = namespace == "/" ? "40" : "40\(namespace),"
            task.send(.string(connectPacket)) { _ in }
        case "2": // ping → pong
            task.send(.string("3")) { _ in }
        case "4": // Engine.IO message → inspect Socket.IO type
            let rest = String(packet.dropFirst())
            guard let sioType = rest.first else { return }
            let body = String(rest.dropFirst())
            switch sioType {
            case "0": continuation.yield(.connected)
            case "1": continuation.yield(.disconnected)
            case "2": // EVENT — body is a JSON array (possibly prefixed by namespace,)
                let json = body.drop { $0 != "[" }
                if let data = String(json).data(using: .utf8),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [Any], !array.isEmpty {
                    let name = array.first as? String ?? "message"
                    let payload = array.count > 1 ? Self.stringify(array[1]) : ""
                    continuation.yield(.message(name: name, payload: payload))
                }
            default: break
            }
        default: break
        }
    }

    public func emit(event: String, payload: String) {
        lock.lock(); let task = self.task; lock.unlock()
        let inner = payload.isEmpty ? "" : ",\(payload)"
        task?.send(.string("42[\"\(event)\"\(inner)]")) { _ in }
    }

    public func close() {
        lock.lock(); let task = self.task; let cont = self.continuation; lock.unlock()
        task?.send(.string("41")) { _ in }            // Socket.IO disconnect
        task?.cancel(with: .normalClosure, reason: nil)
        cont?.yield(.disconnected)
        cont?.finish()
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) { return string }
        return "\(value)"
    }
}
