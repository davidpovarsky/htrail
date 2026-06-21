# Bonjour Discovery + Capture-to-Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an iPhone capture its traffic to a running Mac HTTrail instance discovered over the LAN via Bonjour (as an alternative to on-device capture), with auto Mac-CA install, a health-check + manual fallback, and explicit Local Network disclosure for App Store review.

**Architecture:** A shared `BonjourService` (Foundation `NetService`/`NetServiceBrowser`, service `_httrail._tcp`) lets the Mac advertise its running proxy and the iOS app discover it. The iOS Capture-tab **Start** drives the existing PacketTunnel VPN with a chosen **capture target** (This iPhone / a discovered Mac / Manual host:port); for a remote target the extension forwards `NEProxySettings` to that host instead of running a local proxy (new `SharedConfig.remoteProxyHost/Port`). The Mac serves its CA-only `.mobileconfig` over the LAN (generalized `ProfileHTTPServer`) so the iPhone can trust the Mac's CA; a `CaptureHealthCheck` plus manual instructions handle failures. Info.plist purpose strings + an in-app disclosure satisfy Local Network privacy review.

**Tech Stack:** Swift 5 (core language mode), SwiftUI, Foundation `NetService`, Network framework (`NWListener`/`NWConnection`), SwiftNIO (existing), swift-crypto (`SHA256`), NetworkExtension (iOS), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-20-bonjour-capture-to-mac-design.md`

> **Git note:** This working copy is not a git repository. Skip the `git commit` steps (treat them as review checkpoints) — do not run git commands. Tasks are sequential. Core tests run with `swift test`; the full suite includes a live MITM test needing network.
>
> **Filter note:** `swift test --filter <Name>` may report "0 tests" in some shells; if so, run the full `swift test` and read the relevant suite's lines. Both are acceptable verification.

---

## File Structure

**Create (core):**
- `Sources/HTTrailCore/Discovery/BonjourService.swift` — `DiscoveredProxy`, TXT encode/decode, `BonjourAdvertiser`, `BonjourBrowser`.
- `Sources/HTTrailCore/Discovery/CaptureTarget.swift` — `CaptureTarget` enum.
- `Sources/HTTrailCore/Discovery/CaptureHealthCheck.swift` — TCP reachability check + `CaptureHealth`.

**Create (tests):**
- `Tests/HTTrailCoreTests/BonjourServiceTests.swift`
- `Tests/HTTrailCoreTests/ProfileServerAndConfigTests.swift`
- `Tests/HTTrailCoreTests/CaptureHealthCheckTests.swift`

**Modify (core):**
- `Sources/HTTrailCore/SharedConfigStore.swift` — `SharedConfig` gains `bonjourEnabled`, `remoteProxyHost`, `remoteProxyPort`.
- `Sources/HTTrailCore/ProfileHTTPServer.swift` — remove iOS gate; add `bindHost` param.
- `Sources/HTTrailCore/UI/AppModel.swift` — macOS Bonjour advertiser + LAN CA server; iOS capture target/browser/start wiring; disclosure + CA-marker state.

**Modify (apps):**
- `iosapp/PacketTunnel/PacketTunnelProvider.swift` — remote-target branch.
- `Resources/Info.plist` (macOS) + `iosapp/project.yml` (iOS) — Local Network keys.
- `Sources/HTTrail/Views/RootView.swift` — macOS Bonjour toggle + disclosure + status.
- `iosapp/Sources/CaptureView.swift` — capture-target picker, Start→VPN, routing info, health banner.
- `iosapp/Sources/SetupView.swift` — disclosure sheet plumbing (shared state) if needed.

---

## Task 1: SharedConfig new fields (TDD)

**Files:**
- Modify: `Sources/HTTrailCore/SharedConfigStore.swift:9-17`
- Test: `Tests/HTTrailCoreTests/ProfileServerAndConfigTests.swift` (new file; more added in Task 2)

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/ProfileServerAndConfigTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class SharedConfigFieldsTests: XCTestCase {
    func testRoundTripsNewBonjourAndRemoteFields() throws {
        var config = SharedConfig()
        config.bonjourEnabled = true
        config.remoteProxyHost = "192.168.1.50"
        config.remoteProxyPort = 9091
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: data)
        XCTAssertTrue(decoded.bonjourEnabled)
        XCTAssertEqual(decoded.remoteProxyHost, "192.168.1.50")
        XCTAssertEqual(decoded.remoteProxyPort, 9091)
    }

    func testLegacyConfigDecodesWithDefaults() throws {
        // A config written before these fields existed must still decode.
        let legacy = #"{"rules":[],"sslAllowlist":[],"proxyPort":9090,"pinningEnabled":true,"forcedDecryptHosts":[]}"#
        let decoded = try JSONDecoder().decode(SharedConfig.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.bonjourEnabled)
        XCTAssertNil(decoded.remoteProxyHost)
        XCTAssertNil(decoded.remoteProxyPort)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A2 SharedConfigFieldsTests` (or `swift test --filter SharedConfigFieldsTests`)
Expected: FAIL — `value of type 'SharedConfig' has no member 'bonjourEnabled'`.

- [ ] **Step 3: Add the fields**

In `Sources/HTTrailCore/SharedConfigStore.swift`, the `SharedConfig` struct currently is:

```swift
public struct SharedConfig: Codable, Sendable, Equatable {
    public var rules: [InterceptRule] = []
    public var sslAllowlist: [String] = []
    public var proxyPort: Int = 9090
    public var pinningEnabled: Bool = true
    /// Hosts the user forced back into decryption despite pinning detection.
    public var forcedDecryptHosts: [String] = []
    public init() {}
}
```

Add three fields (defaults keep `Codable` synthesis tolerant of missing keys when combined with the explicit decoder note below):

```swift
public struct SharedConfig: Codable, Sendable, Equatable {
    public var rules: [InterceptRule] = []
    public var sslAllowlist: [String] = []
    public var proxyPort: Int = 9090
    public var pinningEnabled: Bool = true
    /// Hosts the user forced back into decryption despite pinning detection.
    public var forcedDecryptHosts: [String] = []
    /// macOS: advertise this running proxy over Bonjour for iOS discovery.
    public var bonjourEnabled: Bool = false
    /// iOS extension: when non-nil, forward to this remote proxy (a Mac) instead
    /// of running a local on-device proxy.
    public var remoteProxyHost: String?
    public var remoteProxyPort: Int?
    public init() {}
}
```

> Note: Swift's synthesized `Codable` for a struct does NOT use property default values for missing keys — it throws. To make `testLegacyConfigDecodesWithDefaults` pass, add an explicit `init(from:)` that decodes each key with `decodeIfPresent` and falls back to the default. Add this inside the struct:

```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([InterceptRule].self, forKey: .rules) ?? []
        sslAllowlist = try c.decodeIfPresent([String].self, forKey: .sslAllowlist) ?? []
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 9090
        pinningEnabled = try c.decodeIfPresent(Bool.self, forKey: .pinningEnabled) ?? true
        forcedDecryptHosts = try c.decodeIfPresent([String].self, forKey: .forcedDecryptHosts) ?? []
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? false
        remoteProxyHost = try c.decodeIfPresent(String.self, forKey: .remoteProxyHost)
        remoteProxyPort = try c.decodeIfPresent(Int.self, forKey: .remoteProxyPort)
    }
```

(The synthesized `CodingKeys` and `encode(to:)` remain; keep the existing `public init() {}`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A2 SharedConfigFieldsTests`
Expected: both methods PASS.

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 2: Generalize `ProfileHTTPServer` for LAN binding (TDD)

**Files:**
- Modify: `Sources/HTTrailCore/ProfileHTTPServer.swift`
- Test: `Tests/HTTrailCoreTests/ProfileServerAndConfigTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `Tests/HTTrailCoreTests/ProfileServerAndConfigTests.swift`:

```swift
import NIOCore

final class ProfileHTTPServerTests: XCTestCase {
    func testServesPayloadWithProfileMIMEOnGivenHost() throws {
        let payload = Data("hello-profile".utf8)
        let server = ProfileHTTPServer(payload: payload)
        let port = try server.start(bindHost: "127.0.0.1")
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/HTTrail-CA.mobileconfig")!
        let exp = expectation(description: "fetch")
        var gotData: Data?
        var gotMIME: String?
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            gotData = data
            gotMIME = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(gotData, payload)
        XCTAssertEqual(gotMIME, "application/x-apple-aspen-config")
    }

    func testCAOnlyProfileHasRootPayloadNoProxyPayload() throws {
        let ca = try CertificateAuthority.create()
        let data = try ProfileGenerator().makeProfile(
            caCertificateDER: ca.caCertificateDER, proxyHost: "10.0.0.1", proxyPort: 9090,
            includeProxyPayload: false)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let payloads = try XCTUnwrap((plist?["PayloadContent"]) as? [[String: Any]])
        XCTAssertTrue(payloads.contains { ($0["PayloadType"] as? String) == "com.apple.security.root" })
        XCTAssertFalse(payloads.contains { ($0["PayloadType"] as? String) == "com.apple.proxy.http.global" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A2 ProfileHTTPServerTests`
Expected: FAIL to compile — `ProfileHTTPServer` is unavailable on macOS (file is `#if os(iOS)`) and `start` takes no `bindHost`.

- [ ] **Step 3: Generalize the server**

In `Sources/HTTrailCore/ProfileHTTPServer.swift`: remove the opening `#if os(iOS)` (line 1) and the trailing `#endif` (last line). Change the `start()` method to accept a bind host:

Replace:

```swift
    /// Binds 127.0.0.1 on an OS-assigned port and returns it.
    @discardableResult
    public func start() throws -> Int {
        let payload = self.payload
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProfileResponder(payload: payload))
                }
            }
        let ch = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = ch
        return ch.localAddress?.port ?? 0
    }
```

with:

```swift
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
```

The existing iOS caller `AppModel.captureProfileInstallURL()` calls `server.start()` with no args — still valid via the default.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A2 ProfileHTTPServerTests`
Expected: both methods PASS.

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 3: Bonjour service (TDD)

**Files:**
- Create: `Sources/HTTrailCore/Discovery/BonjourService.swift`
- Test: `Tests/HTTrailCoreTests/BonjourServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/BonjourServiceTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class BonjourServiceTests: XCTestCase {
    func testTXTEncodeDecodeRoundTrip() {
        let txt = BonjourTXT.encode(name: "Anu's Mac", port: 9090, caPort: 8443, caFP: "ab12cd34")
        let decoded = BonjourTXT.decode(txt)
        XCTAssertEqual(decoded.name, "Anu's Mac")
        XCTAssertEqual(decoded.port, 9090)
        XCTAssertEqual(decoded.caPort, 8443)
        XCTAssertEqual(decoded.caFP, "ab12cd34")
    }

    func testTXTDecodeMissingFieldsIsNil() {
        let decoded = BonjourTXT.decode([:])
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.port)
        XCTAssertNil(decoded.caPort)
        XCTAssertNil(decoded.caFP)
    }

    // Best-effort end-to-end: advertise on loopback and discover it. Requires
    // local Bonjour/mDNS to be available; if the environment forbids it, this
    // may time out — report it rather than treating as a hard failure.
    func testAdvertiseThenBrowseDiscoversService() {
        let advertiser = BonjourAdvertiser()
        advertiser.start(name: "TestMac", port: 9099, caPort: 8443, caFP: "deadbeef")
        defer { advertiser.stop() }

        let browser = BonjourBrowser()
        let exp = expectation(description: "discovered")
        let cancellable = browser.$found.sink { list in
            if list.contains(where: { $0.name == "TestMac" && $0.port == 9099 }) { exp.fulfill() }
        }
        browser.start()
        defer { browser.stop(); cancellable.cancel() }
        wait(for: [exp], timeout: 10)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A2 BonjourServiceTests`
Expected: FAIL — `cannot find 'BonjourTXT' / 'BonjourAdvertiser' / 'BonjourBrowser' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HTTrailCore/Discovery/BonjourService.swift`:

```swift
import Foundation
import Combine

/// A Mac running HTTrail, discovered on the LAN via Bonjour.
public struct DiscoveredProxy: Identifiable, Hashable, Sendable {
    public var id: String       // Bonjour service name (unique on the LAN)
    public var name: String     // human label (device name)
    public var host: String     // resolved host / IPv4
    public var port: Int        // proxy port
    public var caPort: Int      // LAN CA-profile HTTP port (0 if absent)
    public var caFP: String     // short CA fingerprint ("" if absent)

    public init(id: String, name: String, host: String, port: Int, caPort: Int, caFP: String) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.caPort = caPort; self.caFP = caFP
    }
}

/// The Bonjour service type HTTrail advertises/browses.
public enum BonjourConfig {
    public static let serviceType = "_httrail._tcp."
    public static let domain = "local."
}

/// TXT-record (de)serialisation. Kept pure for deterministic unit testing.
public enum BonjourTXT {
    public static func encode(name: String, port: Int, caPort: Int, caFP: String) -> [String: Data] {
        [
            "name": Data(name.utf8),
            "port": Data(String(port).utf8),
            "caPort": Data(String(caPort).utf8),
            "caFP": Data(caFP.utf8),
        ]
    }

    public static func decode(_ txt: [String: Data]) -> (name: String?, port: Int?, caPort: Int?, caFP: String?) {
        func str(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        return (str("name"), str("port").flatMap(Int.init), str("caPort").flatMap(Int.init), str("caFP"))
    }
}

/// Advertises the running proxy (used by the Mac).
public final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    public func start(name: String, port: Int, caPort: Int, caFP: String) {
        stop()
        let svc = NetService(domain: BonjourConfig.domain, type: BonjourConfig.serviceType,
                             name: name, port: Int32(port))
        svc.delegate = self
        svc.setTXTRecord(NetService.data(fromTXTRecord: BonjourTXT.encode(
            name: name, port: port, caPort: caPort, caFP: caFP)))
        svc.publish()
        service = svc
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}

/// Browses for HTTrail Macs on the LAN (used by iOS). `found` is published for
/// SwiftUI; callbacks are delivered on the main runloop.
public final class BonjourBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published public private(set) var found: [DiscoveredProxy] = []
    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        found = []
        browser.searchForServices(ofType: BonjourConfig.serviceType, inDomain: BonjourConfig.domain)
    }

    public func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    // MARK: NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found.removeAll { $0.id == service.name }
    }

    // MARK: NetServiceDelegate

    public func netServiceDidResolveAddress(_ service: NetService) {
        guard let host = service.hostName else { return }
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        let fields = BonjourTXT.decode(txt)
        let proxy = DiscoveredProxy(
            id: service.name,
            name: fields.name ?? service.name,
            host: host.hasSuffix(".") ? String(host.dropLast()) : host,
            port: fields.port ?? (service.port > 0 ? service.port : 9090),
            caPort: fields.caPort ?? 0,
            caFP: fields.caFP ?? "")
        if let idx = found.firstIndex(where: { $0.id == proxy.id }) { found[idx] = proxy }
        else { found.append(proxy) }
        resolving.remove(service)
    }

    public func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(service)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A2 BonjourServiceTests`
Expected: `testTXTEncodeDecodeRoundTrip` and `testTXTDecodeMissingFieldsIsNil` PASS. `testAdvertiseThenBrowseDiscoversService` should pass if local mDNS works; if it times out due to a sandboxed/no-multicast environment, note it explicitly in your report (it is best-effort, not a logic failure).

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 4: CaptureTarget + CaptureHealthCheck (TDD)

**Files:**
- Create: `Sources/HTTrailCore/Discovery/CaptureTarget.swift`
- Create: `Sources/HTTrailCore/Discovery/CaptureHealthCheck.swift`
- Test: `Tests/HTTrailCoreTests/CaptureHealthCheckTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/CaptureHealthCheckTests.swift`:

```swift
import XCTest
import Network
@testable import HTTrailCore

final class CaptureHealthCheckTests: XCTestCase {
    func testReachableTrueAgainstLiveListenerFalseAgainstClosedPort() async throws {
        // Stand up a real TCP listener on an ephemeral port.
        let listener = try NWListener(using: .tcp)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = Int(listener.port!.rawValue)
        defer { listener.cancel() }

        let up = await CaptureHealthCheck.reachable(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertTrue(up, "live listener should be reachable")

        // Port 1 on loopback is virtually always closed.
        let down = await CaptureHealthCheck.reachable(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertFalse(down, "closed port should be unreachable")
    }

    func testCaptureTargetRemoteHostPort() {
        XCTAssertNil(CaptureTarget.thisDevice.remoteHostPort?.host)
        let p = DiscoveredProxy(id: "x", name: "Mac", host: "10.0.0.5", port: 9090, caPort: 0, caFP: "")
        XCTAssertEqual(CaptureTarget.remote(p).remoteHostPort?.host, "10.0.0.5")
        XCTAssertEqual(CaptureTarget.manual(host: "1.2.3.4", port: 8888).remoteHostPort?.port, 8888)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test 2>&1 | grep -A2 CaptureHealthCheckTests`
Expected: FAIL — `cannot find 'CaptureHealthCheck' / 'CaptureTarget' in scope`.

- [ ] **Step 3: Write the implementations**

Create `Sources/HTTrailCore/Discovery/CaptureTarget.swift`:

```swift
import Foundation

/// Where iOS capture is decrypted/recorded.
public enum CaptureTarget: Hashable, Sendable {
    case thisDevice
    case remote(DiscoveredProxy)
    case manual(host: String, port: Int)

    /// The remote proxy endpoint, or nil for on-device capture.
    public var remoteHostPort: (host: String, port: Int)? {
        switch self {
        case .thisDevice: return nil
        case .remote(let p): return (p.host, p.port)
        case .manual(let host, let port): return (host, port)
        }
    }

    public var label: String {
        switch self {
        case .thisDevice: return "This iPhone"
        case .remote(let p): return p.name
        case .manual(let host, let port): return "Manual \(host):\(port)"
        }
    }
}
```

Create `Sources/HTTrailCore/Discovery/CaptureHealthCheck.swift`:

```swift
import Foundation
import Network

/// Result of probing a capture path.
public enum CaptureHealth: Equatable, Sendable {
    case healthy
    case unreachable    // can't open a TCP connection to the proxy
    case tlsUntrusted   // reachable, but HTTPS through it fails to validate (Mac CA not trusted)
    case unknown
}

/// Lightweight reachability/health probing for a remote proxy target.
public enum CaptureHealthCheck {
    /// True if a TCP connection to `host:port` becomes ready within `timeout`.
    public static func reachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        return await withCheckedContinuation { continuation in
            let resumed = NSLock()
            var done = false
            func finish(_ value: Bool) {
                resumed.lock(); defer { resumed.unlock() }
                if done { return }
                done = true
                conn.cancel()
                continuation.resume(returning: value)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -A2 CaptureHealthCheckTests`
Expected: both methods PASS.

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 5: PacketTunnel remote-target branch

**Files:**
- Modify: `iosapp/PacketTunnel/PacketTunnelProvider.swift:30-60` (the `startTunnel` body)

> No unit test (extension code can't be unit-tested); verified by the iOS build (Task 11) + on-device. Keep the change minimal and surgical.

- [ ] **Step 1: Branch on the remote target in `startTunnel`**

In `iosapp/PacketTunnel/PacketTunnelProvider.swift`, the current `startTunnel` loads config, then always starts a local `ProxyServer`. Replace the section from `let config = configStore.load() ?? SharedConfig()` through the `Task { ... applyNetworkSettings ... }` block with a branch. The new body:

```swift
        let config = configStore.load() ?? SharedConfig()
        let port = config.proxyPort

        // Remote target: forward to a Mac's proxy on the LAN — do NOT run a local
        // proxy; the Mac decrypts and records. Otherwise capture on-device.
        if let remoteHost = config.remoteProxyHost {
            let remotePort = config.remoteProxyPort ?? port
            tunnelLog.log("startTunnel: remote target \(remoteHost):\(remotePort)")
            applyNetworkSettings(proxyHost: remoteHost, port: remotePort, completionHandler: completionHandler)
            return
        }

        engine.apply(config)
        tunnelLog.log("startTunnel: on-device port=\(port) rules=\(config.rules.filter { $0.enabled }.count) allowlist=\(config.sslAllowlist.count)")

        guard let ca = try? CertificateAuthority.loadOrCreate(in: AppPaths.certificatesDirectory) else {
            completionHandler(NSError(domain: "HTTrail", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not load HTTrail CA from the App Group."]))
            return
        }
        let sink: FlowSink = SharedFlowStore().map(SharedFlowSink.init(store:)) ?? NullFlowSink()
        let server = ProxyServer(port: port, certificateAuthority: ca, sink: sink, engine: engine)
        server.bindHost = "127.0.0.1"
        self.proxy = server
        startConfigSync()

        Task {
            do {
                try await server.start()
            } catch {
                completionHandler(error)
                return
            }
            self.applyNetworkSettings(proxyHost: "127.0.0.1", port: port, completionHandler: completionHandler)
        }
```

- [ ] **Step 2: Make `applyNetworkSettings` take a proxy host**

The current `applyNetworkSettings(port:completionHandler:)` hardcodes the proxy server address to `127.0.0.1`. Change its signature and the `NEProxyServer` line. Replace the method header:

```swift
    private func applyNetworkSettings(port: Int, completionHandler: @escaping (Error?) -> Void) {
```

with:

```swift
    private func applyNetworkSettings(proxyHost: String, port: Int, completionHandler: @escaping (Error?) -> Void) {
```

and inside it replace:

```swift
        let server = NEProxyServer(address: "127.0.0.1", port: port)
```

with:

```swift
        let server = NEProxyServer(address: proxyHost, port: port)
```

(The `tunnelRemoteAddress: "127.0.0.1"` for `NEPacketTunnelNetworkSettings` stays — that's the tunnel's own address, not the proxy.)

- [ ] **Step 3: Build the extension via the iOS app build (deferred to Task 11)**

For now confirm the file is syntactically consistent by inspection (no other `applyNetworkSettings(port:` call sites remain — grep `applyNetworkSettings` in the file; both call sites must pass `proxyHost:`).

Run: `grep -n "applyNetworkSettings" iosapp/PacketTunnel/PacketTunnelProvider.swift`
Expected: the definition + two calls, all using `proxyHost:`.

- [ ] **Step 4: Commit** (checkpoint — skip git)

---

## Task 6: Local Network disclosure keys (Info.plist)

**Files:**
- Modify: `Resources/Info.plist` (macOS)
- Modify: `iosapp/project.yml` (iOS app target `info.properties`)

> No automated test; verified by build + the OS prompt appearing with the right text. The purpose string and `NSBonjourServices` are required for `NetService` browsing/advertising and for App Store review.

- [ ] **Step 1: Add keys to the macOS Info.plist**

Open `Resources/Info.plist`. Inside the top-level `<dict>`, add:

```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>HTTrail uses the local network to advertise this Mac so your iPhone running HTTrail can discover it and capture traffic here.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_httrail._tcp</string>
	</array>
```

- [ ] **Step 2: Add keys to the iOS app target in project.yml**

Open `iosapp/project.yml`, find the iOS **app** target (`HTTrailiOS`) `info:` block (the one with `properties:` — per the xcodegen gotcha, keys MUST go under `properties:`). Add these entries under its `properties:`:

```yaml
        NSLocalNetworkUsageDescription: "HTTrail uses the local network to discover a Mac running HTTrail so this iPhone's traffic can be captured there."
        NSBonjourServices:
          - _httrail._tcp
```

(Indent to match the sibling keys already under `properties:`. Do NOT add to the PacketTunnel target.)

- [ ] **Step 3: Regenerate the iOS project and confirm the keys land**

Run:
```bash
cd /Users/mac/Projects/htrail/iosapp && xcodegen generate >/dev/null 2>&1 && \
plutil -p HTTrailiOS.xcodeproj/../$(ls) >/dev/null 2>&1; \
/usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$(find . -name 'Info.plist' -path '*HTTrailiOS*' | head -1)" 2>/dev/null || echo "verify NSBonjourServices in generated Info.plist"
```
Simpler check: after `xcodegen generate`, the generated app Info.plist (xcodegen writes it under `iosapp/`) must contain `NSBonjourServices`. Verify by building in Task 11 (the build embeds it). If unsure, open the generated `.xcodeproj` and confirm the app target's Info.plist keys.

- [ ] **Step 4: Commit** (checkpoint — skip git)

---

## Task 7: macOS AppModel — Bonjour advertiser + LAN CA server

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift`

> Advertising/serving over the LAN can't be unit-tested deterministically here; the `BonjourAdvertiser`/`ProfileHTTPServer` units are already tested (Tasks 2-3). This task wires them into the model lifecycle. Verify with `swift build` + the macOS smoke test.

- [ ] **Step 1: Add macOS Bonjour state + helpers**

In `Sources/HTTrailCore/UI/AppModel.swift`, add a published flag near the other capture state (after `@Published public var resourceTypeFilter ...` block from the sessions feature — anywhere in the published block is fine):

```swift
    /// macOS: advertise the running proxy over Bonjour for iOS discovery.
    @Published public var bonjourEnabled = false
    /// macOS: human label shown to discovering devices.
    @Published public var bonjourDeviceName = ""
```

Add private members near `private let configStore = SharedConfigStore()`:

```swift
    #if os(macOS)
    private let bonjourAdvertiser = BonjourAdvertiser()
    private var caLANServer: ProfileHTTPServer?
    private var caLANPort: Int = 0
    #endif
```

- [ ] **Step 2: Load the persisted flag + device name in `init`**

In `init`, where the saved `SharedConfig` is restored (`if let saved = configStore.load() { ... }`), add inside that block:

```swift
            bonjourEnabled = saved.bonjourEnabled
```

And after that block (before `pushRulesToEngine()`), set the default device name:

```swift
        #if os(macOS)
        bonjourDeviceName = Host.current().localizedName ?? "Mac"
        #endif
```

- [ ] **Step 3: Add the advertise lifecycle helper (macOS)**

Add these methods to `AppModel` (inside the existing `#if os(macOS)` region near `toggleSystemProxy`, or in their own `#if os(macOS)` block):

```swift
    #if os(macOS)
    /// Start/stop Bonjour advertising + the LAN CA server to match
    /// (bonjourEnabled && isProxyRunning). Idempotent — safe to call on any
    /// state change (toggle, proxy start/stop).
    public func refreshBonjour() {
        let shouldAdvertise = bonjourEnabled && isProxyRunning
        if shouldAdvertise {
            // Serve the CA-only profile on the LAN so iOS can trust this Mac's CA.
            if caLANServer == nil {
                let host = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
                if let profile = try? ProfileGenerator().makeProfile(
                    caCertificateDER: ca.caCertificateDER, proxyHost: host, proxyPort: proxyPort,
                    includeProxyPayload: false) {
                    let server = ProfileHTTPServer(payload: profile)
                    caLANPort = (try? server.start(bindHost: "0.0.0.0")) ?? 0
                    caLANServer = server
                }
            }
            bonjourAdvertiser.start(name: bonjourDeviceName, port: proxyPort,
                                    caPort: caLANPort, caFP: caFingerprint())
            statusMessage = "Discoverable over Bonjour as “\(bonjourDeviceName)”"
        } else {
            bonjourAdvertiser.stop()
            caLANServer?.stop(); caLANServer = nil; caLANPort = 0
        }
    }

    public func setBonjourEnabled(_ enabled: Bool) {
        bonjourEnabled = enabled
        pushRulesToEngine()   // persist into SharedConfig
        refreshBonjour()
    }

    /// Short SHA-256 prefix of the root CA DER, advertised so iOS can key its
    /// "Mac CA installed" marker to the actual CA.
    private func caFingerprint() -> String {
        let digest = SHA256.hash(data: ca.caCertificateDER)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
    #endif
```

Add `import Crypto` at the top of `AppModel.swift` if not already imported (needed for `SHA256`). Check the existing imports; `swift-crypto` is a package dependency, imported as `import Crypto`.

- [ ] **Step 4: Persist `bonjourEnabled` in `currentConfig()` and call `refreshBonjour` on proxy start/stop**

In `currentConfig()` (builds the `SharedConfig`), add:

```swift
        config.bonjourEnabled = bonjourEnabled
```

In `startProxy(...)`, inside the `Task` after `self.isProxyRunning = true` (the success path), add:

```swift
                #if os(macOS)
                self.refreshBonjour()
                #endif
```

In `stopProxy()`, inside the `Task` after `self.isProxyRunning = false`, add:

```swift
                #if os(macOS)
                self.refreshBonjour()
                #endif
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds clean. If `import Crypto` is wrong for this package, check `Package.swift` for the crypto product name (it's `Crypto` from `swift-crypto`); the CA already uses it, so mirror `CertificateAuthority.swift`'s import.

- [ ] **Step 6: Commit** (checkpoint — skip git)

---

## Task 8: iOS AppModel — capture target, browser, start wiring

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift`

> Wiring task; verified by iOS build (Task 11) + on-device. The pure units (CaptureTarget, health check, Bonjour) are already tested.

- [ ] **Step 1: Add iOS capture-target + disclosure state**

In `AppModel`, add to the published block:

```swift
    #if os(iOS)
    /// iOS: where capture is sent. Drives the VPN's proxy target.
    @Published public var captureTarget: CaptureTarget = .thisDevice
    /// iOS: discovered Macs (populated while browsing).
    @Published public var discoveredProxies: [DiscoveredProxy] = []
    /// iOS: manual fallback fields.
    @Published public var manualProxyHost: String = ""
    @Published public var manualProxyPort: Int = 9090
    /// iOS: health of the current remote capture path.
    @Published public var captureHealth: CaptureHealth = .unknown
    /// One-time Local Network disclosure shown before the OS prompt.
    @Published public var bonjourDisclosureShown = false
    #endif
```

Add private members:

```swift
    #if os(iOS)
    private let bonjourBrowser = BonjourBrowser()
    private var bonjourBrowserCancellable: AnyCancellable?
    /// Per-Mac CA install markers keyed by caFP (persisted lightly in UserDefaults).
    private let caMarkerKey = "httrail.macCATrusted"
    #endif
```

Add `import Combine` at the top if not already present.

- [ ] **Step 2: Browser start/stop + binding (iOS)**

Add methods:

```swift
    #if os(iOS)
    /// Begin browsing for Macs; mirrors the browser's results into `discoveredProxies`.
    public func startBonjourBrowsing() {
        bonjourBrowserCancellable = bonjourBrowser.$found
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.discoveredProxies = $0 }
        bonjourBrowser.start()
    }

    public func stopBonjourBrowsing() {
        bonjourBrowser.stop()
        bonjourBrowserCancellable?.cancel()
        bonjourBrowserCancellable = nil
    }

    /// True if we've recorded a successful trust for this Mac's CA fingerprint.
    public func isMacCATrusted(_ proxy: DiscoveredProxy) -> Bool {
        guard !proxy.caFP.isEmpty else { return false }
        let set = Set(UserDefaults.standard.stringArray(forKey: caMarkerKey) ?? [])
        return set.contains(proxy.caFP)
    }

    private func markMacCATrusted(_ fp: String) {
        guard !fp.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: caMarkerKey) ?? [])
        set.insert(fp)
        UserDefaults.standard.set(Array(set), forKey: caMarkerKey)
    }

    /// The URL that installs a discovered Mac's CA-only profile (or nil).
    public func macCAInstallURL(_ proxy: DiscoveredProxy) -> URL? {
        guard proxy.caPort > 0 else { return nil }
        return URL(string: "http://\(proxy.host):\(proxy.caPort)/HTTrail-CA.mobileconfig")
    }
    #endif
```

- [ ] **Step 3: Write the target into SharedConfig before starting the VPN**

Add a method that the UI calls at Start to publish the chosen target to the extension:

```swift
    #if os(iOS)
    /// Publish the selected capture target into SharedConfig so the PacketTunnel
    /// extension routes correctly, then return the (host, port) for health checks
    /// (nil for on-device). Call immediately before enabling the VPN.
    @discardableResult
    public func applyCaptureTargetForStart() -> (host: String, port: Int)? {
        let endpoint = captureTarget.remoteHostPort
        // Persist into SharedConfig: remoteProxyHost nil ⇒ on-device.
        pushCaptureTargetConfig(endpoint)
        return endpoint
    }

    private func pushCaptureTargetConfig(_ endpoint: (host: String, port: Int)?) {
        // Reuse the single config sync point but include the remote target.
        var config = SharedConfig()
        config.rules = rules
        config.sslAllowlist = sslAllowlist
        config.proxyPort = proxyPort
        config.pinningEnabled = pinningDetectionEnabled
        config.forcedDecryptHosts = forcedDecryptHosts
        config.bonjourEnabled = bonjourEnabled
        config.remoteProxyHost = endpoint?.host
        config.remoteProxyPort = endpoint?.port
        engine.apply(config)
        SharedConfigStore().save(config)
    }

    /// Run the post-start health check for a remote target and update captureHealth.
    public func runCaptureHealthCheck(host: String, port: Int) {
        captureHealth = .unknown
        Task {
            let up = await CaptureHealthCheck.reachable(host: host, port: port, timeout: 3)
            self.captureHealth = up ? .healthy : .unreachable
            if up, case .remote(let proxy) = self.captureTarget, !proxy.caFP.isEmpty {
                // Reachable; assume CA path validated by use. Mark trusted so we
                // don't re-prompt. (A TLS failure later re-surfaces the offer.)
                self.markMacCATrusted(proxy.caFP)
            }
        }
    }
    #endif
```

> Note: `pushCaptureTargetConfig` duplicates the field-copying of the existing `currentConfig()`. To stay DRY, prefer extending `currentConfig()` to read an optional stored `pendingRemoteTarget`. Simpler approach that keeps one source of truth: add `private var pendingRemoteEndpoint: (host: String, port: Int)?` and have `currentConfig()` set `config.remoteProxyHost/Port` from it, then `pushCaptureTargetConfig` just sets `pendingRemoteEndpoint` and calls `pushRulesToEngine()`. Implement it that DRY way:

Replace the `pushCaptureTargetConfig` body above with:

```swift
    private func pushCaptureTargetConfig(_ endpoint: (host: String, port: Int)?) {
        pendingRemoteEndpoint = endpoint
        pushRulesToEngine()
    }
```

Add the stored property (outside `#if`, or in an iOS block):

```swift
    #if os(iOS)
    private var pendingRemoteEndpoint: (host: String, port: Int)?
    #endif
```

And in `currentConfig()` add (guarded so macOS is unaffected):

```swift
        #if os(iOS)
        config.remoteProxyHost = pendingRemoteEndpoint?.host
        config.remoteProxyPort = pendingRemoteEndpoint?.port
        #endif
```

- [ ] **Step 4: Build for macOS (sanity) — iOS bits are `#if os(iOS)`**

Run: `swift build`
Expected: builds clean (the iOS-only additions are excluded on macOS; the shared `currentConfig` change compiles because the `#if os(iOS)` block is empty on macOS).

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 9: macOS UI — Bonjour toggle + disclosure

**Files:**
- Modify: `Sources/HTTrail/Views/RootView.swift` (Setup menu + status bar)

- [ ] **Step 1: Add the Bonjour toggle + disclosure to the Setup menu**

In `Sources/HTTrail/Views/RootView.swift`, in the Setup `Menu` (the `toolbarContent`), add — right after the "Export iOS Profile…" button — a Bonjour section. Also add a `@State private var showBonjourInfo = false` to `RootView`.

Add the state near `@State private var showSettings = false`:

```swift
    @State private var showBonjourInfo = false
```

Add to the Setup menu content (after `Button("Export iOS Profile…") { model.exportiOSProfile() }`):

```swift
                Divider()
                Toggle("Discoverable over Bonjour", isOn: Binding(
                    get: { model.bonjourEnabled },
                    set: { newValue in
                        if newValue && !model.bonjourEnabled { showBonjourInfo = true }
                        else { model.setBonjourEnabled(false) }
                    }))
```

> The toggle defers actually enabling until the user confirms the disclosure (so the rationale is shown before any advertising / OS prompt). Turning it off applies immediately.

- [ ] **Step 2: Add the disclosure sheet**

Add to `RootView.body`'s modifiers (next to the other `.sheet(...)`):

```swift
        .sheet(isPresented: $showBonjourInfo) {
            BonjourInfoSheet(onEnable: { model.setBonjourEnabled(true) })
        }
```

And define the sheet at file scope:

```swift
/// Explains Local Network usage before HTTrail advertises over Bonjour.
struct BonjourInfoSheet: View {
    let onEnable: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Network Access", systemImage: "wifi")
                .font(.headline)
            Text("HTTrail will advertise this Mac on your local network using Bonjour so an iPhone running HTTrail can discover it and route its traffic here for capture. Your Mac is only discoverable while the proxy is running. No data leaves your network.")
                .font(.callout).foregroundStyle(.secondary)
            Text("macOS may ask for permission to access devices on your local network.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Enable") { onEnable(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 420)
    }
}
```

- [ ] **Step 3: Show advertising status in the status bar**

In the `statusBar` of `RootView`, after the `127.0.0.1:\(model.proxyPort)` text, add:

```swift
            if model.bonjourEnabled && model.isProxyRunning {
                Label("Bonjour", systemImage: "wifi")
                    .font(.system(size: 11)).foregroundStyle(Theme.color.green)
            }
```

- [ ] **Step 4: Build + smoke test**

Run: `swift build`
Expected: clean.
Optional: `./scripts/make_app.sh debug && open dist/HTTrail.app` — enabling "Discoverable over Bonjour" shows the disclosure, then (with the proxy started) the status bar shows the Bonjour badge. Interactive verification is the user's to confirm.

- [ ] **Step 5: Commit** (checkpoint — skip git)

---

## Task 10: iOS UI — target picker, Start→VPN, CA offer, health banner, disclosure

**Files:**
- Modify: `iosapp/Sources/CaptureView.swift` (control bar + routing state + banner)

- [ ] **Step 1: Replace the Start control with a target-aware Start**

In `iosapp/Sources/CaptureView.swift`, the `CaptureView` needs the VPN controller and openURL. Add to the struct's properties (near `@EnvironmentObject var model: AppModel`):

```swift
    @EnvironmentObject var vpn: VPNController
    @Environment(\.openURL) private var openURL
    @State private var showLocalNetInfo = false
    @State private var pendingRemote: DiscoveredProxy?
```

Replace the `controlBar`'s Start/Stop section (the `if model.isProxyRunning { ... } else { Menu { ... } }` block from the sessions feature) with a target picker + a Start that enables the VPN:

```swift
            if vpn.isActive {
                Button { stopCapture() } label: {
                    Label("Stop", systemImage: "stop.circle.fill").font(.headline)
                }.tint(Theme.color.red)
            } else {
                Menu {
                    Button { selectTarget(.thisDevice) } label: {
                        Label("This iPhone (on-device)", systemImage: "iphone")
                    }
                    if !model.discoveredProxies.isEmpty {
                        Divider()
                        ForEach(model.discoveredProxies) { proxy in
                            Button { selectTarget(.remote(proxy)) } label: {
                                Label("\(proxy.name) · \(proxy.host):\(proxy.port)", systemImage: "desktopcomputer")
                            }
                        }
                    }
                    Divider()
                    Button { selectTarget(.manual(host: model.manualProxyHost, port: model.manualProxyPort)) } label: {
                        Label("Manual proxy…", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("Start: \(model.captureTarget.label)", systemImage: "play.circle.fill").font(.headline)
                } primaryAction: {
                    startCapture()
                }.tint(Theme.color.green)
            }
```

- [ ] **Step 2: Add the start/stop/select helpers**

Add these methods to `CaptureView`:

```swift
    private func selectTarget(_ target: CaptureTarget) {
        model.captureTarget = target
        if case .remote = target { ensureLocalNetThen { startCapture() } }
    }

    private func ensureLocalNetThen(_ action: @escaping () -> Void) {
        if model.bonjourDisclosureShown { action() }
        else { showLocalNetInfo = true } // sheet's Continue sets the flag + calls back
    }

    private func startCapture() {
        // On-device → new session (records locally). Remote → no local session.
        if case .thisDevice = model.captureTarget {
            model.beginCaptureSession()
            model.applyCaptureTargetForStart()   // clears remote target in SharedConfig
            Task { await vpn.startCapture(port: model.proxyPort) }
        } else {
            // Offer to install the Mac CA if needed (remote only).
            if case .remote(let proxy) = model.captureTarget,
               !model.isMacCATrusted(proxy), let url = model.macCAInstallURL(proxy) {
                openURL(url)   // Safari → install/trust Mac CA, then user returns & Starts again
            }
            let endpoint = model.applyCaptureTargetForStart()
            Task {
                await vpn.startCapture(port: model.proxyPort)
                if let endpoint { model.runCaptureHealthCheck(host: endpoint.host, port: endpoint.port) }
            }
        }
    }

    private func stopCapture() {
        vpn.disable()
        model.endCaptureSession()
        model.captureHealth = .unknown
    }
```

- [ ] **Step 3: Routing info + health banner in the body**

In `CaptureView.body`, add lifecycle for browsing and the disclosure sheet, plus a banner. Add these modifiers to the `NavigationStack` (alongside existing ones):

```swift
            .onAppear { model.startBonjourBrowsing() }
            .onDisappear { model.stopBonjourBrowsing() }
            .sheet(isPresented: $showLocalNetInfo) {
                LocalNetworkInfoSheet(onContinue: {
                    model.bonjourDisclosureShown = true
                    startCapture()
                })
            }
            .safeAreaInset(edge: .top) { captureBanner }
```

Add the banner + sheet:

```swift
    @ViewBuilder
    private var captureBanner: some View {
        if vpn.isActive, case .thisDevice = model.captureTarget {
            EmptyView()
        } else if vpn.isActive {
            VStack(spacing: 4) {
                switch model.captureHealth {
                case .healthy:
                    bannerRow("Routing to \(model.captureTarget.label) — flows are recorded on that Mac.",
                              system: "checkmark.circle.fill", color: Theme.color.green)
                case .unreachable:
                    bannerRow("Can't reach \(model.captureTarget.label). Check the Mac is running & Started, on the same Wi-Fi, and not firewalled. You can also set this device's Wi-Fi proxy manually.",
                              system: "exclamationmark.triangle.fill", color: Theme.color.red)
                case .tlsUntrusted:
                    bannerRow("Connected, but the Mac's CA isn't trusted. Install & trust it, then restart capture.",
                              system: "lock.trianglebadge.exclamationmark", color: Theme.color.red)
                case .unknown:
                    bannerRow("Routing to \(model.captureTarget.label)…", system: "arrow.triangle.2.circlepath", color: Theme.color.textMuted)
                }
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(Theme.color.base.opacity(0.9))
        }
    }

    private func bannerRow(_ text: String, system: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(Theme.color.textDim)
            Spacer()
        }.padding(.horizontal, 8)
    }
```

Add the iOS disclosure sheet at file scope:

```swift
struct LocalNetworkInfoSheet: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Local Network Access", systemImage: "wifi").font(.headline)
            Text("To capture to a Mac, HTTrail discovers Macs running HTTrail on your local network using Bonjour, then routes this device's traffic to the one you pick. iOS will ask for permission to find devices on your local network.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Nothing is sent outside your network; traffic goes only to the Mac you choose.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") { dismiss(); onContinue() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }
}
```

- [ ] **Step 4: Manual proxy entry**

The "Manual proxy…" menu item selects `.manual(host:port)` using the current `model.manualProxyHost/Port`. Add a small editor so the user can set them — a sheet triggered when host is empty. Add `@State private var showManualEntry = false`, change the Manual button to:

```swift
                    Button { showManualEntry = true } label: {
                        Label("Manual proxy…", systemImage: "square.and.pencil")
                    }
```

and add a sheet:

```swift
            .sheet(isPresented: $showManualEntry) {
                ManualProxySheet(host: $model.manualProxyHost, port: $model.manualProxyPort) {
                    selectTarget(.manual(host: model.manualProxyHost, port: model.manualProxyPort))
                }
            }
```

Define:

```swift
struct ManualProxySheet: View {
    @Binding var host: String
    @Binding var port: Int
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac proxy") {
                    TextField("Host (e.g. 192.168.1.50)", text: $host).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Manual Proxy")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") {
                        if let p = Int(portText) { port = p }
                        dismiss(); onUse()
                    }.disabled(host.isEmpty)
                }
            }
            .onAppear { portText = String(port) }
        }
    }
}
```

- [ ] **Step 5: Regenerate, build for simulator**

Run:
```bash
cd /Users/mac/Projects/htrail/iosapp && xcodegen generate >/dev/null && \
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit** (checkpoint — skip git)

---

## Task 11: Full verification + on-device run

**Files:** none (verification)

- [ ] **Step 1: Core tests**

Run: `swift test 2>&1 | tail -6`
Expected: all suites pass, including the new `SharedConfigFieldsTests`, `ProfileHTTPServerTests`, `BonjourServiceTests` (TXT tests must pass; the live discovery test is best-effort — note if it times out), `CaptureHealthCheckTests`, plus the existing suite + the live MITM test.

- [ ] **Step 2: macOS build**

Run: `swift build 2>&1 | tail -2`
Expected: `ok (build complete)`.

- [ ] **Step 3: iOS signed device build + install + launch**

Run:
```bash
cd /Users/mac/Projects/htrail/iosapp && xcodegen generate >/dev/null && \
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS \
  -destination 'id=00008140-001A19282EA3001C' -derivedDataPath /tmp/iosddp \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=D62Y8JVXB9 build 2>&1 | tail -4 && \
xcrun devicectl device install app --device 00008140-001A19282EA3001C \
  /tmp/iosddp/Build/Products/Debug-iphoneos/HTTrailiOS.app 2>&1 | tail -3 && \
xcrun devicectl device process launch --device 00008140-001A19282EA3001C com.1moby.httrail 2>&1 | tail -2
```
Expected: BUILD SUCCEEDED, App installed, Launched. (Unlock the phone first; a locked device fails launch with error 10002.)

- [ ] **Step 4: Manual end-to-end smoke (user)**

On the Mac: Start the proxy, enable "Discoverable over Bonjour" (approve Local Network if prompted). On the iPhone: Capture tab → Start menu lists the Mac → pick it → approve Local Network → if prompted, install/trust the Mac CA in Settings → return and Start → the banner shows "Routing to <Mac>…/healthy"; traffic flows appear in the **Mac's** capture sessions.

- [ ] **Step 5: Final commit** (checkpoint — skip git)

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** Bonjour module §3 → Task 3; Mac advertise + LAN CA server §4 → Tasks 2,7; iOS target picker + Start-VPN §5 → Tasks 8,10; Mac-CA auto-offer §6 → Tasks 8,10 (`macCAInstallURL`, install on Start); disclosure §7 → Tasks 6,9,10; health check + manual §8 → Tasks 4,10; extension remote branch §9 → Task 5; SharedConfig fields → Task 1; tests §10 → Tasks 1-4,11.
- **Type consistency:** `SharedConfig.remoteProxyHost/remoteProxyPort/bonjourEnabled`; `DiscoveredProxy{id,name,host,port,caPort,caFP}`; `BonjourTXT.encode/decode`; `BonjourAdvertiser.start(name:port:caPort:caFP:)`; `BonjourBrowser.found`; `CaptureTarget{.thisDevice,.remote,.manual}.remoteHostPort/.label`; `CaptureHealth{.healthy,.unreachable,.tlsUntrusted,.unknown}`; `CaptureHealthCheck.reachable(host:port:timeout:)`; `ProfileHTTPServer.start(bindHost:)`; AppModel: `setBonjourEnabled`, `refreshBonjour`, `startBonjourBrowsing`/`stopBonjourBrowsing`, `isMacCATrusted`, `macCAInstallURL`, `applyCaptureTargetForStart`, `runCaptureHealthCheck` — used consistently across tasks.
- **Known constraints:** the live Bonjour discovery test and on-device capture need a real LAN + permissions; route-to-Mac records on the Mac (not the iPhone) by design; target changes require Stop→Start.
