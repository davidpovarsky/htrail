import Foundation
import NIOCore
import NIOHTTP1

/// Closes the channel when an `IdleStateHandler` reports inactivity. Used on
/// upstream connections so an origin that accepts the socket but never (or no
/// longer) sends data is torn down instead of hanging the client forever.
final class IdleCloseHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Relays an upstream HTTP response straight back to the client channel **without
/// buffering the whole body**. This bounds memory — essential inside the iOS
/// Packet Tunnel extension's hard ~50 MB limit, where buffering a large download
/// gets the extension jetsam-killed (which looks like the VPN "flapping").
///
/// - Body bytes are forwarded chunk-by-chunk to the client as they arrive.
/// - Only up to `captureCap` bytes are retained for the recorded ``Flow``; beyond
///   that the captured body is flagged `bodyTruncated` (the client still gets
///   every byte).
/// - Backpressure: the upstream channel runs with `autoRead` off and each next
///   read is gated on the client write completing, so at most ~one socket read is
///   in flight regardless of how fast the origin pushes or how slow the client
///   drains.
///
/// Lives on the **upstream** channel. All client I/O goes through the thread-safe
/// `Channel` API (never the client's handler context), so crossing event loops is
/// safe.
final class StreamingProxyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let requestHead: HTTPRequestHead
    private let requestBody: ByteBuffer
    private let captured: CapturedRequest
    private let flowID: UUID
    private let startedAt: Date
    private let secure: Bool
    private let keepAlive: Bool
    private let captureCap: Int
    private let sink: FlowSink
    private let isHeadRequest: Bool

    private var status: HTTPResponseStatus = .ok
    private var version: HTTPVersion = .http1_1
    private var capturedHeaders: [HeaderPair] = []
    private var captureBuffer = Data()
    private var capturedBytes = 0
    private var truncated = false
    private var headSent = false
    private var completed = false
    private var lastWrite: EventLoopFuture<Void>?

    init(clientChannel: Channel, requestHead: HTTPRequestHead, requestBody: ByteBuffer,
         captured: CapturedRequest, flowID: UUID, startedAt: Date, secure: Bool,
         keepAlive: Bool, captureCap: Int, sink: FlowSink) {
        self.clientChannel = clientChannel
        self.requestHead = requestHead
        self.requestBody = requestBody
        self.captured = captured
        self.flowID = flowID
        self.startedAt = startedAt
        self.secure = secure
        self.keepAlive = keepAlive
        self.captureCap = captureCap
        self.sink = sink
        self.isHeadRequest = captured.method.caseInsensitiveCompare("HEAD") == .orderedSame
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(wrapOutboundOut(.head(requestHead)), promise: nil)
        if requestBody.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(requestBody))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        // autoRead is off (set on the bootstrap); start the response read loop.
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = head.status
            version = head.version
            capturedHeaders = head.headers.map { HeaderPair(name: $0.name, value: $0.value) }
            let clientHead = makeClientHead(from: head)
            lastWrite = clientChannel.write(NIOAny(HTTPServerResponsePart.head(clientHead)))
            headSent = true

        case .body(var chunk):
            let available = chunk.readableBytes
            if capturedBytes < captureCap, available > 0 {
                let room = captureCap - capturedBytes
                let take = min(room, available)
                if let bytes = chunk.getBytes(at: chunk.readerIndex, length: take) {
                    captureBuffer.append(contentsOf: bytes)
                }
                if available > room { truncated = true }
            } else if available > 0 {
                truncated = true
            }
            capturedBytes += available
            lastWrite = clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk))))

        case .end:
            finish(context: context, success: true)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        clientChannel.flush()
        guard !completed else { return }
        // Gate the next upstream read on the client accepting what we just wrote.
        // If the client is slow/backpressured the write future stays pending, so
        // we stop pulling from the origin — memory stays bounded.
        let loop = context.eventLoop
        if let lastWrite {
            lastWrite.hop(to: loop).whenComplete { [weak self] result in
                guard let self, !self.completed else { return }
                if case .failure = result {
                    self.finish(context: context, success: false)
                } else {
                    context.read()
                }
            }
        } else {
            context.read()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context: context, success: false)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A clean close after the head (HTTP/1.0 / close-delimited bodies) is a
        // successful completion; a close before any head is an upstream failure.
        finish(context: context, success: headSent)
    }

    // MARK: - Finalisation

    private func finish(context: ChannelHandlerContext, success: Bool) {
        guard !completed else { return }
        completed = true

        if success && headSent {
            let endFuture = clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
            if !keepAlive {
                endFuture.whenComplete { [clientChannel] _ in clientChannel.close(promise: nil) }
            }
            recordFlow(failed: false, error: nil)
        } else if headSent {
            // Failure mid-stream: we already committed a response head, so we
            // can't synthesise an error status — just drop the client connection
            // and record what we captured as a failed flow.
            clientChannel.close(promise: nil)
            recordFlow(failed: true, error: "Upstream stream interrupted")
        } else {
            // Upstream died before sending any response: tell the client 502.
            sendBadGateway()
            recordFlow(failed: true, error: "Upstream did not respond")
        }
        context.close(promise: nil)
    }

    private func recordFlow(failed: Bool, error: String?) {
        let response: CapturedResponse? = headSent ? CapturedResponse(
            statusCode: Int(status.code), reasonPhrase: status.reasonPhrase,
            httpVersion: "HTTP/\(version.major).\(version.minor)",
            headers: capturedHeaders, body: captureBuffer, timestamp: Date(),
            bodyTruncated: truncated ? true : nil
        ) : nil
        sink.record(Flow(id: flowID, request: captured, response: response,
                         state: failed ? .failed : .completed, error: error,
                         startedAt: startedAt, endedAt: Date(), secure: secure))
    }

    private func sendBadGateway() {
        let message = "Upstream error"
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(message.utf8.count)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
        clientChannel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        var buffer = clientChannel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        let endFuture = clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
        endFuture.whenComplete { [clientChannel] _ in clientChannel.close(promise: nil) }
    }

    /// Re-frame the response head for the client: drop hop-by-hop headers and pick
    /// a framing the client can trust. Keep an explicit Content-Length when the
    /// origin gave one (we forward the exact same bytes); otherwise stream with
    /// chunked transfer-encoding. Bodyless responses keep their headers as-is.
    private func makeClientHead(from upstream: HTTPResponseHead) -> HTTPResponseHead {
        let bodyless = isHeadRequest || status.code == 204 || status.code == 304 || (100..<200).contains(Int(status.code))
        var headers = HTTPHeaders()
        for header in upstream.headers
        where header.name.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame
            && header.name.caseInsensitiveCompare("Connection") != .orderedSame
            && header.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame
            && header.name.caseInsensitiveCompare("Keep-Alive") != .orderedSame {
            headers.add(name: header.name, value: header.value)
        }
        if !bodyless {
            if upstream.headers.first(name: "Content-Length") == nil {
                headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }
        }
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    }
}
