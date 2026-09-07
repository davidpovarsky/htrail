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
    private let capturedRequestProvider: (() -> CapturedRequest)?
    private let completeRequestOnActive: Bool
    private let responseInspectionPolicy: StreamingResponseInspectionPolicy?
    private let responseInspector: StreamingResponseInspector?
    private let targetHost: String?
    private let targetUsesTLS: Bool
    private let runtimeEventHandler: (@Sendable (ProxyRuntimeEvent) -> Void)?
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
    private var inspectionLimit: Int?
    private var inspectionBuffer = Data()
    private var upstreamHead: HTTPResponseHead?

    init(clientChannel: Channel, requestHead: HTTPRequestHead, requestBody: ByteBuffer,
         captured: CapturedRequest, flowID: UUID, startedAt: Date, secure: Bool,
         keepAlive: Bool, captureCap: Int, sink: FlowSink,
         completeRequestOnActive: Bool = true,
         capturedRequestProvider: (() -> CapturedRequest)? = nil,
         responseInspectionPolicy: StreamingResponseInspectionPolicy? = nil,
         responseInspector: StreamingResponseInspector? = nil,
         targetHost: String? = nil, targetUsesTLS: Bool = false,
         runtimeEventHandler: (@Sendable (ProxyRuntimeEvent) -> Void)? = nil) {
        self.clientChannel = clientChannel
        self.requestHead = requestHead
        self.requestBody = requestBody
        self.captured = captured
        self.capturedRequestProvider = capturedRequestProvider
        self.completeRequestOnActive = completeRequestOnActive
        self.responseInspectionPolicy = responseInspectionPolicy
        self.responseInspector = responseInspector
        self.targetHost = targetHost
        self.targetUsesTLS = targetUsesTLS
        self.runtimeEventHandler = runtimeEventHandler
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
        if completeRequestOnActive {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        } else {
            context.flush()
        }
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
            upstreamHead = head
            if head.status.code >= 400 {
                runtimeEventHandler?(ProxyRuntimeEvent(
                    kind: .originHTTPStatus, host: targetHost,
                    detail: head.status.reasonPhrase, statusCode: Int(head.status.code)
                ))
            }
            let metadata = StreamingResponseMetadata(
                statusCode: Int(head.status.code), reasonPhrase: head.status.reasonPhrase,
                httpVersion: "HTTP/\(head.version.major).\(head.version.minor)", headers: capturedHeaders
            )
            let request = capturedRequestProvider?() ?? captured
            if let limit = responseInspectionPolicy?(request, metadata), limit > 0,
               responseInspector != nil {
                inspectionLimit = limit
                inspectionBuffer.reserveCapacity(min(limit, 512 * 1024))
            } else {
                sendHead(head)
            }

        case .body(var chunk):
            let available = chunk.readableBytes
            if let limit = inspectionLimit {
                if inspectionBuffer.count + available <= limit {
                    if let bytes = chunk.readBytes(length: available) { inspectionBuffer.append(contentsOf: bytes) }
                    break
                }
                // Unknown/chunked response crossed the safe inspection limit:
                // release the held prefix and continue transparent streaming.
                inspectionLimit = nil
                if let head = upstreamHead { sendHead(head) }
                if !inspectionBuffer.isEmpty {
                    captureInspectionPrefix()
                    var prefix = clientChannel.allocator.buffer(capacity: inspectionBuffer.count)
                    prefix.writeBytes(inspectionBuffer)
                    lastWrite = clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(prefix))))
                    inspectionBuffer.removeAll(keepingCapacity: false)
                }
            }
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
            if inspectionLimit != nil { finishInspection(context: context) }
            else { finish(context: context, success: true) }
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
        runtimeEventHandler?(ProxyFailureClassifier.event(error: error, host: targetHost, tls: targetUsesTLS))
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

    private func finishInspection(context: ChannelHandlerContext) {
        guard !completed, let head = upstreamHead, let inspector = responseInspector else {
            finish(context: context, success: true); return
        }
        completed = true
        inspectionLimit = nil
        let original = CapturedResponse(
            statusCode: Int(head.status.code), reasonPhrase: head.status.reasonPhrase,
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headers: capturedHeaders, body: inspectionBuffer, timestamp: Date()
        )
        let request = capturedRequestProvider?() ?? captured
        Task {
            let output: CapturedResponse
            do { output = try await inspector(request, original) ?? original }
            catch { output = original }
            self.sendInspected(output)
            self.sink.record(Flow(id: self.flowID, request: request, response: self.captureVersion(output),
                                  state: .completed, startedAt: self.startedAt, endedAt: Date(), secure: self.secure))
            context.channel.close(promise: nil)
        }
    }

    private func sendHead(_ head: HTTPResponseHead) {
        guard !headSent else { return }
        lastWrite = clientChannel.write(NIOAny(HTTPServerResponsePart.head(makeClientHead(from: head))))
        headSent = true
    }

    private func sendInspected(_ response: CapturedResponse) {
        var headers = HTTPHeaders()
        for header in response.headers
        where header.name.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame
            && header.name.caseInsensitiveCompare("Content-Length") != .orderedSame
            && header.name.caseInsensitiveCompare("Connection") != .orderedSame {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let status = HTTPResponseStatus(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase)
        clientChannel.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        if !response.body.isEmpty {
            var body = clientChannel.allocator.buffer(capacity: response.body.count); body.writeBytes(response.body)
            clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(body))), promise: nil)
        }
        let end = clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
        if !keepAlive { end.whenComplete { [clientChannel] _ in clientChannel.close(promise: nil) } }
    }

    private func captureInspectionPrefix() {
        let room = max(0, captureCap - captureBuffer.count)
        if room > 0 { captureBuffer.append(inspectionBuffer.prefix(room)) }
        capturedBytes += inspectionBuffer.count
        if inspectionBuffer.count > room { truncated = true }
    }

    private func captureVersion(_ response: CapturedResponse) -> CapturedResponse {
        guard response.body.count > captureCap else { return response }
        var result = response
        result.body = Data(response.body.prefix(captureCap)); result.bodyTruncated = true
        return result
    }

    private func recordFlow(failed: Bool, error: String?) {
        let response: CapturedResponse? = headSent ? CapturedResponse(
            statusCode: Int(status.code), reasonPhrase: status.reasonPhrase,
            httpVersion: "HTTP/\(version.major).\(version.minor)",
            headers: capturedHeaders, body: captureBuffer, timestamp: Date(),
            bodyTruncated: truncated ? true : nil
        ) : nil
        sink.record(Flow(id: flowID, request: capturedRequestProvider?() ?? captured, response: response,
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
