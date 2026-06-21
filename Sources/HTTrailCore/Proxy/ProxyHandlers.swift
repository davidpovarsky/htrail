import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

enum ProxyHandlerName {
    static let httpEncoder = "httrail.httpEncoder"
    static let httpDecoder = "httrail.httpDecoder"
    static let connect = "httrail.connect"
}

// MARK: - TLS context helpers

enum ProxyTLS {
    static func serverHandler(leaf: CertificateAuthority.LeafMaterial) throws -> NIOSSLServerHandler {
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(leaf.certificateChainPEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
        let config = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        let context = try NIOSSLContext(configuration: config)
        return NIOSSLServerHandler(context: context)
    }

    static func clientHandler(host: String, verify: Bool) throws -> NIOSSLClientHandler {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = verify ? .fullVerification : .none
        let context = try NIOSSLContext(configuration: config)
        // SNI / hostname verification only makes sense for DNS names.
        let serverHostname = isIPAddress(host) ? nil : host
        return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

// MARK: - Pinning sensor

/// Sits just inboard of the server-side `NIOSSLServerHandler` and watches a
/// single signal: did the TLS handshake with the client ever complete?
///
/// - If `TLSUserEvent.handshakeCompleted` fires, the client accepted our forged
///   leaf — the CA is trusted and the host isn't pinned.
/// - If the channel goes inactive (or errors) *before* that event, the client
///   rejected the certificate — a fatal alert or an abrupt close, which is what
///   certificate pinning looks like from this side of the connection.
///
/// Either way it reports to the engine exactly once; the engine decides whether
/// the host has crossed the threshold to be tunneled on its next attempt.
final class TLSHandshakeSensor: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let host: String
    private let engine: InterceptEngine
    private var settled = false

    init(host: String, engine: InterceptEngine) {
        self.host = host
        self.engine = engine
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event, !settled {
            settled = true
            engine.recordMITMHandshakeSuccess(host: host)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        markFailureIfUnsettled()
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        markFailureIfUnsettled()
        context.fireChannelInactive()
    }

    private func markFailureIfUnsettled() {
        guard !settled else { return }
        settled = true
        engine.recordMITMHandshakeFailure(host: host)
    }
}

// MARK: - CONNECT dispatch

/// First handler on every accepted connection. Peeks the opening request to
/// decide between a plain-HTTP proxy flow and an HTTPS MITM tunnel.
final class ProxyConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let ca: CertificateAuthority
    private let sink: FlowSink
    private let group: EventLoopGroup
    private let verifyUpstream: Bool
    private let engine: InterceptEngine
    private let captureBodyCap: Int
    private let idleTimeout: TimeAmount
    private let connectTimeout: TimeAmount
    private var connectTarget: (host: String, port: Int)?
    private var handled = false

    init(ca: CertificateAuthority, sink: FlowSink, group: EventLoopGroup,
         verifyUpstream: Bool, engine: InterceptEngine,
         captureBodyCap: Int = ProxyTuning.defaultCaptureBodyCap,
         idleTimeout: TimeAmount = ProxyTuning.defaultIdleTimeout,
         connectTimeout: TimeAmount = ProxyTuning.defaultConnectTimeout) {
        self.ca = ca
        self.sink = sink
        self.group = group
        self.verifyUpstream = verifyUpstream
        self.engine = engine
        self.captureBodyCap = captureBodyCap
        self.idleTimeout = idleTimeout
        self.connectTimeout = connectTimeout
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            if head.method == .CONNECT {
                connectTarget = parseAuthority(head.uri)
            } else if !handled {
                handled = true
                upgradeToPlainProxy(context: context, firstHead: head)
            }
        case .body:
            break
        case .end:
            if let target = connectTarget, !handled {
                handled = true
                startMITM(context: context, host: target.host, port: target.port)
            }
        }
    }

    // MARK: Plain HTTP

    private func upgradeToPlainProxy(context: ChannelHandlerContext, firstHead: HTTPRequestHead) {
        let proxy = DecryptedProxyHandler(fixedTarget: nil, sink: sink, group: group,
                                          verifyUpstream: verifyUpstream, engine: engine,
                                          captureBodyCap: captureBodyCap, idleTimeout: idleTimeout,
                                          connectTimeout: connectTimeout)
        let pipeline = context.pipeline
        _ = pipeline.addHandler(proxy, position: .after(self)).flatMap { () -> EventLoopFuture<Void> in
            // Re-deliver the head we already consumed, then retire ourselves so
            // body/end parts flow straight to the proxy handler.
            context.fireChannelRead(NIOAny(HTTPServerRequestPart.head(firstHead)))
            return pipeline.removeHandler(self)
        }
    }

    // MARK: HTTPS MITM

    private func startMITM(context: ChannelHandlerContext, host: String, port: Int) {
        // SSL Proxying allowlist: hosts outside it are tunneled, not decrypted.
        guard engine.shouldDecrypt(host: host) else {
            startBlindTunnel(context: context, host: host, port: port)
            return
        }

        let pipeline = context.pipeline
        let channel = context.channel
        let alloc = channel.allocator
        let eventLoop = context.eventLoop

        // Suppress reads while we rebuild the pipeline: the client sends its TLS
        // ClientHello the instant it sees our 200, but installing the TLS handler
        // is asynchronous. Without this, those raw TLS bytes are delivered into
        // the half-rebuilt pipeline (decoder already gone, TLS not yet added) and
        // trap this HTTP-typed handler. With auto-read off the ClientHello stays
        // in the socket buffer until we resume below.
        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        // Strip the cleartext HTTP handlers, ack the tunnel, then layer TLS +
        // fresh HTTP handlers + the forwarding handler underneath.
        pipeline.removeHandler(name: ProxyHandlerName.httpEncoder)
            .flatMap { pipeline.removeHandler(name: ProxyHandlerName.httpDecoder) }
            .flatMap { () -> EventLoopFuture<Void> in
                var buffer = alloc.buffer(capacity: 40)
                buffer.writeString("HTTP/1.1 200 Connection established\r\n\r\n")
                return channel.writeAndFlush(buffer)
            }
            .flatMap { () -> EventLoopFuture<Void> in
                do {
                    let leaf = try self.ca.leaf(for: host)
                    let tls = try ProxyTLS.serverHandler(leaf: leaf)
                    let proxy = DecryptedProxyHandler(
                        fixedTarget: UpstreamTarget(host: host, port: port, tls: true),
                        sink: self.sink, group: self.group, verifyUpstream: self.verifyUpstream,
                        engine: self.engine, captureBodyCap: self.captureBodyCap,
                        idleTimeout: self.idleTimeout, connectTimeout: self.connectTimeout
                    )
                    let sensor = TLSHandshakeSensor(host: host, engine: self.engine)
                    // tls then sensor at the head, in order, so the sensor sits
                    // just inboard of the TLS handler and sees its handshake events.
                    return pipeline.addHandlers([tls, sensor], position: .first)
                        .flatMap {
                            pipeline.addHandlers([
                                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                HTTPResponseEncoder(),
                                proxy
                            ], position: .last)
                        }
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
            }
            .flatMap { pipeline.removeHandler(self) }
            .flatMap { () -> EventLoopFuture<Void> in
                // Pipeline ready (TLS at the head): resume reading so the buffered
                // ClientHello now flows through the TLS handler.
                channel.setOption(ChannelOptions.autoRead, value: true).map { channel.read() }
            }
            .whenFailure { _ in channel.close(promise: nil) }
    }

    /// For allowlist-excluded hosts: raw TCP relay with no TLS interception, so
    /// pinned apps keep working while still routing through the proxy.
    private func startBlindTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        let pipeline = context.pipeline
        let channel = context.channel
        let alloc = channel.allocator
        let eventLoop = channel.eventLoop

        // Same read-suppression as startMITM: the client streams raw TLS right
        // after the 200, and the relay (GlueHandler) is wired up asynchronously.
        // Hold reads until the glue is in place so raw bytes never hit this
        // HTTP-typed handler.
        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        pipeline.removeHandler(name: ProxyHandlerName.httpEncoder)
            .flatMap { pipeline.removeHandler(name: ProxyHandlerName.httpDecoder) }
            .flatMap { () -> EventLoopFuture<Void> in
                var buffer = alloc.buffer(capacity: 40)
                buffer.writeString("HTTP/1.1 200 Connection established\r\n\r\n")
                return channel.writeAndFlush(buffer)
            }
            .flatMap { () -> EventLoopFuture<Channel> in
                // Bind the upstream to the SAME event loop as the client so the
                // GlueHandler pair can read each other's writability without
                // crossing event loops — that traps in debug (assertInEventLoop)
                // and is a data race in release.
                ClientBootstrap(group: eventLoop)
                    .channelInitializer { _ in eventLoop.makeSucceededVoidFuture() }
                    .connect(host: host, port: port)
            }
            .flatMap { upstream -> EventLoopFuture<Void> in
                let (local, remote) = GlueHandler.matchedPair()
                return channel.pipeline.addHandler(local)
                    .flatMap { upstream.pipeline.addHandler(remote) }
                    .flatMap { pipeline.removeHandler(self) }
                    .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
                    .map {
                        // Glue is in place: prime the relay in both directions.
                        channel.read()
                        upstream.read()
                    }
            }
            .whenFailure { _ in channel.close(promise: nil) }
    }

    private func parseAuthority(_ uri: String) -> (host: String, port: Int) {
        if let colon = uri.lastIndex(of: ":"), let port = Int(uri[uri.index(after: colon)...]) {
            return (String(uri[..<colon]), port)
        }
        return (uri, 443)
    }
}
