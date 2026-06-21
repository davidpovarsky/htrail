import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// Detects whether the HTTrail root CA is installed **and trusted** by the system
/// trust store — without any keychain API (which iOS doesn't expose to apps).
///
/// It stands up a throwaway HTTPS server on loopback presenting a leaf signed by
/// our CA, then makes a default-trust `URLSession` request to it. The request
/// only succeeds if the OS trusts the chain, i.e. the user installed the profile
/// *and* enabled full trust for the certificate. Any TLS trust failure → false.
public enum CATrustProbe {
    public static func check(ca: CertificateAuthority, timeout: TimeInterval = 5) async -> Bool {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // Mint a leaf for the loopback IP literal so URLSession's hostname check
        // matches the cert's IP SAN (avoids localhost's v4/v6 resolution ambiguity).
        guard let leaf = try? ca.leaf(for: "127.0.0.1"),
              let bootstrap = try? makeBootstrap(group: group, leaf: leaf),
              let channel = try? await bootstrap.bind(host: "127.0.0.1", port: 0).get(),
              let port = channel.localAddress?.port,
              let url = URL(string: "https://127.0.0.1:\(port)/") else {
            return false
        }
        defer { channel.close(promise: nil) }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        // This is a pure trust-store question — it must reach our loopback server
        // directly. Disable any system/VPN proxy so an active capture tunnel
        // (whose proxy settings match every host, including 127.0.0.1) can't
        // divert the probe to the Mac and make a trusted CA look untrusted.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.data(for: request)
            return true   // chain validated against the system trust store
        } catch {
            return false  // untrusted/missing CA → server cert rejected
        }
    }

    private static func makeBootstrap(group: EventLoopGroup,
                                      leaf: CertificateAuthority.LeafMaterial) throws -> ServerBootstrap {
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(leaf.certificateChainPEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
        let tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) }, privateKey: .privateKey(key))
        let context = try NIOSSLContext(configuration: tlsConfig)
        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: context))
                    .flatMap { channel.pipeline.configureHTTPServerPipeline() }
                    .flatMap { channel.pipeline.addHandler(ProbeResponder()) }
            }
    }
}

/// Replies `200 ok` to any request then closes — just enough for URLSession to
/// complete a request (and therefore a TLS trust evaluation) against us.
private final class ProbeResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "2")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var body = context.channel.allocator.buffer(capacity: 2)
        body.writeString("ok")
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
