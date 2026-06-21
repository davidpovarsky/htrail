# Bring-Your-Own-CA Bonjour Capture + Broadcast Fixes — Design

**Date:** 2026-06-21
**Status:** Approved direction (pending spec review)

## Problem

Two issues with the existing Bonjour capture-to-Mac feature:

1. **The Mac never appears on the network.** `dns-sd -B _httrail._tcp` shows nothing while the rest of the Bonjour environment is healthy. Causes:
   - Advertising is gated on `bonjourEnabled && isProxyRunning`, with no UI signal indicating which precondition is missing.
   - `BonjourAdvertiser` sets a delegate but implements no `netServiceDidPublish` / `netService(_:didNotPublish:)`, so publish failures (most likely macOS Sequoia Local Network permission, or a name clash) are completely silent.

2. **Wrong CA model for capture-to-Mac.** Today the Mac decrypts an iPhone's traffic with the **Mac's** CA, forcing the iPhone to install and trust the Mac's CA. The desired model: the iPhone keeps using **its own** CA — the one it already trusts for on-device capture — and the Mac uses that CA to decrypt this device's traffic.

## Goals

- **G1.** Enabling "Discoverable over Bonjour" broadcasts immediately (auto-starting the proxy if needed) and the UI reports publish success/failure.
- **G2.** Capture-to-Mac uses the iPhone's own CA: the iPhone uploads its CA (cert + private key) to the Mac; the Mac runs a **dedicated per-device proxy** on a fresh port using that CA; the iPhone routes there. No Mac-CA install on the iPhone; the Mac **never** trusts the uploaded CA in its keychain, and the per-device port is isolated from Mac-local capture.

## Non-goals

- Mac-local capture is unchanged (uses the Mac's own CA on `proxyPort`).
- On-device iOS capture is unchanged (uses the iPhone's CA in-process / in the extension).
- No encryption/auth of the pairing upload beyond LAN scoping (see Security).
- No Mac-side "allow this device?" prompt — uploads are auto-accepted on the LAN (per user decision: "only upload and run separate proxy with that CA").

## Architecture

### Prerequisite (clarified model)

The iPhone must already have **its own** HTTrail CA installed and trusted (the same profile/CA used for on-device capture). With that single trust in place, **both** on-device capture and capture-to-Mac work with zero further trust steps. This is strictly simpler than today (one CA to trust instead of two).

### Topologies

| Mode | Proxy | CA | Trust required on iPhone |
|---|---|---|---|
| Mac-local | Mac main proxy (`proxyPort`) | Mac CA | — |
| iOS on-device | in-process / extension | iPhone CA | iPhone CA (already) |
| **iOS → Mac (new)** | **per-device proxy (ephemeral port)** | **iPhone CA (uploaded)** | **iPhone CA (already)** |

### Components

**1. `CertificateAuthority.from(certificatePEM:keyPEM:)`** (new static factory)
Reconstructs a CA from external material — exactly what `loadOrCreate`'s existing-file branch already does. Refactor that branch to call the new factory so there is one code path. Also expose:
- `public var caPrivateKeyPEM: String` → `caBackingKey.pemRepresentation` (needed so the iPhone can upload its CA key).

**2. `PairingServer`** (new, `Sources/HTTrailCore/Discovery/PairingServer.swift`)
A small NIO HTTP server, bound `0.0.0.0` on an OS-assigned port. Routes:
- `POST /pair` — body JSON `{ deviceName, deviceID, caCertPEM, caKeyPEM }`. Accumulates the request body to `.end`, decodes, invokes an async handler closure provided by `AppModel`, and replies `200` with `{ proxyPort, sessionName }` (or `400` on malformed JSON, `500` if the handler returns nil).
- `POST /unpair` — body JSON `{ deviceID }`; stops that device's proxy; replies `200 {}`.

The handler closure signature:
```swift
public struct PairRequest: Codable, Sendable { public var deviceName: String; public var deviceID: String; public var caCertPEM: String; public var caKeyPEM: String }
public struct PairResponse: Codable, Sendable { public var proxyPort: Int; public var sessionName: String }
var onPair: ((PairRequest) async -> PairResponse?)?
var onUnpair: ((String) async -> Void)?
```

**3. `ProxyServer` change** — expose the actually-bound port so a per-device proxy can bind an ephemeral port:
```swift
public var boundPort: Int { channel?.localAddress?.port ?? port }
```
(Bind with `port: 0`, then read `boundPort`.)

**4. `AppModel` (macOS) pairing registry**
```swift
private struct DeviceCapture { let ca: CertificateAuthority; let proxy: ProxyServer; let port: Int; let sessionID: UUID; let bridge: FlowBridge }
private var deviceProxies: [String: DeviceCapture] = [:]   // keyed by deviceID
@Published public private(set) var pairedDeviceCount = 0
```
- `pairDevice(_ req: PairRequest) async -> PairResponse?`:
  1. If a device with this `deviceID` is already paired, tear it down first (re-pair).
  2. Reconstruct CA via `CertificateAuthority.from(certificatePEM:keyPEM:)`. On failure return nil.
  3. Create a per-device session: `sessionStore.createSession(named:)` using `deviceName` (+ timestamp). Capture its `id`.
  4. Create a per-device `FlowBridge` whose `onFlow` calls `ingestDeviceFlow(flow, sessionID:)` on the main actor.
  5. `ProxyServer(port: 0, certificateAuthority: ca, sink: bridge, engine: <shared engine>)`, `bindHost = "0.0.0.0"`, `try await start()`, read `boundPort`.
  6. Store in `deviceProxies`, bump `pairedDeviceCount`, refresh `sessions`. Return `PairResponse(proxyPort: boundPort, sessionName: <session name>)`.
- `unpairDevice(_ deviceID:)`: stop proxy, remove entry, decrement count.
- `ingestDeviceFlow(_ flow: Flow, sessionID: UUID)`: stamp `flow.sessionID = sessionID`, `sessionStore.record(flow, in: sessionID)`, update `sessions` (record counts), and if the user is currently `viewingSessionID == sessionID`, append to `displayedFlows`/`flows` for live view. Does **not** touch the Mac's own active capture session.
- The uploaded CA is held only inside `DeviceCapture` (in memory). It is never written to the keychain, never persisted, and is dropped on unpair / stop / bonjour-off.

**5. Bonjour advertising changes**
- `BonjourTXT` gains `pairPort` (Int). `encode`/`decode` updated; decode stays tolerant of missing keys for back-compat. `caPort`/`caFP` retained but unused by the new flow.
- `DiscoveredProxy` gains `pairPort: Int`.
- `BonjourAdvertiser` implements `netServiceDidPublish` / `netService(_:didNotPublish:)` and exposes `var onState: ((BonjourPublishState) -> Void)?` where `enum BonjourPublishState { case publishing, published, failed(String) }`.
- `AppModel.refreshBonjour()`:
  - `shouldAdvertise = bonjourEnabled` (proxy guaranteed running, see setBonjourEnabled).
  - When advertising: start `PairingServer` (bound `0.0.0.0`, wire `onPair`/`onUnpair`), advertise `pairPort` in TXT, set status from the advertiser's publish state.
  - When not: stop the PairingServer, tear down all `deviceProxies`, stop the advertiser.
- `AppModel.setBonjourEnabled(true)`: set flag; if `!isProxyRunning`, call `startProxy()` (its success path calls `refreshBonjour()`); else call `refreshBonjour()` directly. `setBonjourEnabled(false)`: clear flag, `refreshBonjour()` (tears everything down). Proxy itself is left running on disable (only advertising stops).
- The old LAN CA-profile server (`caLANServer`) for the trust-Mac-CA flow is removed from the Bonjour path (obsolete — the iPhone no longer installs the Mac CA).

**6. iOS side**
- `DiscoveredProxy.pairPort` consumed.
- New `AppModel` (iOS) method `pairWithMac(_ proxy: DiscoveredProxy) async -> Int?`: POST `{ deviceName: UIDevice name, deviceID: identifierForVendor, caCertPEM: ca.caCertificatePEM, caKeyPEM: ca.caPrivateKeyPEM }` to `http://<proxy.host>:<proxy.pairPort>/pair`; parse `{ proxyPort }`; return it.
- `applyCaptureTargetForStart` for `.remote`: call `pairWithMac`, then set `pendingRemoteEndpoint = (proxy.host, returnedProxyPort)` so `currentConfig()` sets `remoteProxyHost/Port` and the extension routes there.
- **Remove** the Mac-CA install/auto-offer/trust-marker flow (`isMacCATrusted`, `markMacCATrusted`, `macCAInstallURL`, the `openURL` CA install) for the remote path — obsolete. Health check (`runCaptureHealthCheck`) is retained (reachability + tlsProbe of the returned port).
- `.manual` target: unchanged (no pairing; user is responsible for trust on a manually-specified proxy). Documented v1 gap.

### Data flow (iOS → Mac, new)

```
iPhone                              Mac
  | discover via Bonjour (pairPort) |
  |-- POST /pair {caCert,caKey} ---->| reconstruct CA, start device proxy(:N),
  |<-- 200 {proxyPort:N} ------------| create session "iPhone …"
  | start VPN -> Mac:N               |
  | HTTPS traffic ------------------>| device proxy mints leaves w/ iPhone CA
  |   (iPhone already trusts CA)     |   -> flows recorded to that session
```

## Security

- The pairing upload carries the iPhone's CA **private key** over plaintext LAN HTTP. This is standard for LAN debugging tools (Charles/Proxyman behave similarly) and is acceptable for this product on a trusted network. It is explicitly flagged in the spec and in a code comment.
- Mitigations in v1: the PairingServer only runs while Bonjour is enabled; uploaded CAs are in-memory only, never written to disk or the Mac keychain, and are destroyed on unpair / proxy stop / Bonjour disable. Pairing is auto-accepted on the LAN per the user's decision.
- Out of scope (future): pairing PIN/confirmation, TLS on the pairing channel.

## Testing

Unit/integration in `Tests/HTTrailCoreTests/`:
1. `CertificateAuthority.from` round-trip: reconstruct from a created CA's `caCertificatePEM` + `caPrivateKeyPEM`; assert the reconstructed CA mints a leaf chaining to the same root (same `caCertificateDER`).
2. `BonjourTXT` encode/decode includes `pairPort`; decode tolerates its absence.
3. `PairingServer`: real `POST /pair` over loopback invokes the handler with decoded fields and returns the handler's `proxyPort`; malformed JSON → `400`.
4. `AppModel.pairDevice` (macOS, injected `sessionStore`): creates a session, starts a device proxy on a non-zero port distinct from `proxyPort`, and `ingestDeviceFlow` records into that session (record count increments); `unpairDevice` stops it and decrements `pairedDeviceCount`.
5. `ProxyServer.boundPort` returns a non-zero port after starting with `port: 0`.

UI/manual (documented, not unit-tested): Bonjour publish callback state, Local Network permission, end-to-end device capture.

## Files

- Modify: `Sources/HTTrailCore/CertificateAuthority.swift` (factory + `caPrivateKeyPEM`)
- Modify: `Sources/HTTrailCore/Proxy/ProxyServer.swift` (`boundPort`)
- Create: `Sources/HTTrailCore/Discovery/PairingServer.swift`
- Modify: `Sources/HTTrailCore/Discovery/BonjourService.swift` (TXT `pairPort`, advertiser publish callbacks, `DiscoveredProxy.pairPort`)
- Modify: `Sources/HTTrailCore/UI/AppModel.swift` (pairing registry, `ingestDeviceFlow`, `refreshBonjour`/`setBonjourEnabled` changes, iOS `pairWithMac`, remove Mac-CA-trust remote flow)
- Modify: `Sources/HTTrail/Views/RootView.swift` (toggle auto-start, advertising state + paired-device count in status bar)
- Modify: `iosapp/Sources/CaptureView.swift` (remove CA auto-offer for remote; pair-then-start)
- Tests: `Tests/HTTrailCoreTests/` (new cases per Testing)
```
