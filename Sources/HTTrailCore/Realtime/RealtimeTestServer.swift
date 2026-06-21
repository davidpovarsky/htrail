import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// An in-process test server for the Realtime tab. It speaks all four realtime
/// protocols on localhost and implements two behaviours everywhere:
///
/// - **echo** — sends back whatever you send.
/// - **datetime** — when you send `datetime` / `time` / `now`, replies with the
///   current timestamp. (`stream` / `stop` toggle a 1 s datetime ticker on
///   WebSocket; SSE streams the datetime continuously since it's receive-only.)
///
/// This lets you exercise WebSocket / Socket.IO / SSE / MQTT without depending
/// on public echo endpoints or brokers. One HTTP listener serves `/ws`,
/// `/socket.io/` and `/sse`; a second TCP listener is a minimal MQTT broker.
public final class RealtimeTestServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var httpChannel: Channel?
    private var mqttChannel: Channel?

    public init() {}

    public struct Ports: Sendable {
        public let httpPort: Int
        public let mqttPort: Int
    }

    /// Binds both listeners on `127.0.0.1` (OS-assigned ports) and returns them.
    @discardableResult
    public func start() throws -> Ports {
        let httpPort = try startHTTP()
        let mqttPort = try startMQTT()
        return Ports(httpPort: httpPort, mqttPort: mqttPort)
    }

    public func stop() {
        try? httpChannel?.close().wait()
        try? mqttChannel?.close().wait()
        httpChannel = nil
        mqttChannel = nil
        try? group.syncShutdownGracefully()
    }

    private func startHTTP() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { ch, _ in ch.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { ch, head in
                        // Route by path: Socket.IO (Engine.IO v4) vs plain echo.
                        let handler: ChannelHandler = head.uri.hasPrefix("/socket.io")
                            ? SocketIOTestHandler() : EchoWebSocketHandler()
                        // The plain-HTTP handler must be removed once we've upgraded,
                        // otherwise it tries to decode WebSocket frames as HTTP.
                        return ch.pipeline.removeHandler(name: "sse-http")
                            .flatMapError { _ in ch.eventLoop.makeSucceededVoidFuture() }
                            .flatMap { ch.pipeline.addHandler(handler) }
                    })
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMap {
                    // Non-upgrade requests (e.g. GET /sse) land here.
                    channel.pipeline.addHandler(SSEHTTPHandler(), name: "sse-http")
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        httpChannel = channel
        return channel.localAddress?.port ?? 0
    }

    private func startMQTT() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MQTTFrameDecoder()),
                    MQTTBrokerHandler()
                ])
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        mqttChannel = channel
        return channel.localAddress?.port ?? 0
    }
}

/// Current time as an ISO-8601 string with millisecond precision.
private func nowTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

// MARK: - WebSocket echo

/// Echoes text frames; replies with the time for `datetime`/`time`/`now`, and
/// streams the time on `stream` (until `stop`).
final class EchoWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private var ticker: RepeatedTask?

    func channelActive(context: ChannelHandlerContext) {
        sendText("HTTrail test server ready — send any text to echo, or 'datetime' / 'stream'.",
                 context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            handle(buffer.readString(length: buffer.readableBytes) ?? "", context: context)
        case .binary:
            // Echo binary frames straight back.
            let frameOut = WebSocketFrame(fin: true, opcode: .binary, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(frameOut), promise: nil)
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            ticker?.cancel()
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) { ticker?.cancel() }

    private func handle(_ text: String, context: ChannelHandlerContext) {
        switch text.lowercased() {
        case "datetime", "time", "now":
            sendText(nowTimestamp(), context: context)
        case "stream", "time stream", "datetime stream":
            ticker?.cancel()
            ticker = context.eventLoop.scheduleRepeatedTask(initialDelay: .zero, delay: .seconds(1)) { [weak self] _ in
                self?.sendText(nowTimestamp(), context: context)
            }
        case "stop", "time stop":
            ticker?.cancel(); ticker = nil
            sendText("stream stopped", context: context)
        default:
            sendText(text, context: context)
        }
    }

    private func sendText(_ text: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
}

// MARK: - Socket.IO (Engine.IO v4)

/// A minimal Socket.IO server matching `SocketIOClient`: Engine.IO open/connect
/// handshake, then echo events back (and reply with the time for `datetime`).
final class SocketIOTestHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelActive(context: ChannelHandlerContext) {
        // Engine.IO OPEN packet (the client only checks the leading "0").
        send("0{\"sid\":\"httrail-test\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}",
             context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text else {
            if frame.opcode == .connectionClose { context.close(promise: nil) }
            return
        }
        var buffer = frame.unmaskedData
        let packet = buffer.readString(length: buffer.readableBytes) ?? ""
        guard let first = packet.first else { return }
        switch first {
        case "2":                              // Engine.IO ping → pong
            send("3", context)
        case "4":                              // Engine.IO message
            let rest = packet.dropFirst()
            guard let sioType = rest.first else { return }
            switch sioType {
            case "0":                          // Socket.IO CONNECT → ack
                send("40{\"sid\":\"httrail-test\"}", context)
            case "1":                          // Socket.IO DISCONNECT
                context.close(promise: nil)
            case "2":                          // Socket.IO EVENT
                let (name, payload) = Self.parseEvent(String(rest.dropFirst()))
                let responsePayload = ["datetime", "time", "now"].contains(name.lowercased())
                    ? nowTimestamp() : payload
                send(encodeEvent(name, responsePayload), context)
            default:
                break
            }
        default:
            break
        }
    }

    /// Build a valid Socket.IO EVENT packet: `42["name","payload"]`.
    private func encodeEvent(_ name: String, _ payload: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [name, payload]),
           let json = String(data: data, encoding: .utf8) {
            return "42" + json
        }
        return "42[\"\(name)\"]"
    }

    /// Tolerantly extract `(name, payload)` from an EVENT body such as
    /// `["echo","hi"]`, `/ns,["echo",hi]` or `["datetime"]`. The client emits
    /// the payload verbatim (sometimes not JSON-quoted), so be lenient.
    static func parseEvent(_ body: String) -> (String, String) {
        let arrayText = String(body.drop { $0 != "[" })
        var name = "message"
        if let range = arrayText.range(of: #""((?:\\.|[^"\\])*)""#, options: .regularExpression) {
            name = String(arrayText[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        var payload = ""
        if let comma = arrayText.firstIndex(of: ",") {
            var tail = String(arrayText[arrayText.index(after: comma)...])
            if tail.hasSuffix("]") { tail.removeLast() }
            tail = tail.trimmingCharacters(in: .whitespaces)
            if tail.count >= 2, tail.hasPrefix("\""), tail.hasSuffix("\"") {
                tail = String(tail.dropFirst().dropLast())
            }
            payload = tail
        }
        return (name, payload)
    }

    private func send(_ text: String, _ context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
}

// MARK: - SSE + plain HTTP

/// Handles non-upgraded HTTP requests: streams a datetime event every second on
/// `/sse`, and returns a short description for anything else.
final class SSEHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var requestHead: HTTPRequestHead?
    private var ticker: RepeatedTask?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            if head.uri.hasPrefix("/sse") {
                startSSE(context: context)
            } else {
                respondPlain(context: context, keepAlive: head.isKeepAlive)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) { ticker?.cancel() }

    private func startSSE(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        writeChunk(": connected to HTTrail test server\n\n", context: context)
        writeChunk("event: hello\ndata: streaming datetime every second\n\n", context: context)
        ticker = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { [weak self] _ in
            self?.writeChunk("event: datetime\ndata: \(nowTimestamp())\n\n", context: context)
        }
    }

    private func writeChunk(_ string: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func respondPlain(context: ChannelHandlerContext, keepAlive: Bool) {
        let body = "HTTrail realtime test server. Endpoints: /ws (WebSocket echo), /socket.io/ (Socket.IO), /sse (datetime stream)."
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { context.close(promise: nil) }
        }
    }
}

// MARK: - MQTT broker

/// A single-connection MQTT 3.1.1 broker: CONNACK/SUBACK, then loops published
/// messages back to the same connection's subscriptions (echo), replying with
/// the time for a `datetime`/`time` payload. Reuses the client's `MQTTCodec` /
/// `MQTTFrameDecoder`.
final class MQTTBrokerHandler: ChannelInboundHandler {
    typealias InboundIn = MQTTPacket
    typealias OutboundOut = ByteBuffer
    private var subscriptions: [String] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        switch packet.type {
        case 1: // CONNECT → CONNACK
            var buffer = context.channel.allocator.buffer(capacity: 4)
            MQTTCodec.writeFixedHeader(type: 2, flags: 0, length: 2, to: &buffer)
            buffer.writeInteger(UInt8(0)) // no session present
            buffer.writeInteger(UInt8(0)) // connection accepted
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)

        case 8: // SUBSCRIBE → SUBACK
            guard let packetID = packet.bytes.readInteger(as: UInt16.self) else { return }
            var returnCodes: [UInt8] = []
            while packet.bytes.readableBytes > 0 {
                guard let length = packet.bytes.readInteger(as: UInt16.self),
                      let topic = packet.bytes.readString(length: Int(length)) else { break }
                _ = packet.bytes.readInteger(as: UInt8.self) // requested QoS
                subscriptions.append(topic)
                returnCodes.append(0x00) // granted QoS 0
            }
            var payload = context.channel.allocator.buffer(capacity: 2 + returnCodes.count)
            payload.writeInteger(packetID)
            for code in returnCodes { payload.writeInteger(code) }
            var buffer = context.channel.allocator.buffer(capacity: payload.readableBytes + 2)
            MQTTCodec.writeFixedHeader(type: 9, flags: 0, length: payload.readableBytes, to: &buffer)
            buffer.writeBuffer(&payload)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)

        case 3: // PUBLISH (QoS 0) → deliver to matching subscriptions (echo)
            guard let length = packet.bytes.readInteger(as: UInt16.self),
                  let topic = packet.bytes.readString(length: Int(length)) else { return }
            let message = packet.bytes.readString(length: packet.bytes.readableBytes) ?? ""
            let out = ["datetime", "time", "now"].contains(message.lowercased()) ? nowTimestamp() : message
            if subscriptions.contains(where: { matches(filter: $0, topic: topic) }) {
                deliver(topic: topic, message: out, context: context)
            }

        case 12: // PINGREQ → PINGRESP
            var buffer = context.channel.allocator.buffer(capacity: 2)
            MQTTCodec.writeFixedHeader(type: 13, flags: 0, length: 0, to: &buffer)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)

        case 14: // DISCONNECT
            context.close(promise: nil)

        default:
            break
        }
    }

    private func matches(filter: String, topic: String) -> Bool {
        if filter == topic || filter == "#" { return true }
        if filter.hasSuffix("/#") { return topic.hasPrefix(String(filter.dropLast())) }
        return false
    }

    private func deliver(topic: String, message: String, context: ChannelHandlerContext) {
        var payload = context.channel.allocator.buffer(capacity: topic.utf8.count + message.utf8.count + 2)
        MQTTCodec.writeString(topic, to: &payload)
        payload.writeString(message)
        var buffer = context.channel.allocator.buffer(capacity: payload.readableBytes + 2)
        MQTTCodec.writeFixedHeader(type: 3, flags: 0, length: payload.readableBytes, to: &buffer)
        buffer.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
