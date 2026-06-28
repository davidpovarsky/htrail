import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal WebSocket client backed by `URLSessionWebSocketTask`, exposing a
/// stream of events for the Hoppscotch-style realtime tab.
public final class WebSocketClient: NSObject, @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case text(String)
        case binary(Data)
        case disconnected(String?)
        case error(String)
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var continuation: AsyncStream<Event>.Continuation?
    private let lock = NSLock()

    public override init() { super.init() }

    public func connect(to url: URL, protocols: [String] = []) -> AsyncStream<Event> {
        let session = RealtimeURLSession.session(for: url)
        let task = protocols.isEmpty ? session.webSocketTask(with: url)
                                     : session.webSocketTask(with: url, protocols: protocols)
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()

        return AsyncStream { continuation in
            self.lock.lock(); self.continuation = continuation; self.lock.unlock()
            task.resume()
            continuation.yield(.connected)
            self.receiveLoop(task: task, continuation: continuation)
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
                self.finishSession(for: task)
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, continuation: AsyncStream<Event>.Continuation) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): continuation.yield(.text(text))
                case .data(let data): continuation.yield(.binary(data))
                @unknown default: break
                }
                self?.receiveLoop(task: task, continuation: continuation)
            case .failure(let error):
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
                self?.finishSession(for: task)
            }
        }
    }

    public func send(text: String) {
        lock.lock(); let task = self.task; lock.unlock()
        task?.send(.string(text)) { _ in }
    }

    public func send(data: Data) {
        lock.lock(); let task = self.task; lock.unlock()
        task?.send(.data(data)) { _ in }
    }

    public func close() {
        lock.lock()
        let task = self.task
        let cont = self.continuation
        let session = self.session
        self.task = nil
        self.continuation = nil
        self.session = nil
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        cont?.yield(.disconnected(nil))
        cont?.finish()
        session?.invalidateAndCancel()
    }

    private func finishSession(for task: URLSessionWebSocketTask) {
        lock.lock()
        guard self.task === task else { lock.unlock(); return }
        let session = self.session
        self.task = nil
        self.continuation = nil
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }
}
