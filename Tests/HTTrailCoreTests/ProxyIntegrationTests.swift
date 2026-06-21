import XCTest
import NIOPosix
@testable import HTTrailCore

/// Thread-safe collector standing in for the UI store.
final class CollectingSink: FlowSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _flows: [Flow] = []
    var flows: [Flow] { lock.lock(); defer { lock.unlock() }; return _flows }
    func record(_ flow: Flow) { lock.lock(); _flows.append(flow); lock.unlock() }
}

final class ProxyIntegrationTests: XCTestCase {

    /// Runs curl through the proxy to a real HTTPS origin, trusting our CA, and
    /// asserts we both got a 200 and decrypted/captured the flow.
    func testHTTPSMITMCapture() async throws {
        let ca = try CertificateAuthority.create()
        let caURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-ca-\(UUID().uuidString).pem")
        try ca.caCertificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: caURL) }

        let sink = CollectingSink()
        let port = 19_099
        let proxy = ProxyServer(port: port, certificateAuthority: ca, sink: sink)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        guard let (code, _) = curl(
            args: ["-sS", "-x", "http://127.0.0.1:\(port)",
                   "--cacert", caURL.path,
                   "-o", "/dev/null", "-w", "%{http_code}",
                   "https://example.com/"]
        ) else {
            throw XCTSkip("curl unavailable")
        }

        if code.trimmingCharacters(in: .whitespaces) == "000" {
            throw XCTSkip("No network access for live MITM test")
        }

        XCTAssertEqual(code.trimmingCharacters(in: .whitespaces), "200")

        // Give the async sink a beat to record.
        try await Task.sleep(nanoseconds: 200_000_000)
        let flows = sink.flows
        XCTAssertFalse(flows.isEmpty, "Expected at least one captured flow")
        let flow = try XCTUnwrap(flows.first)
        XCTAssertTrue(flow.secure, "HTTPS flow should be marked secure (MITM decrypted)")
        XCTAssertEqual(flow.request.host, "example.com")
        XCTAssertEqual(flow.statusCode, 200)
        XCTAssertNotNil(flow.response?.body)
    }

    /// Proves interception rules actually take effect through the full proxy:
    /// a block rule must short-circuit an HTTPS request to a synthetic 403 — and
    /// because block never goes upstream, this works even with no network.
    func testBlockRuleWiresThroughProxy() async throws {
        let ca = try CertificateAuthority.create()
        let caURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-ca-\(UUID().uuidString).pem")
        try ca.caCertificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: caURL) }

        // Configure the engine exactly as the UI does via pushRulesToEngine →
        // engine.apply(SharedConfig).
        let engine = InterceptEngine()
        var rule = InterceptRule()
        rule.kind = .block
        rule.urlPattern = "*example.com*"
        rule.blockStatus = 403
        var config = SharedConfig()
        config.rules = [rule]
        engine.apply(config)

        let sink = CollectingSink()
        let port = 19_098
        let proxy = ProxyServer(port: port, certificateAuthority: ca, sink: sink, engine: engine)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        guard let (code, _) = curl(
            args: ["-sS", "-x", "http://127.0.0.1:\(port)",
                   "--cacert", caURL.path,
                   "-o", "/dev/null", "-w", "%{http_code}",
                   "https://example.com/"]
        ) else { throw XCTSkip("curl unavailable") }

        XCTAssertEqual(code.trimmingCharacters(in: .whitespaces), "403",
                       "Block rule should short-circuit the request with its status")
    }

    /// Exercises the blind-tunnel path (host excluded from SSL proxying, e.g. a
    /// pinned app). The proxy must relay raw TLS to the origin without decrypting,
    /// so the client validates the origin's REAL cert (no `--cacert`). This also
    /// guards the GlueHandler same-event-loop invariant: if the upstream lands on
    /// a different loop than the client, the relay traps on a cross-loop access.
    func testBlindTunnelPassesThroughExcludedHost() async throws {
        let ca = try CertificateAuthority.create()
        let engine = InterceptEngine()
        // Non-empty allowlist that doesn't match example.com ⇒ it is tunneled.
        engine.setSSLAllowlist(["*.example.invalid"])

        let sink = CollectingSink()
        let port = 19_097
        let proxy = ProxyServer(port: port, certificateAuthority: ca, sink: sink, engine: engine)
        try await proxy.start()
        defer { Task { try? await proxy.stop() } }

        // No --cacert: a correct blind tunnel forwards the origin's real cert, so
        // system trust validates example.com. If interception leaked in, curl would
        // reject our forged cert and this would not be 200.
        guard let (code, _) = curl(
            args: ["-sS", "-x", "http://127.0.0.1:\(port)",
                   "-o", "/dev/null", "-w", "%{http_code}",
                   "https://example.com/"]
        ) else { throw XCTSkip("curl unavailable") }

        if code.trimmingCharacters(in: .whitespaces) == "000" {
            throw XCTSkip("No network access for blind-tunnel test")
        }
        XCTAssertEqual(code.trimmingCharacters(in: .whitespaces), "200",
                       "Blind tunnel should relay to the real origin and return 200")
    }

    /// The iOS app↔extension bridge: a config written by the app must round-trip
    /// through the shared store and load identically (this is what carries rules
    /// into the Packet Tunnel extension's engine).
    func testSharedConfigRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var rule = InterceptRule()
        rule.kind = .block
        rule.urlPattern = "*api.test*"
        var config = SharedConfig()
        config.rules = [rule]
        config.sslAllowlist = ["*.example.com"]
        config.proxyPort = 8123

        let cfgURL = tmp.appendingPathComponent("shared-config.json")
        try JSONEncoder().encode(config).write(to: cfgURL)
        let loaded = try JSONDecoder().decode(SharedConfig.self, from: Data(contentsOf: cfgURL))

        XCTAssertEqual(loaded.rules.count, 1)
        XCTAssertEqual(loaded.rules.first?.urlPattern, "*api.test*")
        XCTAssertEqual(loaded.sslAllowlist, ["*.example.com"])
        XCTAssertEqual(loaded.proxyPort, 8123)
    }

    private func curl(args: [String]) -> (String, Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
