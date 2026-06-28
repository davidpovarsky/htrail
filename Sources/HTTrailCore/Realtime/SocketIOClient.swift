import Foundation
import Dispatch
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
    private var session: URLSession?
    private var continuation: AsyncStream<Event>.Continuation?
    private var handshakeTimer: DispatchSourceTimer?
    private var handshakeComplete = false
    private let lock = NSLock()

    public override init() { super.init() }

    /// `baseURL` may be http(s) or ws(s); the Socket.IO path/query is appended.
    public func connect(
        to baseURL: URL,
        namespace: String = "/",
        handshakeTimeout: DispatchTimeInterval = .seconds(5)
    ) -> AsyncStream<Event> {
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
        let url = components?.url ?? baseURL

        let session = RealtimeURLSession.session(for: url)
        let task = session.webSocketTask(with: url)
        lock.lock()
        self.session = session
        self.task = task
        self.handshakeComplete = false
        lock.unlock()

        return AsyncStream { continuation in
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
            self.startHandshakeTimer(interval: handshakeTimeout, task: task, continuation: continuation)
            task.resume()
            self.receiveLoop(task: task, namespace: namespace, continuation: continuation)
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
                self.finishSession(for: task)
            }
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
                self.finishSession(for: task)
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
            case "0":
                markHandshakeComplete()
                continuation.yield(.connected)
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
        task?.send(.string(Self.encodeEventPacket(event: event, payload: payload))) { _ in }
    }

    static func encodeEventPacket(event: String, payload: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [event, payload]),
           let json = String(data: data, encoding: .utf8) {
            return "42" + json
        }
        return "42[\"\(event)\",\"\(payload)\"]"
    }

    public func close() {
        lock.lock()
        let task = self.task
        let cont = self.continuation
        let session = self.session
        let timer = self.handshakeTimer
        self.task = nil
        self.continuation = nil
        self.session = nil
        self.handshakeTimer = nil
        self.handshakeComplete = false
        lock.unlock()
        timer?.cancel()
        task?.send(.string("41")) { _ in }            // Socket.IO disconnect
        task?.cancel(with: .normalClosure, reason: nil)
        cont?.yield(.disconnected)
        cont?.finish()
        session?.invalidateAndCancel()
    }

    private static func stringify(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) { return string }
        return "\(value)"
    }

    private func startHandshakeTimer(
        interval: DispatchTimeInterval,
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<Event>.Continuation
    ) {
        if case .never = interval {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.task === task && !self.handshakeComplete
            self.lock.unlock()
            guard active else { return }
            continuation.yield(.error("Socket.IO handshake timed out"))
            continuation.finish()
            task.cancel(with: .goingAway, reason: nil)
            self.finishSession(for: task)
        }
        lock.lock()
        handshakeTimer?.cancel()
        handshakeTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func markHandshakeComplete() {
        lock.lock()
        handshakeComplete = true
        let timer = handshakeTimer
        handshakeTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func finishSession(for task: URLSessionWebSocketTask) {
        lock.lock()
        guard self.task === task else { lock.unlock(); return }
        let session = self.session
        let timer = self.handshakeTimer
        self.task = nil
        self.continuation = nil
        self.session = nil
        self.handshakeTimer = nil
        self.handshakeComplete = false
        lock.unlock()
        timer?.cancel()
        session?.invalidateAndCancel()
    }
}
