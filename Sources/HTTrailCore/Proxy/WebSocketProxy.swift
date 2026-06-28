import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import Crypto

/// WebSocket capture for the MITM proxy.
///
/// When ``DecryptedProxyHandler`` sees a `GET` carrying `Upgrade: websocket`, it
/// hands the (already decrypted) client channel to ``WebSocketTunnel``. We replay
/// the handshake to the origin using NIO's own client upgrader — reusing the
/// *client's* `Sec-WebSocket-Key` so the origin's `Sec-WebSocket-Accept` still
/// validates for the real client — then, on `101`, splice both channels onto
/// WebSocket frame codecs. Every frame in either direction is decoded, recorded
/// onto the owning ``Flow`` (so the UI shows the message log à la Chrome
/// DevTools), and forwarded to the peer — text as text, binary as hex.
///
/// `permessage-deflate` is stripped from the forwarded handshake so frames stay
/// uncompressed and therefore inspectable (the same trade-off Charles/Proxyman
/// make). Both channels run on the client's event loop so the relay never crosses
/// loops.
enum WebSocketTunnel {
    /// Largest single frame we will decode/forward. Bounds the aggregator's
    /// buffer so a hostile peer can't exhaust the (tight, on iOS) memory budget.
    static let maxFrameSize = 8 * 1024 * 1024
    /// Cap on bytes retained *per message* for the recorded ``Flow`` (the frame is
    /// still forwarded in full); keeps a chatty socket from ballooning memory.
    static let defaultPerMessageCap = 64 * 1024
    /// Total bytes of captured frames retained per flow. The recorded ``Flow`` is
    /// re-emitted whole on every update and (on iOS) the sink rewrites the shared
    /// file atomically each time — so an unbounded history would blow the Packet
    /// Tunnel extension's ~50 MB budget and drop the VPN. Oldest frames are evicted
    /// past this; forwarding to the peer is never affected.
    static let totalBytesCap = 1 * 1024 * 1024
    /// Cap on retained messages; oldest are dropped past this (forwarding is
    /// unaffected).
    static let messageCap = 1500
    /// Largest number of fragments an aggregated message may span.
    static let maxFragments = 1024

    static func start(clientChannel: Channel,
                      clientProxyHandler: RemovableChannelHandler,
                      request: CapturedRequest,
                      target: UpstreamTarget,
                      flowID: UUID,
                      startedAt: Date,
                      secure: Bool,
                      sink: FlowSink,
                      group: EventLoopGroup,
                      verifyUpstream: Bool,
                      connectTimeout: TimeAmount,
                      perMessageCap: Int) {
        let eventLoop = clientChannel.eventLoop

        // The client's key is replayed to the origin so its computed accept is
        // valid for the real client (we hand that same accept back below).
        guard let clientKey = request.header("Sec-WebSocket-Key") else {
            sink.record(Flow(id: flowID, request: request, response: nil, state: .failed,
                             error: "Missing Sec-WebSocket-Key", startedAt: startedAt,
                             endedAt: Date(), secure: secure))
            clientChannel.close(promise: nil)
            return
        }

        // Hold reads on the client until its WS pipeline is spliced in, so the
        // first frames (sent the instant it sees our 101) don't hit a half-built
        // pipeline.
        _ = clientChannel.setOption(ChannelOptions.autoRead, value: false)

        // On a successful origin upgrade: record the open flow, install the
        // capture/aggregator on the origin, splice the client, and resume reads.
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: clientKey, maxFrameSize: maxFrameSize
        ) { originChannel, responseHead -> EventLoopFuture<Void> in
            let response = CapturedResponse(
                statusCode: Int(responseHead.status.code),
                reasonPhrase: responseHead.status.reasonPhrase,
                httpVersion: "HTTP/\(responseHead.version.major).\(responseHead.version.minor)",
                headers: responseHead.headers.map { HeaderPair(name: $0.name, value: $0.value) },
                body: Data(), timestamp: Date())
            let capture = WebSocketCapture(flowID: flowID, request: request, response: response,
                                           startedAt: startedAt, secure: secure, sink: sink,
                                           eventLoop: eventLoop, perMessageCap: perMessageCap,
                                           messageCap: messageCap, totalBytesCap: totalBytesCap)
            capture.recordNow(state: .pending)

            let originRelay = WebSocketRelayHandler(direction: .received, capture: capture,
                                                    partner: clientChannel, maskOutbound: false)
            let clientRelay = WebSocketRelayHandler(direction: .sent, capture: capture,
                                                    partner: originChannel, maskOutbound: true)

            return originChannel.pipeline.addHandlers([aggregator(), originRelay])
                .flatMap {
                    spliceClient(clientChannel, proxyHandler: clientProxyHandler,
                                 relay: clientRelay, clientKey: clientKey, responseHead: responseHead)
                }
                .flatMap {
                    clientChannel.setOption(ChannelOptions.autoRead, value: true)
                        .map { clientChannel.read() }
                }
                .flatMapError { error in
                    capture.finish(now: Date())
                    clientChannel.close(promise: nil)
                    originChannel.close(promise: nil)
                    return originChannel.eventLoop.makeFailedFuture(error)
                }
        }

        // Build the handshake replayed to the origin: the client's headers minus
        // hop-by-hop fields, the compression extension, and the handshake headers
        // the upgrader re-adds itself.
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: request.path)
        var headers = HTTPHeaders()
        for header in request.headers where !isStrippedHandshakeHeader(header.name) {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Host", value: hostHeader(target))
        head.headers = headers

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(connectTimeout)
            .channelInitializer { channel in
                do {
                    var tlsFuture: EventLoopFuture<Void> = channel.eventLoop.makeSucceededVoidFuture()
                    if target.tls {
                        let tls = try ProxyTLS.clientHandler(host: target.host, verify: verifyUpstream)
                        tlsFuture = channel.pipeline.addHandler(tls)
                    }
                    return tlsFuture.flatMap {
                        channel.pipeline.addHTTPClientHandlers(
                            leftOverBytesStrategy: .forwardBytes,
                            withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: target.host, port: target.port).whenComplete { result in
            switch result {
            case .success(let originChannel):
                // Send the handshake; the upgrader appends the WS headers and waits
                // for the 101, then runs the upgradePipelineHandler above.
                originChannel.write(HTTPClientRequestPart.head(head), promise: nil)
                originChannel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
            case .failure(let error):
                sink.record(Flow(id: flowID, request: request, response: nil, state: .failed,
                                 error: "\(error)", startedAt: startedAt, endedAt: Date(), secure: secure))
                clientChannel.close(promise: nil)
            }
        }
    }

    /// Client side splice: drop the response encoder, hand back a freshly-computed
    /// `101` (its accept derived from the client's own key), then drop the request
    /// decoder + proxy handler and install the WS codecs. The client only sends
    /// frames after it sees the 101, and reads stay held until the chain is ready.
    private static func spliceClient(_ channel: Channel, proxyHandler: RemovableChannelHandler,
                                     relay: WebSocketRelayHandler, clientKey: String,
                                     responseHead: HTTPResponseHead) -> EventLoopFuture<Void> {
        let p = channel.pipeline
        let decoder = ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: maxFrameSize))
        let encoder = WebSocketFrameEncoder()
        return removeByType(p, HTTPResponseEncoder.self)
            .flatMap { () -> EventLoopFuture<Void> in
                channel.writeAndFlush(client101(channel, clientKey: clientKey, responseHead: responseHead))
            }
            // Drop the request decoder while the proxy handler is still next: any
            // spurious decodeLast `.end` lands on the proxy (which ignores it),
            // never on a byte-typed WS handler.
            .flatMap { removeByType(p, ByteToMessageHandler<HTTPRequestDecoder>.self) }
            .flatMap { p.addHandler(decoder, position: .last) }
            .flatMap { p.addHandler(encoder, position: .last) }
            .flatMap { p.addHandler(aggregator(), position: .last) }
            .flatMap { p.addHandler(relay, position: .last) }
            .flatMap { p.removeHandler(proxyHandler) }
    }

    /// The `101 Switching Protocols` we send back to the client, with an accept
    /// computed from its own key (plus any subprotocol the origin negotiated).
    private static func client101(_ channel: Channel, clientKey: String,
                                  responseHead: HTTPResponseHead) -> ByteBuffer {
        var buffer = channel.allocator.buffer(capacity: 200)
        buffer.writeString("HTTP/1.1 101 Switching Protocols\r\n")
        buffer.writeString("Upgrade: websocket\r\n")
        buffer.writeString("Connection: Upgrade\r\n")
        buffer.writeString("Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r\n")
        if let proto = responseHead.headers.first(name: "Sec-WebSocket-Protocol") {
            buffer.writeString("Sec-WebSocket-Protocol: \(proto)\r\n")
        }
        buffer.writeString("\r\n")
        return buffer
    }

    /// RFC 6455 accept: base64(SHA1(key + magic GUID)).
    private static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func aggregator() -> NIOWebSocketFrameAggregator {
        NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0,
                                    maxAccumulatedFrameCount: maxFragments,
                                    maxAccumulatedFrameSize: maxFrameSize)
    }

    private static func removeByType<T: ChannelHandler>(_ p: ChannelPipeline, _ type: T.Type) -> EventLoopFuture<Void> {
        p.context(handlerType: type).flatMap { p.removeHandler(context: $0) }
    }

    /// Hop-by-hop / compression / handshake headers we don't replay verbatim.
    /// `Sec-WebSocket-*` handshake fields are re-added by the upgrader (keyed on
    /// the client's key); dropping `Sec-WebSocket-Extensions` disables
    /// `permessage-deflate` so frames stay uncompressed and inspectable.
    private static func isStrippedHandshakeHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "proxy-connection", "host", "content-length",
             "upgrade", "connection",
             "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions":
            return true
        default:
            return false
        }
    }

    private static func hostHeader(_ target: UpstreamTarget) -> String {
        let isDefault = (target.tls && target.port == 443) || (!target.tls && target.port == 80)
        return isDefault ? target.host : "\(target.host):\(target.port)"
    }
}

/// Relays one direction of an upgraded WebSocket: decodes each (aggregated) frame,
/// records it onto the shared ``WebSocketCapture``, and re-frames it to the peer.
/// Client→server frames are re-masked (RFC 6455 requires client frames be masked);
/// server→client frames are sent unmasked.
final class WebSocketRelayHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let direction: WebSocketMessage.Direction
    private let capture: WebSocketCapture
    private let partner: Channel
    private let maskOutbound: Bool
    private var closed = false

    init(direction: WebSocketMessage.Direction, capture: WebSocketCapture,
         partner: Channel, maskOutbound: Bool) {
        self.direction = direction
        self.capture = capture
        self.partner = partner
        self.maskOutbound = maskOutbound
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let payload = frame.unmaskedData
        capture.append(direction: direction, opcode: frame.opcode, payload: payload, now: Date())

        let outgoing: WebSocketFrame
        if maskOutbound {
            outgoing = WebSocketFrame(fin: frame.fin, opcode: frame.opcode,
                                      maskKey: Self.randomMask(), data: payload)
        } else {
            outgoing = WebSocketFrame(fin: frame.fin, opcode: frame.opcode, data: payload)
        }

        if frame.opcode == .connectionClose {
            // Flush the close to the peer *before* tearing down the TCP, so it sees
            // a clean WebSocket close rather than an abrupt reset.
            capture.finish(now: Date())
            let flushed = partner.eventLoop.makePromise(of: Void.self)
            partner.writeAndFlush(outgoing, promise: flushed)
            flushed.futureResult.whenComplete { [weak self] _ in self?.closeBoth(context: context) }
        } else {
            partner.writeAndFlush(outgoing, promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        capture.finish(now: Date())
        closeBoth(context: context)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        capture.finish(now: Date())
        closeBoth(context: context)
    }

    private func closeBoth(context: ChannelHandlerContext) {
        guard !closed else { return }
        closed = true
        partner.close(promise: nil)
        context.close(promise: nil)
    }

    private static func randomMask() -> WebSocketMaskingKey {
        WebSocketMaskingKey((0..<4).map { _ in UInt8.random(in: .min ... .max) })!
    }
}

/// Accumulates the frames of one upgraded WebSocket connection and re-emits the
/// owning ``Flow`` (coalesced to ~200ms) so the UI streams messages live. A
/// reference type confined to the connection's event loop.
final class WebSocketCapture {
    private let flowID: UUID
    private let request: CapturedRequest
    private let response: CapturedResponse
    private let startedAt: Date
    private let secure: Bool
    private let sink: FlowSink
    private let eventLoop: EventLoop
    private let perMessageCap: Int
    private let messageCap: Int
    private let totalBytesCap: Int

    private var messages: [WebSocketMessage] = []
    private var retainedBytes = 0
    private var recordScheduled = false
    private var ended = false

    init(flowID: UUID, request: CapturedRequest, response: CapturedResponse,
         startedAt: Date, secure: Bool, sink: FlowSink, eventLoop: EventLoop,
         perMessageCap: Int, messageCap: Int, totalBytesCap: Int) {
        self.flowID = flowID
        self.request = request
        self.response = response
        self.startedAt = startedAt
        self.secure = secure
        self.sink = sink
        self.eventLoop = eventLoop
        self.perMessageCap = perMessageCap
        self.messageCap = messageCap
        self.totalBytesCap = totalBytesCap
    }

    func append(direction: WebSocketMessage.Direction, opcode: WebSocketOpcode,
                payload: ByteBuffer, now: Date) {
        let kind: WebSocketMessage.Kind
        switch opcode {
        case .text: kind = .text
        case .binary: kind = .binary
        case .ping: kind = .ping
        case .pong: kind = .pong
        case .connectionClose: kind = .close
        default: return   // continuation frames are merged by the aggregator
        }
        var bytes = payload.getBytes(at: payload.readerIndex, length: payload.readableBytes) ?? []
        var truncated = false
        if bytes.count > perMessageCap {
            bytes = Array(bytes.prefix(perMessageCap))
            truncated = true
        }
        messages.append(WebSocketMessage(direction: direction, kind: kind,
                                         data: Data(bytes), timestamp: now, truncated: truncated))
        retainedBytes += bytes.count
        // Evict oldest frames to stay within both the count and total-byte budgets,
        // bounding the memory the whole-flow re-record holds (critical on iOS).
        while messages.count > messageCap || (retainedBytes > totalBytesCap && messages.count > 1) {
            retainedBytes -= messages.removeFirst().data.count
        }
        scheduleRecord()
    }

    /// Mark the connection finished and flush a final `.completed` record.
    func finish(now: Date) {
        guard !ended else { return }
        ended = true
        recordNow(state: .completed, endedAt: now)
    }

    /// Emit the current snapshot immediately (used for the initial open record).
    func recordNow(state: FlowState, endedAt: Date? = nil) {
        sink.record(Flow(id: flowID, request: request, response: response, state: state,
                         startedAt: startedAt, endedAt: endedAt, secure: secure,
                         webSocketMessages: messages))
    }

    /// Coalesce live updates so a chatty socket doesn't rewrite the session file
    /// on every frame (the store persists the whole session per record).
    private func scheduleRecord() {
        guard !recordScheduled, !ended else { return }
        recordScheduled = true
        eventLoop.scheduleTask(in: .milliseconds(500)) { [weak self] in
            guard let self else { return }
            self.recordScheduled = false
            if !self.ended { self.recordNow(state: .pending) }
        }
    }
}
