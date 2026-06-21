import XCTest
import Foundation
@testable import HTTrailCore

/// Thread-safe collector so the consuming `Task` and the test body can share a
/// growing list under Swift 6 strict concurrency.
private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private func isTimestamp(_ s: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: s) != nil
}

/// Verifies the in-process `RealtimeTestServer` (echo + datetime) speaks all four
/// realtime protocols correctly, by driving the real clients against it over
/// loopback. No external network — fast and deterministic.
final class RealtimeTestServerTests: XCTestCase {

    func testWebSocketEchoAndDatetime() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let client = WebSocketClient()
        let url = URL(string: "ws://127.0.0.1:\(ports.httpPort)/ws")!
        let received = Collector<String>()
        let collector = Task {
            for await event in client.connect(to: url) {
                if case .text(let text) = event { received.add(text) }
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        client.send(text: "datetime")
        try await Task.sleep(nanoseconds: 300_000_000)
        client.send(text: "echo-me-123")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.close()
        collector.cancel()

        let messages = received.all
        XCTAssertTrue(messages.contains("echo-me-123"), "echo failed; got \(messages)")
        XCTAssertTrue(messages.contains(where: isTimestamp), "no datetime reply; got \(messages)")
    }

    func testSSEStreamsDatetime() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let client = SSEClient()
        let url = URL(string: "http://127.0.0.1:\(ports.httpPort)/sse")!
        let events = Collector<SSEEvent>()
        let collector = Task {
            do {
                for try await event in client.connect(to: url) {
                    events.add(event)
                    if events.count >= 2 { break }
                }
            } catch {}
        }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        collector.cancel()

        let all = events.all
        XCTAssertTrue(all.contains { $0.event == "datetime" && isTimestamp($0.data) },
                      "no datetime SSE event; got \(all.map { "\($0.event)=\($0.data)" })")
    }

    func testSocketIOEchoAndDatetime() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let client = SocketIOClient()
        let url = URL(string: "http://127.0.0.1:\(ports.httpPort)")!
        let messages = Collector<[String]>()
        let collector = Task {
            for await event in client.connect(to: url) {
                if case .message(let name, let payload) = event { messages.add([name, payload]) }
            }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        client.emit(event: "echo", payload: "hi-sio")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.emit(event: "datetime", payload: "")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.close()
        collector.cancel()

        let all = messages.all
        XCTAssertTrue(all.contains { $0.first == "echo" && $0.last == "hi-sio" },
                      "socket.io echo failed; got \(all)")
        XCTAssertTrue(all.contains { $0.first == "datetime" && isTimestamp($0.last ?? "") },
                      "socket.io datetime failed; got \(all)")
    }

    func testMQTTEchoAndDatetime() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let client = MQTTClient()
        let topic = "httrail/test"
        let messages = Collector<[String]>()
        let collector = Task {
            for await event in client.connect(host: "127.0.0.1", port: ports.mqttPort) {
                switch event {
                case .connected: client.subscribe(topic: topic)
                case .message(let t, let p): messages.add([t, p])
                default: break
                }
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        client.publish(topic: topic, message: "mqtt-echo-1")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.publish(topic: topic, message: "datetime")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.close()
        collector.cancel()

        let all = messages.all
        XCTAssertTrue(all.contains { $0.first == topic && $0.last == "mqtt-echo-1" },
                      "mqtt echo failed; got \(all)")
        XCTAssertTrue(all.contains { isTimestamp($0.last ?? "") },
                      "mqtt datetime failed; got \(all)")
    }
}
