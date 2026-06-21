import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Tiny HTTP server that serves a `.mobileconfig` with the MIME type
/// iOS recognises (`application/x-apple-aspen-config`). Opening its URL in
/// Safari is the supported way to install a configuration profile — iOS shows
/// "download this configuration profile", then the user installs and approves
/// it in *Settings ▸ General ▸ VPN & Device Management*. (A share sheet cannot
/// install a profile.)
///
/// Can be bound to loopback (same-device install) or `0.0.0.0` (LAN install
/// from a Mac to an iPhone that discovered this Mac via Bonjour).
public final class ProfileHTTPServer: @unchecked Sendable {
    private let payload: Data
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    public init(payload: Data) { self.payload = payload }

    /// Binds `bindHost` (loopback by default; `0.0.0.0` to serve the LAN) on an
    /// OS-assigned port and returns it.
    @discardableResult
    public func start(bindHost: String = "127.0.0.1") throws -> Int {
        let payload = self.payload
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProfileResponder(payload: payload))
                }
            }
        let ch = try bootstrap.bind(host: bindHost, port: 0).wait()
        self.channel = ch
        return ch.localAddress?.port ?? 0
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

private final class ProfileResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let payload: Data
    init(payload: Data) { self.payload = payload }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-apple-aspen-config")
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"HTTrail.mobileconfig\"")
        headers.add(name: "Content-Length", value: String(payload.count))
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
