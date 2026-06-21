import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Body an iPhone POSTs to /pair: its own CA so the Mac can decrypt that
/// device's traffic with a CA the iPhone already trusts.
public struct PairRequest: Codable, Sendable {
    public var deviceName: String
    public var deviceID: String
    public var caCertPEM: String
    public var caKeyPEM: String
    public init(deviceName: String, deviceID: String, caCertPEM: String, caKeyPEM: String) {
        self.deviceName = deviceName; self.deviceID = deviceID
        self.caCertPEM = caCertPEM; self.caKeyPEM = caKeyPEM
    }
}

/// Reply: the dedicated proxy port the Mac stood up for this device.
public struct PairResponse: Codable, Sendable {
    public var proxyPort: Int
    public var sessionName: String
    public init(proxyPort: Int, sessionName: String) {
        self.proxyPort = proxyPort; self.sessionName = sessionName
    }
}

/// Tiny LAN HTTP server the Mac runs while discoverable. Accepts a device's CA
/// upload (`POST /pair`) and a teardown (`POST /unpair`). The CA material it
/// receives is handed to `onPair` and never persisted by this type.
public final class PairingServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    /// Invoked with the uploaded CA; returns the dedicated proxy port (nil = 500).
    public var onPair: ((PairRequest) async -> PairResponse?)?
    /// Invoked with a deviceID to tear down its proxy.
    public var onUnpair: ((String) async -> Void)?

    public init() {}

    @discardableResult
    public func start(bindHost: String = "0.0.0.0") throws -> Int {
        let onPair = { [weak self] (r: PairRequest) async -> PairResponse? in await self?.onPair?(r) ?? nil }
        let onUnpair: (String) async -> Void = { [weak self] (id: String) in await self?.onUnpair?(id) ?? () }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(PairingResponder(onPair: onPair, onUnpair: onUnpair))
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

private final class PairingResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let onPair: (PairRequest) async -> PairResponse?
    private let onUnpair: (String) async -> Void
    private var path = ""
    private var body = ByteBuffer()

    init(onPair: @escaping (PairRequest) async -> PairResponse?,
         onUnpair: @escaping (String) async -> Void) {
        self.onPair = onPair; self.onUnpair = onUnpair
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            let bytes = Data(body.readableBytesView)
            let route = path
            let channel = context.channel
            let onPair = self.onPair
            let onUnpair = self.onUnpair
            let responder = self
            Task {
                let (status, payload) = await Self.handle(route: route, body: bytes,
                                                          onPair: onPair, onUnpair: onUnpair)
                channel.eventLoop.execute {
                    responder.respond(channel: channel, status: status, json: payload)
                }
            }
        }
    }

    private static func handle(route: String, body: Data,
                               onPair: (PairRequest) async -> PairResponse?,
                               onUnpair: (String) async -> Void) async -> (HTTPResponseStatus, Data) {
        if route.hasPrefix("/pair") {
            guard let req = try? JSONDecoder().decode(PairRequest.self, from: body) else {
                return (.badRequest, Data("{\"error\":\"bad json\"}".utf8))
            }
            guard let resp = await onPair(req), let data = try? JSONEncoder().encode(resp) else {
                return (.internalServerError, Data("{\"error\":\"pair failed\"}".utf8))
            }
            return (.ok, data)
        } else if route.hasPrefix("/unpair") {
            struct U: Codable { var deviceID: String }
            guard let u = try? JSONDecoder().decode(U.self, from: body) else {
                return (.badRequest, Data("{\"error\":\"bad json\"}".utf8))
            }
            await onUnpair(u.deviceID)
            return (.ok, Data("{}".utf8))
        }
        return (.notFound, Data("{\"error\":\"not found\"}".utf8))
    }

    private func respond(channel: Channel, status: HTTPResponseStatus, json: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(json.count))
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(wrapOutboundOut(.head(head)), promise: nil)
        var buf = channel.allocator.buffer(capacity: json.count)
        buf.writeBytes(json)
        channel.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        channel.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
