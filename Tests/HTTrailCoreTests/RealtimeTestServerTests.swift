import XCTest
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
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

    func testLoopbackRealtimeSessionsBypassConfiguredProxies() {
        let localURLs = [
            URL(string: "ws://127.0.0.1:9091/ws")!,
            URL(string: "http://localhost:9091/socket.io/")!,
            URL(string: "http://[::1]:9091/sse")!
        ]

        for url in localURLs {
            let config = RealtimeURLSession.configuration(for: url)
            let proxy = config.connectionProxyDictionary
            XCTAssertEqual(proxy?.isEmpty, true, "loopback realtime traffic should bypass proxies for \(url)")
        }

        let remote = URL(string: "wss://example.com/socket.io/")!
        XCTAssertNil(RealtimeURLSession.configuration(for: remote).connectionProxyDictionary)
    }

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

    func testWebSocketCommandReplies() async throws {
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
        client.send(text: "ping")
        client.send(text: "date")
        client.send(text: "uptime")
        try await Task.sleep(nanoseconds: 600_000_000)
        client.close()
        collector.cancel()

        let messages = received.all
        XCTAssertTrue(messages.contains("pong"), "no ping reply; got \(messages)")
        XCTAssertTrue(messages.contains(where: isTimestamp), "no date reply; got \(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("uptime ") && $0.hasSuffix("s") },
                      "no uptime reply; got \(messages)")
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

    func testSocketIOLocalServerCompletesHandshakeBeforeFirstEmit() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let client = SocketIOClient()
        let url = URL(string: "http://127.0.0.1:\(ports.httpPort)")!
        let events = Collector<SocketIOClient.Event>()
        let collector = Task {
            for await event in client.connect(to: url, handshakeTimeout: .milliseconds(300)) {
                events.add(event)
            }
        }

        try await Task.sleep(nanoseconds: 900_000_000)
        client.close()
        collector.cancel()

        var sawConnected = false
        var sawTimeout = false
        for event in events.all {
            switch event {
            case .connected:
                sawConnected = true
            case .error(let message) where message.contains("timed out"):
                sawTimeout = true
            default:
                break
            }
        }
        XCTAssertTrue(sawConnected, "local Socket.IO server never completed handshake; got \(events.all)")
        XCTAssertFalse(sawTimeout, "local Socket.IO server timed out during handshake; got \(events.all)")
    }

    /// The Realtime UI emits the typed message as the *payload* with a fixed
    /// event name ("message"), so "datetime" must be recognised in the payload —
    /// not only as the event name — to match the WebSocket / MQTT behaviour.
    func testSocketIODatetimeByPayload() async throws {
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
        client.emit(event: "message", payload: "datetime")
        try await Task.sleep(nanoseconds: 400_000_000)
        client.close()
        collector.cancel()

        let all = messages.all
        XCTAssertTrue(all.contains { isTimestamp($0.last ?? "") },
                      "socket.io datetime-by-payload failed; got \(all)")
    }

    func testSocketIOCommandReplies() async throws {
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
        client.emit(event: "message", payload: "ping")
        client.emit(event: "message", payload: "date")
        client.emit(event: "message", payload: "uptime")
        try await Task.sleep(nanoseconds: 700_000_000)
        client.close()
        collector.cancel()

        let all = messages.all
        XCTAssertTrue(all.contains { $0.first == "message" && $0.last == "pong" },
                      "socket.io ping failed; got \(all)")
        XCTAssertTrue(all.contains { isTimestamp($0.last ?? "") },
                      "socket.io date failed; got \(all)")
        XCTAssertTrue(all.contains { ($0.last ?? "").hasPrefix("uptime ") && ($0.last ?? "").hasSuffix("s") },
                      "socket.io uptime failed; got \(all)")
    }

    func testSocketIOHandshakeTimesOutIfServerNeverOpens() async throws {
        let server = SilentWebSocketServer()
        let port = try server.start()
        defer { server.stop() }

        let client = SocketIOClient()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let events = Collector<SocketIOClient.Event>()
        let collector = Task {
            for await event in client.connect(to: url, handshakeTimeout: .milliseconds(200)) {
                events.add(event)
            }
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        client.close()
        collector.cancel()

        let descriptions = events.all.map { "\($0)" }
        XCTAssertTrue(descriptions.contains { $0.contains("timed out") },
                      "socket.io handshake should time out; got \(descriptions)")
    }

    func testSocketIOEmitQuotesStringPayloads() {
        XCTAssertEqual(SocketIOClient.encodeEventPacket(event: "message", payload: "hello"),
                       #"42["message","hello"]"#)
        XCTAssertEqual(SocketIOClient.encodeEventPacket(event: "message", payload: "a \"quote\""),
                       #"42["message","a \"quote\""]"#)
        XCTAssertEqual(SocketIOClient.encodeEventPacket(event: "message", payload: ""),
                       #"42["message",""]"#)
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

private final class SilentWebSocketServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    func start() throws -> Int {
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture([:])
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(SilentWebSocketHandler())
            }
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                    upgraders: [upgrader],
                    completionHandler: { _ in }
                ))
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let serverChannel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = serverChannel
        return serverChannel.localAddress!.port!
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class SilentWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
}
