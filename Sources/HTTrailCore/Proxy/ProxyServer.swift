import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Reliability tuning shared by the proxy data path.
public enum ProxyTuning {
    /// Max response-body bytes retained for capture. The client still receives
    /// the full body; only what we keep for the recorded ``Flow`` is capped, so a
    /// large download can't exhaust the iOS extension's tight memory budget.
    public static let defaultCaptureBodyCap = 10 * 1024 * 1024
    /// Tear down an upstream connection that goes this long without sending any
    /// bytes (stalled origin) so the client gets a prompt 502 instead of hanging.
    public static let defaultIdleTimeout: TimeAmount = .seconds(30)
    /// Give up establishing the upstream TCP/TLS connection after this long.
    public static let defaultConnectTimeout: TimeAmount = .seconds(15)
}

/// Where an intercepted request should ultimately be sent.
public struct UpstreamTarget: Sendable {
    public var host: String
    public var port: Int
    public var tls: Bool
    public init(host: String, port: Int, tls: Bool) {
        self.host = host; self.port = port; self.tls = tls
    }
}

/// A Charles-style intercepting HTTP/HTTPS proxy.
///
/// Plain HTTP requests (absolute-form URI) are proxied directly. HTTPS requests
/// arrive as `CONNECT host:443`; we answer `200`, terminate TLS using a leaf
/// certificate minted by ``CertificateAuthority`` for that host, read the
/// decrypted HTTP, forward it to the real origin over a fresh TLS connection,
/// and emit a ``Flow`` for both directions.
public final class ProxyServer: @unchecked Sendable {
    public let port: Int
    private let ca: CertificateAuthority
    private let sink: FlowSink
    private let group: EventLoopGroup
    /// True when we created `group` ourselves (and must shut it down on stop).
    /// False when a caller passed in a shared group we don't own.
    private let ownsGroup: Bool
    private var channel: Channel?
    private let stateLock = NSLock()

    /// Rule engine (block / map / rewrite / throttle / breakpoint). Shared so the
    /// UI can update rules live while the proxy runs.
    public let engine: InterceptEngine

    /// If false, upstream TLS certs are not verified (captures self-signed /
    /// pinned-bypassed endpoints — the Charles default for a debugging proxy).
    public var verifyUpstreamCertificates: Bool = false

    /// Interface to bind. `0.0.0.0` lets other devices on the LAN (e.g. an
    /// iPhone pointed at this Mac) reach the proxy; `127.0.0.1` is Mac-only.
    public var bindHost: String = "0.0.0.0"

    /// Reliability tuning (see ``ProxyTuning``). Read at `start()`.
    public var captureBodyCap: Int = ProxyTuning.defaultCaptureBodyCap
    public var upstreamIdleTimeout: TimeAmount = ProxyTuning.defaultIdleTimeout
    public var upstreamConnectTimeout: TimeAmount = ProxyTuning.defaultConnectTimeout

    public init(port: Int, certificateAuthority: CertificateAuthority, sink: FlowSink,
                engine: InterceptEngine = InterceptEngine(), group: EventLoopGroup? = nil) {
        self.port = port
        self.ca = certificateAuthority
        self.sink = sink
        self.engine = engine
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount))
            self.ownsGroup = true
        }
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return channel != nil
    }

    /// The port the listener is actually bound to. When constructed with
    /// `port: 0` the OS assigns an ephemeral port; read this after `start()`.
    public var boundPort: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return channel?.localAddress?.port ?? port
    }

    private func setChannel(_ ch: Channel?) {
        stateLock.lock(); defer { stateLock.unlock() }
        channel = ch
    }

    private func takeChannel() -> Channel? {
        stateLock.lock(); defer { stateLock.unlock() }
        let ch = channel; channel = nil; return ch
    }

    public func start() async throws {
        let ca = self.ca
        let sink = self.sink
        let group = self.group
        let verify = self.verifyUpstreamCertificates
        let engine = self.engine
        let captureBodyCap = self.captureBodyCap
        let idleTimeout = self.upstreamIdleTimeout
        let connectTimeout = self.upstreamConnectTimeout

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Named handlers so the CONNECT handler can swap them out for TLS.
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let connect = ProxyConnectHandler(ca: ca, sink: sink, group: group,
                                                  verifyUpstream: verify, engine: engine,
                                                  captureBodyCap: captureBodyCap,
                                                  idleTimeout: idleTimeout,
                                                  connectTimeout: connectTimeout)
                return channel.pipeline.addHandler(encoder, name: ProxyHandlerName.httpEncoder)
                    .flatMap { channel.pipeline.addHandler(decoder, name: ProxyHandlerName.httpDecoder) }
                    .flatMap { channel.pipeline.addHandler(connect, name: ProxyHandlerName.connect) }
            }

        let ch = try await bootstrap.bind(host: bindHost, port: port).get()
        setChannel(ch)
    }

    public func stop() async throws {
        let ch = takeChannel()
        try await ch?.close().get()
        // Only shut down the event-loop group if we created it; a caller-owned
        // group must outlive us. Without this each pair/unpair cycle leaks an
        // OS thread pool.
        if ownsGroup {
            try await group.shutdownGracefully()
        }
    }
}
