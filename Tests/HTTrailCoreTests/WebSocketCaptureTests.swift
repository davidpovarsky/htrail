import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
@testable import HTTrailCore

/// Drives a real WebSocket connection through the proxy to the bundled echo
/// server and asserts both directions (text + binary) are captured onto the Flow.
final class WebSocketCaptureTests: XCTestCase {

    func testWebSocketFramesCapturedThroughProxy() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let ca = try CertificateAuthority.create()
        let sink = CollectingSink()
        let proxyPort = 19_096
        let proxy = ProxyServer(port: proxyPort, certificateAuthority: ca, sink: sink)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let collector = WSFrameCollector()
        let upgraded = group.next().makePromise(of: Channel.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawWSUpgradeClient(
                    host: "127.0.0.1:\(ports.httpPort)", path: "/ws",
                    collector: collector, upgraded: upgraded))
            }
        let channel = try await bootstrap.connect(host: "127.0.0.1", port: proxyPort).get()

        let ws = try await upgraded.futureResult.get()
        try await sendFrame(ws, opcode: .text, bytes: Array("hello-ws".utf8))
        try await sendFrame(ws, opcode: .binary, bytes: [0xDE, 0xAD, 0xBE, 0xEF])

        // Wait for the echoes plus the capture's ~200ms coalesced re-record.
        try await Task.sleep(nanoseconds: 900_000_000)

        let wsFlow = sink.flows
            .filter { $0.isWebSocket }
            .max { ($0.webSocketMessages?.count ?? 0) < ($1.webSocketMessages?.count ?? 0) }
        let flow = try XCTUnwrap(wsFlow, "Expected a captured WebSocket flow")
        XCTAssertEqual(flow.statusCode, 101)
        let msgs = flow.webSocketMessages ?? []

        XCTAssertTrue(msgs.contains { $0.direction == .sent && $0.kind == .text && $0.text == "hello-ws" },
                      "client→server text frame should be captured")
        XCTAssertTrue(msgs.contains { $0.direction == .received && $0.kind == .text && $0.text == "hello-ws" },
                      "server→client echoed text frame should be captured")
        XCTAssertTrue(msgs.contains { $0.direction == .sent && $0.kind == .binary && $0.data == Data([0xDE, 0xAD, 0xBE, 0xEF]) },
                      "client→server binary frame should be captured")
        XCTAssertTrue(msgs.contains { $0.direction == .received && $0.kind == .binary && $0.data == Data([0xDE, 0xAD, 0xBE, 0xEF]) },
                      "server→client echoed binary frame should be captured")

        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    /// A long-lived, server-initiated stream must stay up: the echo server's
    /// `stream` command pushes a text frame every second until told to stop. This
    /// catches a connection that the proxy interrupts after the first exchange.
    func testWebSocketStreamStaysAlive() async throws {
        let server = RealtimeTestServer()
        let ports = try server.start()
        defer { server.stop() }

        let ca = try CertificateAuthority.create()
        let sink = CollectingSink()
        let proxyPort = 19_094
        let proxy = ProxyServer(port: proxyPort, certificateAuthority: ca, sink: sink)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let collector = WSFrameCollector()
        let upgraded = group.next().makePromise(of: Channel.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawWSUpgradeClient(
                    host: "127.0.0.1:\(ports.httpPort)", path: "/ws",
                    collector: collector, upgraded: upgraded))
            }
        let channel = try await bootstrap.connect(host: "127.0.0.1", port: proxyPort).get()
        let ws = try await upgraded.futureResult.get()

        // Ask the server to stream a frame every second.
        try await sendFrame(ws, opcode: .text, bytes: Array("stream".utf8))
        try await Task.sleep(nanoseconds: 3_500_000_000)

        let flow = try XCTUnwrap(sink.flows.filter { $0.isWebSocket }
            .max { ($0.webSocketMessages?.count ?? 0) < ($1.webSocketMessages?.count ?? 0) })
        let received = (flow.webSocketMessages ?? []).filter { $0.direction == .received && $0.kind == .text }
        XCTAssertGreaterThanOrEqual(received.count, 3,
            "expected several streamed frames; got \(received.count) — connection was interrupted")
        XCTAssertNotEqual(flow.state, .failed, "connection should not have failed")

        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    /// The capture must bound retained frame bytes so the whole-flow re-record
    /// (which the iOS sink rewrites atomically each time) can't blow the Packet
    /// Tunnel extension's memory budget and drop the VPN.
    func testCaptureEvictsOldFramesToStayBounded() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let sink = CollectingSink()
        let req = CapturedRequest(method: "GET", url: "ws://x/", scheme: "ws", host: "x",
                                  port: 80, path: "/", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = CapturedResponse(statusCode: 101, reasonPhrase: "Switching Protocols",
                                    httpVersion: "HTTP/1.1", headers: [], body: Data(), timestamp: Date())
        let cap = 256 * 1024
        let capture = WebSocketCapture(flowID: UUID(), request: req, response: resp,
                                       startedAt: Date(), secure: false, sink: sink, eventLoop: loop,
                                       perMessageCap: 64 * 1024, messageCap: 1500, totalBytesCap: cap)

        try loop.submit {
            var buf = ByteBufferAllocator().buffer(capacity: 64 * 1024)
            buf.writeBytes([UInt8](repeating: 0xAB, count: 64 * 1024))
            for _ in 0..<100 {   // 100 × 64KB = 6.4MB streamed in
                capture.append(direction: .received, opcode: .binary, payload: buf, now: Date())
            }
            capture.finish(now: Date())
        }.wait()

        let flow = try XCTUnwrap(sink.flows.last)
        let retained = (flow.webSocketMessages ?? []).reduce(0) { $0 + $1.data.count }
        XCTAssertLessThanOrEqual(retained, cap, "retained WS bytes must stay within the cap")
        XCTAssertFalse((flow.webSocketMessages ?? []).isEmpty, "recent frames are kept")
    }

    private func sendFrame(_ channel: Channel, opcode: WebSocketOpcode, bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let mask = WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: .min ... .max) })!
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: opcode, maskKey: mask, data: buffer))
    }
}

enum WSTestError: Error { case notUpgraded(String) }

/// Minimal raw WebSocket client: writes an origin-form upgrade (so it routes
/// through the plain-HTTP proxy path), and on `101` splices the NIO WS codecs in
/// and fulfils `upgraded` with the channel.
final class RawWSUpgradeClient: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let host: String
    private let path: String
    private let collector: WSFrameCollector
    private let upgraded: EventLoopPromise<Channel>
    private var acc = ByteBuffer()
    private var done = false

    init(host: String, path: String, collector: WSFrameCollector, upgraded: EventLoopPromise<Channel>) {
        self.host = host
        self.path = path
        self.collector = collector
        self.upgraded = upgraded
    }

    func channelActive(context: ChannelHandlerContext) {
        var b = context.channel.allocator.buffer(capacity: 256)
        b.writeString("GET \(path) HTTP/1.1\r\n")
        b.writeString("Host: \(host)\r\n")
        b.writeString("Upgrade: websocket\r\n")
        b.writeString("Connection: Upgrade\r\n")
        b.writeString("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n")
        b.writeString("Sec-WebSocket-Version: 13\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(b), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { context.fireChannelRead(data); return }
        var part = unwrapInboundIn(data)
        acc.writeBuffer(&part)
        let bytes = acc.getBytes(at: acc.readerIndex, length: acc.readableBytes) ?? []
        guard let idx = Self.headerEnd(bytes) else { return }
        done = true
        let header = String(decoding: bytes[0..<idx], as: UTF8.self)
        guard header.contains(" 101 ") else {
            upgraded.fail(WSTestError.notUpgraded(header)); context.close(promise: nil); return
        }
        // Validate the accept exactly as a real client would. RFC 6455's example
        // key "dGhlIHNhbXBsZSBub25jZQ==" must yield this accept; a wrong value
        // makes a real browser reject the handshake (appears as an interruption).
        guard header.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") else {
            upgraded.fail(WSTestError.notUpgraded("bad accept:\n\(header)")); context.close(promise: nil); return
        }
        let leftover = Array(bytes[(idx + 4)...])
        let channel = context.channel
        let decoder = ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 20))
        let encoder = WebSocketFrameEncoder()
        channel.pipeline.addHandlers([decoder, encoder, collector])
            .flatMap { channel.pipeline.removeHandler(self) }
            .whenComplete { _ in
                if !leftover.isEmpty {
                    var lb = channel.allocator.buffer(capacity: leftover.count)
                    lb.writeBytes(leftover)
                    channel.pipeline.fireChannelRead(NIOAny(lb))
                }
                self.upgraded.succeed(channel)
            }
    }

    /// Index of the start of the CRLF-CRLF that ends the HTTP head, or nil.
    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i+1] == 10 && bytes[i+2] == 13 && bytes[i+3] == 10 {
            return i
        }
        return nil
    }
}

/// Drains inbound frames so the client keeps reading echoes (and the proxy keeps
/// relaying/capturing them).
final class WSFrameCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        _ = unwrapInboundIn(data)
    }
}
