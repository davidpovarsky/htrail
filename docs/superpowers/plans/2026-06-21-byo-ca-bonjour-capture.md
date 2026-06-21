# BYO-CA Bonjour Capture + Broadcast Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Mac broadcast over Bonjour the moment the toggle is on (with visible publish state), and let an iPhone capture to the Mac using the iPhone's *own* CA — uploaded to a per-device proxy on the Mac — so no Mac CA is ever installed on the phone.

**Architecture:** A reconstructable `CertificateAuthority` + a small `PairingServer` on the Mac that accepts an uploaded CA and spins up a dedicated, ephemeral-port `ProxyServer` per device, recording into a per-device session. The uploaded CA stays in memory and is never keychain-trusted. Bonjour advertising is decoupled from manual proxy-start and reports publish success/failure.

**Tech Stack:** Swift 5 (HTTrailCore in `.v5` language mode), SwiftNIO (HTTP server + proxy), swift-certificates / swift-crypto (CA), Foundation `NetService` (Bonjour), XCTest.

**Reference spec:** `docs/superpowers/specs/2026-06-21-byo-ca-bonjour-capture-design.md`

**Notes for the implementer:**
- This repo is **not** a git repo — **skip all `git commit` steps**. Treat "Commit" steps as "save and move on".
- `swift test --filter X` reports "0 tests" in this shell. Run the **full** suite: `swift test 2>&1 | tail -30`, and grep for your case: `swift test 2>&1 | grep -A6 <TestName>`.
- `swift test` builds the **macOS** app target too, so iOS-only (`#if os(iOS)`) code is *not* compiled by it. iOS code is verified with the iOS build (Tasks 8 & 10).
- HTTrailCore is Swift 5 language mode — don't add strict-concurrency annotations to it.

---

### Task 1: Reconstructable CA + private-key export

**Files:**
- Modify: `Sources/HTTrailCore/CertificateAuthority.swift`
- Test: `Tests/HTTrailCoreTests/CertificateAuthorityReconstructTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/CertificateAuthorityReconstructTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class CertificateAuthorityReconstructTests: XCTestCase {
    func testReconstructFromPEMMintsLeafChainingToSameRoot() throws {
        let original = try CertificateAuthority.create()
        let certPEM = original.caCertificatePEM
        let keyPEM = original.caPrivateKeyPEM
        XCTAssertFalse(certPEM.isEmpty)
        XCTAssertTrue(keyPEM.contains("PRIVATE KEY"))

        let restored = try CertificateAuthority.from(certificatePEM: certPEM, keyPEM: keyPEM)
        // Same root certificate.
        XCTAssertEqual(restored.caCertificateDER, original.caCertificateDER)
        // Restored CA can mint a leaf, and the chain includes the shared root.
        let leaf = try restored.leaf(for: "example.com")
        XCTAssertTrue(leaf.certificateChainPEM.contains(original.caCertificatePEM))
        XCTAssertTrue(leaf.privateKeyPEM.contains("PRIVATE KEY"))
    }

    func testReconstructFromGarbageThrows() {
        XCTAssertThrowsError(try CertificateAuthority.from(certificatePEM: "nope", keyPEM: "nope"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 CertificateAuthorityReconstructTests`
Expected: FAIL — `caPrivateKeyPEM` / `from(certificatePEM:keyPEM:)` don't exist (compile error).

- [ ] **Step 3: Implement**

In `Sources/HTTrailCore/CertificateAuthority.swift`, add the private-key accessor near `caCertificatePEM` (around line 40):

```swift
    /// PEM of the root CA EC private key. Needed so a device can hand its CA to
    /// another HTTrail instance (Bonjour capture-to-Mac). Sensitive — only sent
    /// over the trusted LAN; never persisted by the receiver.
    public var caPrivateKeyPEM: String { caBackingKey.pemRepresentation }
```

Add the factory in the `// MARK: - Loading / creation` section, and refactor `loadOrCreate` to use it. Replace the existing-file branch inside `loadOrCreate` (lines ~60-70) so it calls the new factory:

```swift
        if fm.fileExists(atPath: certURL.path), fm.fileExists(atPath: keyURL.path) {
            let certPEM = try String(contentsOf: certURL, encoding: .utf8)
            let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
            return try from(certificatePEM: certPEM, keyPEM: keyPEM)
        }
```

Then add the factory itself (e.g. right after `loadOrCreate`):

```swift
    /// Reconstruct a CA from externally supplied PEM material (e.g. a CA uploaded
    /// by an iPhone for capture-to-Mac). The reconstructed CA is identical to the
    /// source and mints leaves the source's trust store accepts.
    public static func from(certificatePEM: String, keyPEM: String) throws -> CertificateAuthority {
        let backingKey = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        let cert = try Certificate(pemEncoded: certificatePEM)
        return CertificateAuthority(
            certificate: cert,
            privateKey: Certificate.PrivateKey(backingKey),
            backingKey: backingKey
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 CertificateAuthorityReconstructTests`
Expected: both tests pass.

- [ ] **Step 5: Commit** (skip — not a git repo)

---

### Task 2: Expose the actually-bound proxy port

**Files:**
- Modify: `Sources/HTTrailCore/Proxy/ProxyServer.swift`
- Test: `Tests/HTTrailCoreTests/ProxyServerBoundPortTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/ProxyServerBoundPortTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class ProxyServerBoundPortTests: XCTestCase {
    func testEphemeralBindReportsRealPort() async throws {
        let ca = try CertificateAuthority.create()
        let bridge = FlowBridge()
        let server = ProxyServer(port: 0, certificateAuthority: ca, sink: bridge)
        try await server.start()
        defer { Task { try? await server.stop() } }
        XCTAssertGreaterThan(server.boundPort, 0)
        XCTAssertNotEqual(server.boundPort, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 ProxyServerBoundPortTests`
Expected: FAIL — `boundPort` doesn't exist.

- [ ] **Step 3: Implement**

In `Sources/HTTrailCore/Proxy/ProxyServer.swift`, add after the `isRunning` computed property (around line 56):

```swift
    /// The port the listener is actually bound to. When constructed with
    /// `port: 0` the OS assigns an ephemeral port; read this after `start()`.
    public var boundPort: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return channel?.localAddress?.port ?? port
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 ProxyServerBoundPortTests`
Expected: PASS.

- [ ] **Step 5: Commit** (skip)

---

### Task 3: Bonjour TXT + DiscoveredProxy gain `pairPort`

**Files:**
- Modify: `Sources/HTTrailCore/Discovery/BonjourService.swift`
- Test: `Tests/HTTrailCoreTests/` — add a case to the existing Bonjour test file if present, else create `BonjourPairPortTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/BonjourPairPortTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class BonjourPairPortTests: XCTestCase {
    func testTXTRoundTripIncludesPairPort() {
        let txt = BonjourTXT.encode(name: "Mac", port: 9090, caPort: 0, caFP: "", pairPort: 54321)
        let decoded = BonjourTXT.decode(txt)
        XCTAssertEqual(decoded.name, "Mac")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertEqual(decoded.pairPort, 54321)
    }

    func testDecodeToleratesMissingPairPort() {
        let legacy: [String: Data] = ["name": Data("Mac".utf8), "port": Data("9090".utf8)]
        let decoded = BonjourTXT.decode(legacy)
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertNil(decoded.pairPort)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 BonjourPairPortTests`
Expected: FAIL — `encode` has no `pairPort:` param; `decode` tuple has no `pairPort`.

- [ ] **Step 3: Implement**

In `Sources/HTTrailCore/Discovery/BonjourService.swift`:

Update `BonjourTXT.encode`/`decode`:

```swift
public enum BonjourTXT {
    public static func encode(name: String, port: Int, caPort: Int, caFP: String, pairPort: Int) -> [String: Data] {
        [
            "name": Data(name.utf8),
            "port": Data(String(port).utf8),
            "caPort": Data(String(caPort).utf8),
            "caFP": Data(caFP.utf8),
            "pairPort": Data(String(pairPort).utf8),
        ]
    }

    public static func decode(_ txt: [String: Data]) -> (name: String?, port: Int?, caPort: Int?, caFP: String?, pairPort: Int?) {
        func str(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        return (str("name"), str("port").flatMap(Int.init), str("caPort").flatMap(Int.init), str("caFP"), str("pairPort").flatMap(Int.init))
    }
}
```

Add `pairPort` to `DiscoveredProxy`:

```swift
public struct DiscoveredProxy: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var caPort: Int
    public var caFP: String
    public var pairPort: Int   // Mac PairingServer port (0 if absent)

    public init(id: String, name: String, host: String, port: Int, caPort: Int, caFP: String, pairPort: Int) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.caPort = caPort; self.caFP = caFP; self.pairPort = pairPort
    }
}
```

Update `BonjourAdvertiser.start` to accept and encode `pairPort`:

```swift
    public func start(name: String, port: Int, caPort: Int, caFP: String, pairPort: Int) {
        stop()
        let svc = NetService(domain: BonjourConfig.domain, type: BonjourConfig.serviceType,
                             name: name, port: Int32(port))
        svc.delegate = self
        svc.setTXTRecord(NetService.data(fromTXTRecord: BonjourTXT.encode(
            name: name, port: port, caPort: caPort, caFP: caFP, pairPort: pairPort)))
        svc.publish()
        service = svc
    }
```

Update `netServiceDidResolveAddress` to populate `pairPort`:

```swift
        let proxy = DiscoveredProxy(
            id: service.name,
            name: fields.name ?? service.name,
            host: host.hasSuffix(".") ? String(host.dropLast()) : host,
            port: fields.port ?? (service.port > 0 ? service.port : 9090),
            caPort: fields.caPort ?? 0,
            caFP: fields.caFP ?? "",
            pairPort: fields.pairPort ?? 0)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 BonjourPairPortTests`
Expected: PASS. Also run the full suite to catch any other `encode/start/DiscoveredProxy` callers that now need the new argument: `swift test 2>&1 | tail -30`. Fix any compile errors at call sites by passing `pairPort:` (they will be re-touched properly in Tasks 6–8; for now pass `pairPort: 0` to keep the build green).

- [ ] **Step 5: Commit** (skip)

---

### Task 4: BonjourAdvertiser publish-state callback

**Files:**
- Modify: `Sources/HTTrailCore/Discovery/BonjourService.swift`
- Test: `Tests/HTTrailCoreTests/BonjourPublishStateTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/BonjourPublishStateTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class BonjourPublishStateTests: XCTestCase {
    func testPublishEmitsPublishingThenPublished() {
        let adv = BonjourAdvertiser()
        let publishing = expectation(description: "publishing")
        let published = expectation(description: "published")
        var sawPublishing = false
        adv.onState = { state in
            switch state {
            case .publishing: if !sawPublishing { sawPublishing = true; publishing.fulfill() }
            case .published: published.fulfill()
            case .failed: break
            }
        }
        adv.start(name: "HTTrailTest-\(UUID().uuidString.prefix(6))", port: 9099, caPort: 0, caFP: "", pairPort: 9098)
        wait(for: [publishing, published], timeout: 10)
        adv.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 BonjourPublishStateTests`
Expected: FAIL — `onState` / `BonjourPublishState` don't exist. (If the publish callback proves environment-flaky in CI, this test may be marked `XCTSkip`, but it passes in this dev environment where live Bonjour works.)

- [ ] **Step 3: Implement**

In `Sources/HTTrailCore/Discovery/BonjourService.swift`, add the state enum near the top:

```swift
/// Result of attempting to advertise over Bonjour.
public enum BonjourPublishState: Sendable, Equatable {
    case publishing
    case published
    case failed(String)
}
```

Extend `BonjourAdvertiser` — add the callback property, emit `.publishing` on `start`, and implement the delegate methods:

```swift
public final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    /// Reports publish success/failure so the UI can surface it.
    public var onState: ((BonjourPublishState) -> Void)?

    public func start(name: String, port: Int, caPort: Int, caFP: String, pairPort: Int) {
        stop()
        let svc = NetService(domain: BonjourConfig.domain, type: BonjourConfig.serviceType,
                             name: name, port: Int32(port))
        svc.delegate = self
        svc.setTXTRecord(NetService.data(fromTXTRecord: BonjourTXT.encode(
            name: name, port: port, caPort: caPort, caFP: caFP, pairPort: pairPort)))
        onState?(.publishing)
        svc.publish()
        service = svc
    }

    public func stop() {
        service?.stop()
        service = nil
    }

    public func netServiceDidPublish(_ sender: NetService) {
        onState?(.published)
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        onState?(.failed("Bonjour publish failed (error \(code)). Check System Settings ▸ Privacy ▸ Local Network."))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 BonjourPublishStateTests`
Expected: PASS.

- [ ] **Step 5: Commit** (skip)

---

### Task 5: PairingServer (Mac-side CA upload endpoint)

**Files:**
- Create: `Sources/HTTrailCore/Discovery/PairingServer.swift`
- Test: `Tests/HTTrailCoreTests/PairingServerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/PairingServerTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class PairingServerTests: XCTestCase {
    func testPairInvokesHandlerAndReturnsPort() async throws {
        let server = PairingServer()
        server.onPair = { req in
            XCTAssertEqual(req.deviceName, "iPhone")
            XCTAssertEqual(req.caCertPEM, "CERT")
            return PairResponse(proxyPort: 6789, sessionName: "iPhone session")
        }
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }

        let body = try JSONEncoder().encode(PairRequest(
            deviceName: "iPhone", deviceID: "dev-1", caCertPEM: "CERT", caKeyPEM: "KEY"))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let decoded = try JSONDecoder().decode(PairResponse.self, from: data)
        XCTAssertEqual(decoded.proxyPort, 6789)
    }

    func testMalformedBodyReturns400() async throws {
        let server = PairingServer()
        server.onPair = { _ in PairResponse(proxyPort: 1, sessionName: "x") }
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.httpBody = Data("not json".utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 400)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 PairingServerTests`
Expected: FAIL — `PairingServer` / `PairRequest` / `PairResponse` don't exist.

- [ ] **Step 3: Implement**

Create `Sources/HTTrailCore/Discovery/PairingServer.swift`:

```swift
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
        let onUnpair = { [weak self] (id: String) async in await self?.onUnpair?(id) }
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
            Task {
                let (status, payload) = await Self.handle(route: route, body: bytes,
                                                          onPair: onPair, onUnpair: onUnpair)
                channel.eventLoop.execute {
                    Self.respond(channel: channel, status: status, json: payload)
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

    private static func respond(channel: Channel, status: HTTPResponseStatus, json: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(json.count))
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        var buf = channel.allocator.buffer(capacity: json.count)
        buf.writeBytes(json)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 PairingServerTests`
Expected: both tests pass.

- [ ] **Step 5: Commit** (skip)

---

### Task 6: AppModel (macOS) pairing registry + device-flow ingest

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift`
- Test: `Tests/HTTrailCoreTests/AppModelPairingTests.swift` (create)

**Context:** `ingest(_:)` (line ~321) stamps the active session and bumps its `recordCount`. We add a parallel path for device proxies that records into a *device* session without disturbing the Mac's own `activeSessionID`. `sessionStore.createSession(name:startedAt:)` returns a `CaptureSession`; `sessionStore.record(_ flow:in:)` persists. `FlowBridge` (line 12) is the `FlowSink` that hops to main; we create one per device.

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/AppModelPairingTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

@MainActor
final class AppModelPairingTests: XCTestCase {
    private func makeModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-pair-\(UUID().uuidString)", isDirectory: true)
        return AppModel(sessionStore: CaptureSessionStore(directory: dir))
    }

    private func flow(host: String) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                    headers: [], body: Data(), timestamp: Date())
        return Flow(request: req, response: resp, state: .completed,
                    startedAt: Date(), endedAt: Date(), secure: true)
    }

    func testPairDeviceStartsDistinctProxyAndRecordsFlows() async throws {
        let model = makeModel()
        let ca = try CertificateAuthority.create()
        let req = PairRequest(deviceName: "TestPhone", deviceID: "dev-1",
                              caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM)
        let resp = await model.pairDevice(req)
        let unwrapped = try XCTUnwrap(resp)
        XCTAssertGreaterThan(unwrapped.proxyPort, 0)
        XCTAssertNotEqual(unwrapped.proxyPort, model.proxyPort)
        XCTAssertEqual(model.pairedDeviceCount, 1)

        // A session was created for the device.
        let session = try XCTUnwrap(model.sessions.first { $0.name.contains("TestPhone") })
        // Device flows are recorded into that device session.
        model.ingestDeviceFlow(flow(host: "a.example"), sessionID: session.id)
        XCTAssertEqual(model.sessionStoreFlowCountForTesting(session.id), 1)

        await model.unpairDevice("dev-1")
        XCTAssertEqual(model.pairedDeviceCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A6 AppModelPairingTests`
Expected: FAIL — `pairDevice`, `unpairDevice`, `ingestDeviceFlow`, `pairedDeviceCount`, `sessionStoreFlowCountForTesting` don't exist.

- [ ] **Step 3: Implement**

In `Sources/HTTrailCore/UI/AppModel.swift`:

Add published state near the other `#if os(macOS)` published vars (around line 90):

```swift
    /// Number of iPhones currently paired and capturing to this Mac.
    @Published public private(set) var pairedDeviceCount = 0
    /// Latest Bonjour publish state, surfaced in the status bar.
    @Published public var bonjourPublishState: BonjourPublishState?
```

Add the registry + advertiser/pairing storage in the `#if os(macOS)` private section (around line 206-211). Replace the `caLANServer`/`caLANPort` lines (no longer used by the new flow) with the pairing storage:

```swift
    #if os(macOS)
    private let systemProxy = SystemProxyController()
    private let bonjourAdvertiser = BonjourAdvertiser()
    private var pairingServer: PairingServer?
    private var pairingPort: Int = 0
    private struct DeviceCapture {
        let ca: CertificateAuthority
        let proxy: ProxyServer
        let port: Int
        let sessionID: UUID
        let bridge: FlowBridge
    }
    private var deviceProxies: [String: DeviceCapture] = [:]
    #endif
```

Add the macOS pairing methods (inside the existing `#if os(macOS)` region that holds `refreshBonjour`, near line 688). Add these methods and rewrite `refreshBonjour`/`setBonjourEnabled`:

```swift
    /// Reconstruct an uploaded CA, start a dedicated proxy for that device on an
    /// ephemeral port, and create a session to record its flows into. The CA is
    /// held in memory only — never written to disk or the Mac keychain.
    public func pairDevice(_ req: PairRequest) async -> PairResponse? {
        // Re-pair: tear down any existing capture for this device first.
        if deviceProxies[req.deviceID] != nil { await unpairDevice(req.deviceID) }
        guard let ca = try? CertificateAuthority.from(certificatePEM: req.caCertPEM, keyPEM: req.caKeyPEM) else {
            return nil
        }
        let name = "\(req.deviceName) \(CaptureSession.defaultName(for: Date()))"
        let session = sessionStore.createSession(name: name, startedAt: Date())
        sessions = sessionStore.allSessions()

        let bridge = FlowBridge()
        let sid = session.id
        bridge.onFlow = { [weak self] flow in
            MainActor.assumeIsolated { self?.ingestDeviceFlow(flow, sessionID: sid) }
        }
        let proxy = ProxyServer(port: 0, certificateAuthority: ca, sink: bridge, engine: engine)
        proxy.bindHost = "0.0.0.0"
        do {
            try await proxy.start()
        } catch {
            statusMessage = "Failed to start device proxy: \(error.localizedDescription)"
            return nil
        }
        let port = proxy.boundPort
        deviceProxies[req.deviceID] = DeviceCapture(ca: ca, proxy: proxy, port: port, sessionID: sid, bridge: bridge)
        pairedDeviceCount = deviceProxies.count
        statusMessage = "Capturing \(req.deviceName) → \(name)"
        return PairResponse(proxyPort: port, sessionName: name)
    }

    public func unpairDevice(_ deviceID: String) async {
        guard let device = deviceProxies.removeValue(forKey: deviceID) else { return }
        try? await device.proxy.stop()
        pairedDeviceCount = deviceProxies.count
    }

    private func tearDownAllDeviceProxies() {
        let devices = deviceProxies
        deviceProxies.removeAll()
        pairedDeviceCount = 0
        for (_, d) in devices { Task { try? await d.proxy.stop() } }
    }

    /// Record a flow captured for a paired device into that device's session,
    /// without touching the Mac's own active capture session.
    public func ingestDeviceFlow(_ flow: Flow, sessionID: UUID) {
        var flow = flow
        flow.sessionID = sessionID
        let isNew = sessionStore.flows(in: sessionID).first { $0.id == flow.id } == nil
        sessionStore.record(flow, in: sessionID)
        if isNew, let i = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[i].recordCount += 1
        }
        // Live view if the user is currently looking at this device's session.
        if viewingSessionID == sessionID, viewingSessionID != activeSessionID {
            viewingFlows = sessionStore.flows(in: sessionID).reversed()
        }
    }
```

Rewrite `refreshBonjour` and `setBonjourEnabled` (replace the existing implementations, lines ~688-718):

```swift
    /// Advertise over Bonjour whenever the toggle is on (auto-starting the proxy
    /// if needed) and run the PairingServer so iPhones can upload their CA.
    public func refreshBonjour() {
        if bonjourEnabled && isProxyRunning {
            if pairingServer == nil {
                let server = PairingServer()
                server.onPair = { [weak self] req in await self?.pairDevice(req) }
                server.onUnpair = { [weak self] id in await self?.unpairDevice(id) }
                pairingPort = (try? server.start(bindHost: "0.0.0.0")) ?? 0
                pairingServer = server
            }
            bonjourAdvertiser.onState = { [weak self] state in
                MainActor.assumeIsolated {
                    self?.bonjourPublishState = state
                    if case .failed(let msg) = state { self?.statusMessage = msg }
                }
            }
            bonjourAdvertiser.start(name: bonjourDeviceName, port: proxyPort,
                                    caPort: 0, caFP: "", pairPort: pairingPort)
            statusMessage = "Proxy on \(deviceIP):\(proxyPort) · Discoverable as \"\(bonjourDeviceName)\""
        } else {
            bonjourAdvertiser.stop()
            bonjourPublishState = nil
            tearDownAllDeviceProxies()
            pairingServer?.stop(); pairingServer = nil; pairingPort = 0
        }
    }

    public func setBonjourEnabled(_ enabled: Bool) {
        bonjourEnabled = enabled
        pushRulesToEngine()   // persist into SharedConfig
        if enabled && !isProxyRunning {
            startProxy()       // success path calls refreshBonjour()
        } else {
            refreshBonjour()
        }
    }
```

Delete the now-unused `caFingerprint()` helper if nothing else references it (search first: `swift build 2>&1 | grep caFingerprint`). If `writeArtifacts`/elsewhere still needs it, leave it.

Add the test seam near `ingestForTesting` (around line 340), inside the existing `#if DEBUG`:

```swift
    #if DEBUG
    public func sessionStoreFlowCountForTesting(_ id: UUID) -> Int { sessionStore.flows(in: id).count }
    #endif
```

**Important:** verify `CaptureSession.defaultName(for:)` exists with that signature (summary says it does). If it's named differently, use the actual API or inline a date formatter.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A6 AppModelPairingTests`
Expected: PASS. Then full suite: `swift test 2>&1 | tail -30` → all green (fix any leftover `caLANServer` references — they should all be gone now).

- [ ] **Step 5: Commit** (skip)

---

### Task 7: macOS UI — auto-start toggle + advertising/paired status

**Files:**
- Modify: `Sources/HTTrail/Views/RootView.swift`

**Context:** The toggle already calls `setBonjourEnabled` (now auto-starts). The status bar (line ~154) shows a static "Bonjour" badge. Surface publish state + paired count.

- [ ] **Step 1: Update the status badge**

In `Sources/HTTrail/Views/RootView.swift`, replace the existing Bonjour badge block (around lines 154-156):

```swift
            if model.bonjourEnabled {
                switch model.bonjourPublishState {
                case .published, .none:
                    Label(model.pairedDeviceCount > 0 ? "Bonjour · \(model.pairedDeviceCount) device\(model.pairedDeviceCount == 1 ? "" : "s")" : "Bonjour",
                          systemImage: "wifi")
                        .foregroundStyle(.secondary)
                case .publishing:
                    Label("Bonjour…", systemImage: "wifi")
                        .foregroundStyle(.secondary)
                case .failed:
                    Label("Bonjour failed", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                }
            }
```

- [ ] **Step 2: Update the BonjourInfoSheet copy (optional but recommended)**

In the `BonjourInfoSheet` body text (around line 173), update to reflect the new model:

```swift
            Text("HTTrail will advertise this Mac on your local network so an iPhone running HTTrail can route its traffic here. The iPhone uses its own certificate authority — nothing new is installed on this Mac, and the Mac never trusts the uploaded certificate. Your Mac is only discoverable while the proxy is running. No data leaves your network.")
```

- [ ] **Step 3: Build the macOS app**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Verify the bundle builds**

Run: `./scripts/make_app.sh debug 2>&1 | tail -3`
Expected: `Built: …/dist/HTTrail.app`

- [ ] **Step 5: Commit** (skip)

---

### Task 8: iOS AppModel — pair-with-Mac + remove Mac-CA-trust remote flow

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift` (the `#if os(iOS)` regions)
- Modify: `Sources/HTTrailCore/CertificateAuthority.swift` (already exposes `caPrivateKeyPEM` from Task 1)

**Context (iOS-only code — not compiled by `swift test`; verified by the iOS build in this task's Step 3).** Current remote flow: `applyCaptureTargetForStart()` sets `pendingRemoteEndpoint` from `captureTarget.remoteHostPort`; `currentConfig()` copies it into `remoteProxyHost/Port`. Mac-CA trust helpers (`isMacCATrusted`, `markMacCATrusted`, `macCAInstallURL`) and the `caFP`-based marking in `runCaptureHealthCheck` are now obsolete.

- [ ] **Step 1: Add the pairing call**

In the `#if os(iOS)` region of `AppModel.swift`, add:

```swift
    /// Upload this iPhone's CA to a discovered Mac and return the dedicated
    /// proxy port the Mac stood up for us (nil on failure).
    public func pairWithMac(_ proxy: DiscoveredProxy) async -> Int? {
        guard proxy.pairPort > 0 else { return nil }
        let deviceName = UIDevice.current.name
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let req = PairRequest(deviceName: deviceName, deviceID: deviceID,
                              caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM)
        guard let body = try? JSONEncoder().encode(req),
              let url = URL(string: "http://\(proxy.host):\(proxy.pairPort)/pair") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PairResponse.self, from: data) else { return nil }
        return decoded.proxyPort
    }
```

Add `import UIKit` at the top of the file under the existing `#if os(iOS)` import if not present. Check the top of the file: if there's no `#if canImport(UIKit) import UIKit #endif`, add:

```swift
#if canImport(UIKit)
import UIKit
#endif
```

- [ ] **Step 2: Rewire start + remove obsolete trust helpers**

Make `applyCaptureTargetForStart` async and pair when the target is `.remote`. Replace it (around line 598):

```swift
    /// Resolve the endpoint to route to for the chosen target. For a discovered
    /// Mac this pairs first (uploading our CA) and uses the returned proxy port.
    public func applyCaptureTargetForStart() async -> (host: String, port: Int)? {
        switch captureTarget {
        case .thisDevice:
            pendingRemoteEndpoint = nil
            return nil
        case .manual(let host, let port):
            pendingRemoteEndpoint = (host, port)
            return (host, port)
        case .remote(let proxy):
            guard let port = await pairWithMac(proxy) else {
                statusMessage = "Couldn't pair with \(proxy.name)"
                pendingRemoteEndpoint = nil
                return nil
            }
            let endpoint = (proxy.host, port)
            pendingRemoteEndpoint = endpoint
            return endpoint
        }
    }
```

Delete the obsolete helpers `isMacCATrusted`, `markMacCATrusted`, `macCAInstallURL`, and the `caMarkerKey` property. In `runCaptureHealthCheck` remove the `markMacCATrusted` branch — keep just the reachability + tlsProbe:

```swift
    public func runCaptureHealthCheck(host: String, port: Int) {
        captureHealth = .unknown
        Task {
            guard await CaptureHealthCheck.reachable(host: host, port: port, timeout: 3) else {
                self.captureHealth = .unreachable
                return
            }
            self.captureHealth = await CaptureHealthCheck.tlsProbe(timeout: 6)
        }
    }
```

**Note:** callers of `applyCaptureTargetForStart()` are now `await`-ed; update them in Task 10 (CaptureView). If any caller is in `AppModel` itself, wrap in a `Task { ... }`.

- [ ] **Step 3: Build for iOS simulator**

Run:
```bash
cd iosapp && xcodegen generate && \
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors (e.g. remaining references to deleted helpers).

- [ ] **Step 4: Commit** (skip)

---

### Task 9: iOS CaptureView — pair-then-start, drop CA auto-offer

**Files:**
- Modify: `iosapp/Sources/CaptureView.swift`

**Context:** Today selecting a `.remote` target may call `openURL(macCAInstallURL)` and a CA-trust banner. Remove that; just pair + start. `applyCaptureTargetForStart()` is now async.

- [ ] **Step 1: Update the start path**

In `iosapp/Sources/CaptureView.swift`, find where capture starts for a chosen target (the `selectTarget`/start handler). Ensure it awaits the async resolve and starts the VPN with the returned endpoint. Replace the relevant handler with:

```swift
    private func startCapture() {
        Task {
            _ = await model.applyCaptureTargetForStart()
            model.startCaptureSessionVPN()   // existing VPN-begin entry point
        }
    }
```

Use the **actual** existing VPN-start method name in this file (the summary notes a "VPN begin/endCaptureSession wiring"). Search: `grep -n "applyCaptureTargetForStart\|startTunnel\|beginCapture\|startVPN\|NETunnel" iosapp/Sources/CaptureView.swift` and call the same method that was previously invoked after `applyCaptureTargetForStart()`.

- [ ] **Step 2: Remove the Mac-CA auto-offer UI**

Delete any code referencing `macCAInstallURL`, `isMacCATrusted`, or a "trust the Mac's CA" banner/openURL for the remote target. Keep the health banner (reachable / tlsUntrusted / healthy) — `tlsUntrusted` now means "your iPhone's own CA isn't trusted on this device" (instruct the user to install the HTTrail profile), which is still a valid state.

- [ ] **Step 3: Update the health banner copy for tlsUntrusted**

Where the banner renders `.tlsUntrusted`, set the message to:

```swift
"HTTPS isn't validating. Make sure this iPhone has the HTTrail certificate installed and trusted (Settings ▸ General ▸ VPN & Device Management, and Certificate Trust Settings)."
```

- [ ] **Step 4: Build for iOS simulator**

Run:
```bash
cd iosapp && xcodegen generate && \
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** (skip)

---

### Task 10: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Full test suite**

Run: `swift test 2>&1 | tail -15`
Expected: all tests pass (previous 44 + the new cases from Tasks 1–6). Confirm `0 failures`.

- [ ] **Step 2: macOS app bundle**

Run: `./scripts/make_app.sh debug 2>&1 | tail -3`
Expected: `Built: …/dist/HTTrail.app`.

- [ ] **Step 3: iOS device build (signed)**

Run:
```bash
cd iosapp && xcodegen generate && \
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **` (team `D62Y8JVXB9`).

- [ ] **Step 4: Manual smoke (report to user, do not block on it)**

Document for the user: on Mac, start proxy + enable "Discoverable over Bonjour"; confirm `dns-sd -B _httrail._tcp local.` now lists the Mac and the status bar shows "Bonjour". On iPhone (with its own HTTrail CA already trusted), pick the Mac on the Capture tab → Start → confirm a `"<device> Capture …"` session appears on the Mac and fills with flows.

- [ ] **Step 5: Commit** (skip)

---

## Self-Review Notes

- **Spec coverage:** G1 → Tasks 4, 6 (refreshBonjour/setBonjourEnabled auto-start + publish state), 7 (UI). G2 → Tasks 1 (reconstruct CA), 2 (ephemeral port), 5 (PairingServer), 6 (per-device proxy + session), 8–9 (iOS pair-then-start, drop Mac-CA trust). Security handling (in-memory CA, no keychain) → Task 6.
- **Type consistency:** `pairPort` threaded through `BonjourTXT`/`DiscoveredProxy`/advertiser (Task 3) before consumers (6/8). `PairRequest`/`PairResponse` defined in Task 5, used in 6/8. `boundPort` (Task 2) used in 6. `caPrivateKeyPEM` (Task 1) used in 6 (test) and 8.
- **Ordering:** core/library tasks (1–6) precede UI (7) and iOS (8–10) so each builds on a green suite.
- **iOS caveat:** Tasks 8–9 are `#if os(iOS)` and not covered by `swift test`; they're verified by the iOS build. This is inherent to the codebase, not a plan gap.
```
