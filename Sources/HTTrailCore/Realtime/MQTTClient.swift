import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// A compact MQTT 3.1.1 client (CONNECT / SUBSCRIBE / PUBLISH QoS0 / PINGREQ)
/// for the Hoppscotch "MQTT" realtime tab. Built directly on SwiftNIO.
public final class MQTTClient: @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case message(topic: String, payload: String)
        case disconnected
        case error(String)
    }

    private let group: EventLoopGroup
    private var channel: Channel?
    private let lock = NSLock()
    private var packetID: UInt16 = 1

    public init(group: EventLoopGroup? = nil) {
        self.group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func connect(host: String, port: Int, tls: Bool = false, clientID: String = "httrail")
        -> AsyncStream<Event> {
        AsyncStream { continuation in
            let handler = MQTTHandler(clientID: clientID, continuation: continuation)
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    do {
                        var handlers: [ChannelHandler] = []
                        if tls {
                            var config = TLSConfiguration.makeClientConfiguration()
                            config.certificateVerification = .none
                            let context = try NIOSSLContext(configuration: config)
                            handlers.append(try NIOSSLClientHandler(context: context, serverHostname: host))
                        }
                        handlers.append(ByteToMessageHandler(MQTTFrameDecoder()))
                        handlers.append(handler)
                        return channel.pipeline.addHandlers(handlers)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .success(let channel):
                    self.lock.lock(); self.channel = channel; self.lock.unlock()
                case .failure(let error):
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in self.close() }
        }
    }

    public func subscribe(topic: String) {
        lock.lock(); let channel = self.channel; let id = nextPacketID(); lock.unlock()
        guard let channel else { return }
        var buffer = channel.allocator.buffer(capacity: 32)
        var payload = channel.allocator.buffer(capacity: 16)
        payload.writeInteger(id)
        MQTTCodec.writeString(topic, to: &payload)
        payload.writeInteger(UInt8(0)) // QoS 0
        MQTTCodec.writeFixedHeader(type: 8, flags: 0x02, length: payload.readableBytes, to: &buffer)
        buffer.writeBuffer(&payload)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func publish(topic: String, message: String) {
        lock.lock(); let channel = self.channel; lock.unlock()
        guard let channel else { return }
        var buffer = channel.allocator.buffer(capacity: 32)
        var payload = channel.allocator.buffer(capacity: 32)
        MQTTCodec.writeString(topic, to: &payload)   // QoS 0 → no packet id
        payload.writeString(message)
        MQTTCodec.writeFixedHeader(type: 3, flags: 0x00, length: payload.readableBytes, to: &buffer)
        buffer.writeBuffer(&payload)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func close() {
        lock.lock(); let channel = self.channel; self.channel = nil; lock.unlock()
        channel?.close(promise: nil)
    }

    private func nextPacketID() -> UInt16 {
        let id = packetID
        packetID = packetID == UInt16.max ? 1 : packetID + 1
        return id
    }
}

/// MQTT packet after framing: control type + flags + variable bytes.
struct MQTTPacket {
    let type: UInt8
    let flags: UInt8
    var bytes: ByteBuffer
}

enum MQTTCodec {
    static func writeString(_ string: String, to buffer: inout ByteBuffer) {
        let utf8 = Array(string.utf8)
        buffer.writeInteger(UInt16(utf8.count))
        buffer.writeBytes(utf8)
    }

    static func writeFixedHeader(type: UInt8, flags: UInt8, length: Int, to buffer: inout ByteBuffer) {
        buffer.writeInteger((type << 4) | flags)
        var value = length
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            buffer.writeInteger(byte)
        } while value > 0
    }
}

/// Frames incoming MQTT packets using the remaining-length varint.
final class MQTTFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = MQTTPacket

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let start = buffer.readerIndex
        guard let header = buffer.getInteger(at: start, as: UInt8.self) else { return .needMoreData }

        var multiplier = 1
        var length = 0
        var lengthBytes = 0
        var index = start + 1
        while true {
            guard let encoded = buffer.getInteger(at: index, as: UInt8.self) else { return .needMoreData }
            length += Int(encoded & 0x7F) * multiplier
            multiplier *= 128
            index += 1
            lengthBytes += 1
            if encoded & 0x80 == 0 { break }
            if lengthBytes > 4 { throw MQTTError.malformed }
        }

        let headerLength = 1 + lengthBytes
        guard buffer.readableBytes >= headerLength + length else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: headerLength)
        let payload = buffer.readSlice(length: length) ?? ByteBufferAllocator().buffer(capacity: 0)
        let packet = MQTTPacket(type: header >> 4, flags: header & 0x0F, bytes: payload)
        context.fireChannelRead(wrapInboundOut(packet))
        return .continue
    }

    enum MQTTError: Error { case malformed }
}

/// Sends CONNECT on connect, replies to PINGREQ, and surfaces CONNACK / PUBLISH.
final class MQTTHandler: ChannelInboundHandler {
    typealias InboundIn = MQTTPacket
    typealias OutboundOut = ByteBuffer

    private let clientID: String
    private let continuation: AsyncStream<MQTTClient.Event>.Continuation

    init(clientID: String, continuation: AsyncStream<MQTTClient.Event>.Continuation) {
        self.clientID = clientID
        self.continuation = continuation
    }

    func channelActive(context: ChannelHandlerContext) {
        var payload = context.channel.allocator.buffer(capacity: 32)
        MQTTCodec.writeString("MQTT", to: &payload)   // protocol name
        payload.writeInteger(UInt8(4))                // protocol level 3.1.1
        payload.writeInteger(UInt8(0x02))             // clean session
        payload.writeInteger(UInt16(60))              // keepalive
        MQTTCodec.writeString(clientID, to: &payload) // client id

        var buffer = context.channel.allocator.buffer(capacity: 40)
        MQTTCodec.writeFixedHeader(type: 1, flags: 0, length: payload.readableBytes, to: &buffer)
        buffer.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        switch packet.type {
        case 2: // CONNACK
            continuation.yield(.connected)
        case 3: // PUBLISH (QoS 0)
            if let topicLen = packet.bytes.readInteger(as: UInt16.self),
               let topic = packet.bytes.readString(length: Int(topicLen)) {
                let message = packet.bytes.readString(length: packet.bytes.readableBytes) ?? ""
                continuation.yield(.message(topic: topic, payload: message))
            }
        case 12: // PINGREQ → PINGRESP
            var pong = context.channel.allocator.buffer(capacity: 2)
            MQTTCodec.writeFixedHeader(type: 13, flags: 0, length: 0, to: &pong)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.yield(.disconnected)
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.error(error.localizedDescription))
        context.close(promise: nil)
    }
}
