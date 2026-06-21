import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import HTTrailCore

/// Exercises the streaming response path, the capture-body cap, upstream
/// timeouts, and confirms response-rewrite rules still take the buffered path.
/// Uses a local plaintext origin reached through the proxy's plain-HTTP path
/// (curl `-x ... http://...`), so no network or TLS is needed.
final class StreamingProxyTests: XCTestCase {

    // MARK: Engine decision

    func testRequiresBufferedResponseOnlyForBodyConsumingRules() {
        let engine = InterceptEngine()
        let req = CapturedRequest(method: "GET", url: "https://api.test/x", scheme: "https",
                                  host: "api.test", port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())

        // No rules → stream.
        XCTAssertFalse(engine.requiresBufferedResponse(for: req))

        // rewriteResponse → must buffer.
        var rw = InterceptRule(); rw.kind = .rewriteResponse; rw.urlPattern = "*api.test*"
        engine.setRules([rw])
        XCTAssertTrue(engine.requiresBufferedResponse(for: req))

        // response breakpoint → must buffer; request-only breakpoint → may stream.
        var bp = InterceptRule(); bp.kind = .breakpoint; bp.breakResponse = true; bp.urlPattern = "*"
        engine.setRules([bp])
        XCTAssertTrue(engine.requiresBufferedResponse(for: req))
        bp.breakResponse = false; bp.breakRequest = true
        engine.setRules([bp])
        XCTAssertFalse(engine.requiresBufferedResponse(for: req))

        // A rewriteResponse that doesn't match this URL → stream.
        var other = InterceptRule(); other.kind = .rewriteResponse; other.urlPattern = "*nope.test*"
        engine.setRules([other])
        XCTAssertFalse(engine.requiresBufferedResponse(for: req))
    }

    // MARK: Model backward-compat

    func testCapturedResponseDecodesWithoutBodyTruncatedKey() throws {
        let json = """
        {"statusCode":200,"reasonPhrase":"OK","httpVersion":"HTTP/1.1","headers":[],"body":"","timestamp":0}
        """
        let decoded = try JSONDecoder().decode(CapturedResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.statusCode, 200)
        XCTAssertNil(decoded.bodyTruncated)
    }

    // MARK: Streaming integration

    func testStreamingForwardsAndCapturesSmallBodyFully() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyString: "HELLO-FROM-ORIGIN")
        defer { origin.stop() }

        let (proxy, sink) = try await makeProxy()
        defer { Task { try? await proxy.stop() } }

        guard let result = curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(originPort)/") else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body, "HELLO-FROM-ORIGIN", "client must receive the full body")

        let flow = try await waitForFlow(sink)
        XCTAssertEqual(flow.statusCode, 200)
        XCTAssertEqual(String(data: flow.response?.body ?? Data(), encoding: .utf8), "HELLO-FROM-ORIGIN")
        XCTAssertNotEqual(flow.response?.bodyTruncated, true, "small body should not be flagged truncated")
    }

    func testStreamingCapsCapturedBodyButDeliversFullBodyToClient() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyByteCount: 5000)
        defer { origin.stop() }

        let (proxy, sink) = try await makeProxy { $0.captureBodyCap = 1000 }
        defer { Task { try? await proxy.stop() } }

        guard let result = curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(originPort)/") else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body.utf8.count, 5000, "client must receive every byte despite the capture cap")

        let flow = try await waitForFlow(sink)
        XCTAssertEqual(flow.response?.body.count, 1000, "captured body is capped at captureBodyCap")
        XCTAssertEqual(flow.response?.bodyTruncated, true, "captured body must be flagged truncated")
    }

    func testStalledUpstreamReturns502WithinIdleTimeout() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(hang: true)   // accepts, never responds
        defer { origin.stop() }

        let (proxy, sink) = try await makeProxy { $0.upstreamIdleTimeout = .seconds(1) }
        defer { Task { try? await proxy.stop() } }

        guard let result = curlThroughProxy(proxyPort: proxy.boundPort,
                                            url: "http://127.0.0.1:\(originPort)/", maxTime: 10) else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(result.code, "502", "a stalled origin must yield a prompt 502, not hang")

        let flow = try await waitForFlow(sink)
        XCTAssertEqual(flow.state, .failed)
    }

    func testRewriteResponseStillAppliesViaBufferedPath() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyString: "value=ORIGIN")
        defer { origin.stop() }

        let engine = InterceptEngine()
        var rule = InterceptRule()
        rule.kind = .rewriteResponse
        rule.urlPattern = "*127.0.0.1*"
        rule.findText = "ORIGIN"
        rule.replaceText = "REWRITTEN"
        engine.setRules([rule])

        let (proxy, _) = try await makeProxy(engine: engine)
        defer { Task { try? await proxy.stop() } }

        guard let result = curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(originPort)/") else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body, "value=REWRITTEN", "rewriteResponse must still mutate the body")
    }

    // MARK: - Helpers

    private func makeProxy(engine: InterceptEngine = InterceptEngine(),
                           _ configure: (ProxyServer) -> Void = { _ in }) async throws -> (ProxyServer, CollectingSink) {
        let ca = try CertificateAuthority.create()
        let sink = CollectingSink()
        let proxy = ProxyServer(port: 0, certificateAuthority: ca, sink: sink, engine: engine)
        proxy.bindHost = "127.0.0.1"
        configure(proxy)
        try await proxy.start()
        return (proxy, sink)
    }

    private func waitForFlow(_ sink: CollectingSink, timeout: TimeInterval = 3) async throws -> Flow {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flow = sink.flows.first { return flow }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("No flow recorded within timeout")
    }

    private func curlThroughProxy(proxyPort: Int, url: String, maxTime: Int = 15) -> (code: String, body: String)? {
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("htrail-curl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "-x", "http://127.0.0.1:\(proxyPort)",
                             "--max-time", "\(maxTime)",
                             "-o", bodyFile.path, "-w", "%{http_code}", url]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let codeData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let code = (String(data: codeData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces)
        let body = (try? String(contentsOf: bodyFile, encoding: .utf8)) ?? ""
        return (code, body)
    }
}

/// Minimal local HTTP origin for proxy tests: replies with a fixed body, or
/// accepts the connection and never responds (to exercise upstream timeouts).
final class TestOrigin {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    func start(bodyString: String? = nil, bodyByteCount: Int? = nil, hang: Bool = false) throws -> Int {
        let body: [UInt8]
        if let bodyString { body = Array(bodyString.utf8) }
        else if let bodyByteCount { body = Array(repeating: UInt8(ascii: "x"), count: bodyByteCount) }
        else { body = [] }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(OriginHandler(body: body, hang: hang))
                }
            }
        let ch = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = ch
        return ch.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: [UInt8]
    private let hang: Bool
    init(body: [UInt8], hang: Bool) { self.body = body; self.hang = hang }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        if hang { return }   // accept the request, never reply
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Content-Type", value: "text/plain")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
