import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Handles a single cleartext HTTP stream (either a plain-HTTP client, or the
/// decrypted side of an HTTPS MITM tunnel). For each request it runs the
/// ``InterceptEngine`` (block / map / rewrite / throttle / breakpoint), forwards
/// the (possibly modified) request to the origin, runs the engine over the
/// response, relays it, and records a ``Flow``.
final class DecryptedProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let fixedTarget: UpstreamTarget?
    private let sink: FlowSink
    private let group: EventLoopGroup
    private let verifyUpstream: Bool
    private let engine: InterceptEngine
    private let captureBodyCap: Int
    private let idleTimeout: TimeAmount
    private let connectTimeout: TimeAmount

    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    private var startedAt = Date()
    private var keepAlive = true

    init(fixedTarget: UpstreamTarget?, sink: FlowSink, group: EventLoopGroup,
         verifyUpstream: Bool, engine: InterceptEngine,
         captureBodyCap: Int = ProxyTuning.defaultCaptureBodyCap,
         idleTimeout: TimeAmount = ProxyTuning.defaultIdleTimeout,
         connectTimeout: TimeAmount = ProxyTuning.defaultConnectTimeout) {
        self.fixedTarget = fixedTarget
        self.sink = sink
        self.group = group
        self.verifyUpstream = verifyUpstream
        self.engine = engine
        self.captureBodyCap = captureBodyCap
        self.idleTimeout = idleTimeout
        self.connectTimeout = connectTimeout
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
            startedAt = Date()
            keepAlive = head.isKeepAlive
        case .body(var chunk):
            requestBody.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else { return }
            forward(context: context, head: head, body: requestBody)
            requestHead = nil
        }
    }

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
        guard let target = resolveTarget(head) else {
            respondError(channel: context.channel, status: .badRequest, message: "Cannot resolve target host")
            return
        }

        let scheme = target.tls ? "https" : "http"
        let path = originForm(head.uri)
        let url = "\(scheme)://\(target.host)\(target.port == (target.tls ? 443 : 80) ? "" : ":\(target.port)")\(path)"
        let request = CapturedRequest(
            method: head.method.rawValue, url: url, scheme: scheme, host: target.host,
            port: target.port, path: path,
            httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
            headers: head.headers.map { HeaderPair(name: $0.name, value: $0.value) },
            body: Data(body.readableBytesView), timestamp: startedAt
        )

        let flowID = UUID()
        let started = startedAt
        let secure = target.tls
        let keepAlive = self.keepAlive
        let engine = self.engine
        let sink = self.sink
        let channel = context.channel
        let allocator = context.channel.allocator
        let isWebSocket = isWebSocketUpgrade(head)

        Task {
            let outcome = await engine.processRequest(request, target: target)
            switch outcome {
            case .respond(let response):
                sink.record(Flow(id: flowID, request: request, response: response,
                                 state: .completed, startedAt: started, endedAt: Date(), secure: secure))
                await self.relay(channel: channel, allocator: allocator, response: response, keepAlive: keepAlive)

            case .forward(let finalRequest, let finalTarget, let throttle):
                // A WebSocket upgrade leaves the HTTP request/response model behind:
                // hand both channels to the frame-capturing tunnel and stop here.
                if isWebSocket {
                    WebSocketTunnel.start(
                        clientChannel: channel, clientProxyHandler: self,
                        request: finalRequest, target: finalTarget, flowID: flowID,
                        startedAt: started, secure: secure, sink: sink, group: self.group,
                        verifyUpstream: self.verifyUpstream, connectTimeout: self.connectTimeout,
                        perMessageCap: min(self.captureBodyCap, WebSocketTunnel.defaultPerMessageCap))
                    return
                }
                if throttle.delayMS > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(throttle.delayMS) * 1_000_000)
                }
                // Stream the response straight through (bounded memory) unless a
                // throttle is active or a rule needs the whole body in hand
                // (rewriteResponse / response breakpoint) — those take the
                // buffered path below.
                if !throttle.isActive, !engine.requiresBufferedResponse(for: finalRequest) {
                    self.startStreaming(clientChannel: channel, target: finalTarget,
                                        request: finalRequest, flowID: flowID,
                                        startedAt: started, secure: secure, keepAlive: keepAlive)
                    return
                }
                do {
                    let (head, bodyBuffer) = try await self.performUpstream(
                        target: finalTarget, request: finalRequest, allocator: allocator).get()
                    var response = CapturedResponse(
                        statusCode: Int(head.status.code), reasonPhrase: head.status.reasonPhrase,
                        httpVersion: "HTTP/\(head.version.major).\(head.version.minor)",
                        headers: head.headers.map { HeaderPair(name: $0.name, value: $0.value) },
                        body: Data(bodyBuffer.readableBytesView), timestamp: Date()
                    )
                    response = await engine.processResponse(response, for: finalRequest)
                    sink.record(Flow(id: flowID, request: finalRequest, response: response,
                                     state: .completed, startedAt: started, endedAt: Date(), secure: secure))
                    await self.relay(channel: channel, allocator: allocator, response: response,
                                     keepAlive: keepAlive, throttle: throttle)
                } catch {
                    sink.record(Flow(id: flowID, request: finalRequest, response: nil, state: .failed,
                                     error: "\(error)", startedAt: started, endedAt: Date(), secure: secure))
                    self.respondError(channel: channel, status: .badGateway, message: "Upstream error: \(error)")
                }
            }
        }
    }

    // MARK: Upstream request

    private func performUpstream(target: UpstreamTarget, request: CapturedRequest, allocator: ByteBufferAllocator)
        -> EventLoopFuture<(HTTPResponseHead, ByteBuffer)> {
        let promise = group.next().makePromise(of: (HTTPResponseHead, ByteBuffer).self)
        let verify = verifyUpstream

        let method = HTTPMethod(rawValue: request.method)
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: request.path)
        var headers = HTTPHeaders()
        for header in request.headers where header.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Host", value: hostHeader(target))
        headers.replaceOrAdd(name: "Connection", value: "close")
        if !request.body.isEmpty {
            headers.replaceOrAdd(name: "Content-Length", value: "\(request.body.count)")
        }
        head.headers = headers

        var bodyBuffer = allocator.buffer(capacity: request.body.count)
        bodyBuffer.writeBytes(request.body)

        let idleTimeout = self.idleTimeout
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelInitializer { channel in
                do {
                    var handlers: [ChannelHandler] = [
                        IdleStateHandler(readTimeout: idleTimeout),
                        IdleCloseHandler()
                    ]
                    if target.tls {
                        handlers.append(try ProxyTLS.clientHandler(host: target.host, verify: verify))
                    }
                    handlers.append(HTTPRequestEncoder())
                    handlers.append(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
                    handlers.append(UpstreamCollector(head: head, body: bodyBuffer, promise: promise))
                    return channel.pipeline.addHandlers(handlers)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: target.host, port: target.port).whenFailure { promise.fail($0) }
        return promise.futureResult
    }

    // MARK: Streaming upstream (bounded memory)

    /// Connects to the origin and hands the response off to a ``StreamingProxyHandler``
    /// that pipes it straight back to `clientChannel` while capturing at most
    /// `captureBodyCap` bytes. Used for the common case (no response-modifying
    /// rule, no throttle).
    private func startStreaming(clientChannel: Channel, target: UpstreamTarget,
                               request: CapturedRequest, flowID: UUID,
                               startedAt: Date, secure: Bool, keepAlive: Bool) {
        let method = HTTPMethod(rawValue: request.method)
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: request.path)
        var headers = HTTPHeaders()
        for header in request.headers where header.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Host", value: hostHeader(target))
        headers.replaceOrAdd(name: "Connection", value: "close")
        if !request.body.isEmpty {
            headers.replaceOrAdd(name: "Content-Length", value: "\(request.body.count)")
        }
        head.headers = headers

        var bodyBuffer = clientChannel.allocator.buffer(capacity: request.body.count)
        bodyBuffer.writeBytes(request.body)

        let handler = StreamingProxyHandler(
            clientChannel: clientChannel, requestHead: head, requestBody: bodyBuffer,
            captured: request, flowID: flowID, startedAt: startedAt, secure: secure,
            keepAlive: keepAlive, captureCap: captureBodyCap, sink: sink)

        let verify = verifyUpstream
        let idleTimeout = self.idleTimeout
        let sink = self.sink
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            // autoRead off: StreamingProxyHandler paces reads against client writes.
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { channel in
                do {
                    var handlers: [ChannelHandler] = [
                        IdleStateHandler(readTimeout: idleTimeout),
                        IdleCloseHandler()
                    ]
                    if target.tls {
                        handlers.append(try ProxyTLS.clientHandler(host: target.host, verify: verify))
                    }
                    handlers.append(HTTPRequestEncoder())
                    handlers.append(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
                    handlers.append(handler)
                    return channel.pipeline.addHandlers(handlers)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: target.host, port: target.port).whenFailure { error in
            // Never connected: record the failure and tell the client 502.
            sink.record(Flow(id: flowID, request: request, response: nil, state: .failed,
                             error: "\(error)", startedAt: startedAt, endedAt: Date(), secure: secure))
            self.respondError(channel: clientChannel, status: .badGateway,
                              message: "Upstream error: \(error)")
        }
    }

    // MARK: Relay & errors

    private func relay(channel: Channel, allocator: ByteBufferAllocator,
                       response: CapturedResponse, keepAlive: Bool,
                       throttle: ThrottleConfig = ThrottleConfig()) async {
        var headers = HTTPHeaders()
        for header in response.headers
        where header.name.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame
            && header.name.caseInsensitiveCompare("Content-Length") != .orderedSame
            && header.name.caseInsensitiveCompare("Connection") != .orderedSame {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let status = HTTPResponseStatus(statusCode: response.statusCode, reasonPhrase: response.reasonPhrase)
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        if throttle.bytesPerSecond > 0, response.body.count > 0 {
            // Bandwidth simulation: drip the body in ~100ms slices.
            let chunkSize = max(256, throttle.bytesPerSecond / 10)
            var offset = 0
            while offset < response.body.count {
                let end = min(offset + chunkSize, response.body.count)
                let slice = response.body[offset..<end]
                var buffer = allocator.buffer(capacity: slice.count)
                buffer.writeBytes(slice)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                channel.flush()
                let seconds = Double(slice.count) / Double(throttle.bytesPerSecond)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                offset = end
            }
        } else {
            var buffer = allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            if buffer.readableBytes > 0 {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            }
        }

        try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
        if !keepAlive { try? await channel.close() }
    }

    private func respondError(channel: Channel, status: HTTPResponseStatus, message: String) {
        let response = CapturedResponse(
            statusCode: Int(status.code), reasonPhrase: status.reasonPhrase, httpVersion: "HTTP/1.1",
            headers: [HeaderPair(name: "Content-Type", value: "text/plain; charset=utf-8")],
            body: Data(message.utf8), timestamp: Date()
        )
        Task { await relay(channel: channel, allocator: channel.allocator, response: response, keepAlive: false) }
    }

    /// True for an RFC 6455 upgrade handshake (`GET` + `Upgrade: websocket` +
    /// `Connection: upgrade`). `canonicalForm` splits comma-separated list headers.
    private func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
        guard head.method == .GET else { return false }
        let upgrade = head.headers[canonicalForm: "upgrade"].map { $0.lowercased() }
        let connection = head.headers[canonicalForm: "connection"].map { $0.lowercased() }
        return upgrade.contains("websocket") && connection.contains { $0.contains("upgrade") }
    }

    // MARK: Target resolution

    private func resolveTarget(_ head: HTTPRequestHead) -> UpstreamTarget? {
        if let fixedTarget { return fixedTarget }
        guard let comps = URLComponents(string: head.uri), let host = comps.host else {
            if let hostHeader = head.headers.first(name: "Host") {
                let (h, p) = splitHostPort(hostHeader, defaultPort: 80)
                return UpstreamTarget(host: h, port: p, tls: false)
            }
            return nil
        }
        let tls = comps.scheme?.lowercased() == "https"
        return UpstreamTarget(host: host, port: comps.port ?? (tls ? 443 : 80), tls: tls)
    }

    private func originForm(_ uri: String) -> String {
        guard uri.lowercased().hasPrefix("http://") || uri.lowercased().hasPrefix("https://"),
              let comps = URLComponents(string: uri) else {
            return uri.isEmpty ? "/" : uri
        }
        var path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let query = comps.percentEncodedQuery { path += "?" + query }
        return path
    }

    private func hostHeader(_ target: UpstreamTarget) -> String {
        let isDefault = (target.tls && target.port == 443) || (!target.tls && target.port == 80)
        return isDefault ? target.host : "\(target.host):\(target.port)"
    }

    private func splitHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
        if let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
            return (String(value[..<colon]), port)
        }
        return (value, defaultPort)
    }
}

/// Drives a single upstream request: sends head+body on connect, accumulates the
/// response, and fulfils the promise on `.end`.
final class UpstreamCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let head: HTTPRequestHead
    private let body: ByteBuffer
    private let promise: EventLoopPromise<(HTTPResponseHead, ByteBuffer)>
    private var responseHead: HTTPResponseHead?
    private var responseBody = ByteBuffer()
    private var completed = false

    init(head: HTTPRequestHead, body: ByteBuffer, promise: EventLoopPromise<(HTTPResponseHead, ByteBuffer)>) {
        self.head = head
        self.body = body
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if body.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            responseHead = head
            responseBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            responseBody.writeBuffer(&chunk)
        case .end:
            succeed(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed { completed = true; promise.fail(error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            if let head = responseHead { promise.succeed((head, responseBody)) }
            else { promise.fail(ChannelError.eof) }
        }
    }

    private func succeed(context: ChannelHandlerContext) {
        guard !completed, let head = responseHead else { return }
        completed = true
        promise.succeed((head, responseBody))
        context.close(promise: nil)
    }
}
