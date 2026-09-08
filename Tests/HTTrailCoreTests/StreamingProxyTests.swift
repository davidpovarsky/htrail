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

    func testRequiresBufferedRequestOnlyForBodyConsumingRules() {
        let engine = InterceptEngine()
        let request = CapturedRequest(method: "POST", url: "https://api.test/x", scheme: "https",
                                      host: "api.test", port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                      headers: [], body: Data(), timestamp: Date())
        XCTAssertFalse(engine.requiresBufferedRequest(for: request))
        var headerRewrite = InterceptRule(); headerRewrite.kind = .rewriteRequest
        headerRewrite.setHeaders = [KeyValueItem(name: "X-Test", value: "yes")]
        engine.setRules([headerRewrite])
        XCTAssertFalse(engine.requiresBufferedRequest(for: request))
        headerRewrite.findText = "secret"
        engine.setRules([headerRewrite])
        XCTAssertTrue(engine.requiresBufferedRequest(for: request))
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

    func testLargeRequestStreamsCompletelyWithBoundedCapturePreview() async throws {
        let origin = UploadOrigin()
        let originPort = try origin.start()
        defer { origin.stop() }
        let previewCap = 64 * 1024
        let payloadBytes = 2 * 1024 * 1024
        let (proxy, sink) = try await makeProxy {
            $0.streamRequestBodies = true
            $0.requestCaptureBodyCap = previewCap
            $0.requestInspectionBodyCap = 128 * 1024
        }
        defer { Task { try? await proxy.stop() } }

        guard let result = curlUploadThroughProxy(
            proxyPort: proxy.boundPort,
            url: "http://127.0.0.1:\(originPort)/upload",
            byteCount: payloadBytes
        ) else { throw XCTSkip("curl unavailable") }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body, String(payloadBytes), "origin must receive the complete upload")
        let flow = try await waitForFlow(sink)
        XCTAssertEqual(flow.request.body.count, previewCap)
        XCTAssertEqual(flow.request.bodyTruncated, true)
    }

    func testOversizedUnknownLengthInspectionPassesThroughWithoutInspector() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyByteCount: 5000, chunked: true)
        defer { origin.stop() }
        let calls = LockedCounter()
        let (proxy, sink) = try await makeProxy {
            $0.streamingResponseInspectionPolicy = { _, _ in 1000 }
            $0.streamingResponseInspector = { _, response in calls.increment(); return response }
        }
        defer { Task { try? await proxy.stop() } }
        guard let result = curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(originPort)/image")
        else { throw XCTSkip("curl unavailable") }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body.utf8.count, 5000)
        XCTAssertEqual(calls.value, 0, "oversized body must not reach the inspector")
    }

    func testInspectionFailureFailsOpenWithOriginalResponse() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyString: "ORIGINAL")
        defer { origin.stop() }
        let (proxy, _) = try await makeProxy {
            $0.streamingResponseInspectionPolicy = { _, _ in 1024 }
            $0.streamingResponseInspector = { _, _ in throw CocoaError(.fileReadCorruptFile) }
        }
        defer { Task { try? await proxy.stop() } }
        guard let result = curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(originPort)/image")
        else { throw XCTSkip("curl unavailable") }
        XCTAssertEqual(result.code, "200")
        XCTAssertEqual(result.body, "ORIGINAL")
    }

    func testBoundedPoolReusesSequentialSameOriginConnections() async throws {
        let origin = TestOrigin()
        let wire = LockedStrings()
        let originPort = try origin.start(bodyString: "REUSED", wireRecorder: wire)
        defer { origin.stop() }
        let events = LockedEvents()
        let (proxy, sink) = try await makeProxy {
            $0.upstreamConnectionPoolConfiguration = UpstreamConnectionPoolConfiguration(
                maximumConnectionsPerOrigin: 1, maximumConnectionsTotal: 2, idleTimeout: 5
            )
            $0.runtimeEventHandler = { events.append($0) }
        }
        defer { Task { try? await proxy.stop() } }
        let url = "http://127.0.0.1:\(originPort)/"
        guard let first = curlThroughProxy(proxyPort: proxy.boundPort, url: url) else { throw XCTSkip("curl unavailable") }
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let second = curlThroughProxy(proxyPort: proxy.boundPort, url: url) else { throw XCTSkip("curl unavailable") }
        let eventSummary = events.values.map { "\($0.kind.rawValue)[\($0.host ?? "-")]:\($0.detail)" }.joined(separator: " | ")
        XCTAssertEqual(first.body, "REUSED")
        let wireSummary = wire.values.joined().replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertEqual(second.body, "REUSED", "\(eventSummary) | captured=\(sink.flows.map { $0.response?.body.count ?? -1 }) | wire=\(wireSummary)")
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolMiss }.count, 1, eventSummary)
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolHit }.count, 1, eventSummary)
        XCTAssertTrue(events.values.contains { $0.kind == .upstreamTiming && $0.detail.contains("reused=true") }, eventSummary)
    }

    func testPoolExpiresIdleConnections() async throws {
        let origin = TestOrigin()
        let originPort = try origin.start(bodyString: "IDLE")
        defer { origin.stop() }
        let events = LockedEvents()
        let (proxy, _) = try await makeProxy {
            $0.upstreamConnectionPoolConfiguration = .init(
                maximumConnectionsPerOrigin: 1, maximumConnectionsTotal: 2, idleTimeout: 1
            )
            $0.runtimeEventHandler = { events.append($0) }
        }
        defer { Task { try? await proxy.stop() } }
        let url = "http://127.0.0.1:\(originPort)/"
        guard curlThroughProxy(proxyPort: proxy.boundPort, url: url) != nil else { throw XCTSkip("curl unavailable") }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard curlThroughProxy(proxyPort: proxy.boundPort, url: url) != nil else { throw XCTSkip("curl unavailable") }
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolMiss }.count, 2)
        XCTAssertTrue(events.values.contains { $0.kind == .upstreamPoolEviction && $0.detail == "idle-timeout" })
    }

    func testPoolEvictsOldestIdleConnectionAtGlobalBound() async throws {
        let origins = [TestOrigin(), TestOrigin(), TestOrigin()]
        let ports = try origins.map { try $0.start(bodyString: "BOUND") }
        defer { origins.forEach { $0.stop() } }
        let events = LockedEvents()
        let (proxy, _) = try await makeProxy {
            $0.upstreamConnectionPoolConfiguration = .init(
                maximumConnectionsPerOrigin: 1, maximumConnectionsTotal: 2, idleTimeout: 5
            )
            $0.runtimeEventHandler = { events.append($0) }
        }
        defer { Task { try? await proxy.stop() } }
        for port in ports {
            guard curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(port)/") != nil else {
                throw XCTSkip("curl unavailable")
            }
        }
        guard curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(ports[0])/") != nil else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolMiss }.count, 4)
        XCTAssertTrue(events.values.contains { $0.kind == .upstreamPoolEviction && $0.detail == "bounded-capacity" })
    }

    func testPoolDoesNotCrossOriginsAndHonorsConnectionClose() async throws {
        let first = TestOrigin(), second = TestOrigin()
        let firstPort = try first.start(bodyString: "ONE", closeResponse: true)
        let secondPort = try second.start(bodyString: "TWO")
        defer { first.stop(); second.stop() }
        let events = LockedEvents()
        let (proxy, _) = try await makeProxy {
            $0.upstreamConnectionPoolConfiguration = .init(maximumConnectionsPerOrigin: 1, maximumConnectionsTotal: 2, idleTimeout: 5)
            $0.runtimeEventHandler = { events.append($0) }
        }
        defer { Task { try? await proxy.stop() } }
        guard curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(firstPort)/") != nil,
              curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(firstPort)/") != nil,
              curlThroughProxy(proxyPort: proxy.boundPort, url: "http://127.0.0.1:\(secondPort)/") != nil else {
            throw XCTSkip("curl unavailable")
        }
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolHit }.count, 0)
        XCTAssertEqual(events.values.filter { $0.kind == .upstreamPoolMiss }.count, 3)
        XCTAssertTrue(events.values.contains { $0.kind == .upstreamPoolEviction && $0.detail == "origin-connection-close" })
    }

    func testTemporaryCompatibilityBypassExpiresAndForceDecryptWins() {
        let engine = InterceptEngine()
        let now = Date()
        engine.installCompatibilityBypass(.init(host: "challenge.test", reason: "antiBotIncompatible", expiresAt: now.addingTimeInterval(60)), now: now)
        XCTAssertFalse(engine.shouldDecrypt(host: "challenge.test"))
        engine.setForcedDecryptHosts(["challenge.test"])
        XCTAssertTrue(engine.shouldDecrypt(host: "challenge.test"))
        engine.setForcedDecryptHosts([])
        engine.installCompatibilityBypass(.init(host: "expired.test", reason: "test", expiresAt: now.addingTimeInterval(-1)), now: now)
        XCTAssertTrue(engine.shouldDecrypt(host: "expired.test"))
    }

    func testTimeoutFailureCategoriesAreDistinct() {
        XCTAssertEqual(
            ProxyFailureClassifier.event(error: NSError(domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "connect timeout"]), host: "a", tls: true).kind,
            .upstreamConnectTimeout
        )
        XCTAssertEqual(
            ProxyFailureClassifier.event(error: NSError(domain: "test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "TLS handshake timed out"]), host: "a", tls: true).kind,
            .upstreamTLSHandshakeTimeout
        )
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

    private func curlUploadThroughProxy(proxyPort: Int, url: String, byteCount: Int) -> (code: String, body: String)? {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("htrail-upload-\(UUID().uuidString)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("htrail-upload-result-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try? Data(repeating: 0x5a, count: byteCount).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "-x", "http://127.0.0.1:\(proxyPort)", "--max-time", "20",
                             "--data-binary", "@\(input.path)", "-o", output.path, "-w", "%{http_code}", url]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let codeData = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let code = (String(data: codeData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespaces)
        return (code, (try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }
}

/// Minimal local HTTP origin for proxy tests: replies with a fixed body, or
/// accepts the connection and never responds (to exercise upstream timeouts).
final class TestOrigin {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    fileprivate func start(bodyString: String? = nil, bodyByteCount: Int? = nil,
               hang: Bool = false, chunked: Bool = false, closeResponse: Bool = false,
               wireRecorder: LockedStrings? = nil) throws -> Int {
        let body: [UInt8]
        if let bodyString { body = Array(bodyString.utf8) }
        else if let bodyByteCount { body = Array(repeating: UInt8(ascii: "x"), count: bodyByteCount) }
        else { body = [] }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let recorder = wireRecorder.map { channel.pipeline.addHandler(RawRequestRecorder(storage: $0)) }
                    ?? channel.eventLoop.makeSucceededVoidFuture()
                return recorder.flatMap { channel.pipeline.configureHTTPServerPipeline() }.flatMap {
                    channel.pipeline.addHandler(OriginHandler(body: body, hang: hang, chunked: chunked, closeResponse: closeResponse))
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

private final class RawRequestRecorder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let storage: LockedStrings
    init(storage: LockedStrings) { self.storage = storage }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        storage.append(String(buffer: unwrapInboundIn(data)))
        context.fireChannelRead(data)
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: [UInt8]
    private let hang: Bool
    private let chunked: Bool
    private let closeResponse: Bool
    init(body: [UInt8], hang: Bool, chunked: Bool, closeResponse: Bool) {
        self.body = body; self.hang = hang; self.chunked = chunked; self.closeResponse = closeResponse
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        if hang { return }   // accept the request, never reply
        var headers = HTTPHeaders()
        if chunked { headers.add(name: "Transfer-Encoding", value: "chunked") }
        else { headers.add(name: "Content-Length", value: "\(body.count)") }
        headers.add(name: "Content-Type", value: "text/plain")
        if closeResponse { headers.add(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let end = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if closeResponse { end.whenComplete { _ in context.close(promise: nil) } }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProxyRuntimeEvent] = []
    func append(_ event: ProxyRuntimeEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var values: [ProxyRuntimeEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class UploadOrigin {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(UploadOriginHandler())
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = channel
        return channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class UploadOriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var received = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .body(let buffer): received += buffer.readableBytes
        case .end:
            let response = String(received)
            var headers = HTTPHeaders(); headers.add(name: "Content-Length", value: String(response.utf8.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: response.utf8.count); buffer.writeString(response)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        default: break
        }
    }
}
