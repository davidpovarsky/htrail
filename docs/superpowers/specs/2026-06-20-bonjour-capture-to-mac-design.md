# Bonjour Discovery + Capture-to-Mac Design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)
**Scope:** macOS app + iOS app + iOS PacketTunnel extension (shared `HTTrailCore`)
**Builds on:** the capture-sessions feature (`2026-06-20-capture-sessions-design.md`).

## 1. Goal

Let an iPhone capture its traffic **to a running Mac HTTrail instance over the LAN**, discovered automatically via **Bonjour**, as an alternative to on-device capture. Pressing **Start Capture** on the iPhone enables the VPN; a **capture-target picker** chooses where traffic is decrypted/recorded:

- **This iPhone** — on-device MITM (PacketTunnel runs the proxy locally; records into iPhone sessions). *Existing behavior, now reachable from the Capture-tab Start.*
- **A discovered Mac** — the PacketTunnel forwards the phone's HTTP/HTTPS to that Mac's proxy; the **Mac** decrypts and records into the **Mac's** sessions.
- **Manual…** — user-entered `host:port` (the fallback when discovery/health fails).

When discovery or the proxy path doesn't work, a **health check** surfaces explicit manual instructions. Bonjour requires Local Network access, so the app **explicitly discloses** why before triggering the system prompt (App Store review + user trust).

All reusable logic lives in `HTTrailCore`; the macOS/iOS view layers stay thin.

## 2. Topology & transport

Both transports use the **same iOS PacketTunnel VPN** ("enable VPN on iPhone"); only the proxy endpoint differs:

| Target | PacketTunnel local proxy | `NEProxySettings` server | Decrypt + record |
|--------|--------------------------|--------------------------|------------------|
| This iPhone | runs (`127.0.0.1:port`) | `127.0.0.1:port` | iPhone |
| A Mac | **not started** | `<MacIP>:<MacPort>` | Mac |
| Manual | **not started** | `<userHost>:<userPort>` | that host |

For a Mac/manual target the iPhone must trust the **Mac's** root CA (the Mac mints leaf certs with its own CA). See §6.

## 3. Bonjour module (`Sources/HTTrailCore/Discovery/BonjourService.swift`)

Foundation `NetService`/`NetServiceBrowser` (no new dependency; usable from the dependency-light core; available on both platforms). Service type **`_httrail._tcp`**, domain `local.`.

```swift
public struct DiscoveredProxy: Identifiable, Hashable, Sendable {
    public var id: String      // service name (stable within a browse session)
    public var name: String    // human label (device name)
    public var host: String    // resolved IPv4/host
    public var port: Int       // proxy port
    public var caPort: Int     // LAN CA-profile HTTP port (0 if absent)
    public var caFP: String    // short SHA-256 prefix of the Mac root CA DER ("" if absent)
}

public final class BonjourAdvertiser {           // used by the Mac
    func start(name: String, port: Int, caPort: Int, caFP: String)
    func stop()
}

public final class BonjourBrowser: ObservableObject {   // used by iOS
    @Published public private(set) var found: [DiscoveredProxy]
    func start(); func stop()
}
```

- **Advertiser** publishes `_httrail._tcp` on the proxy `port` with a TXT record `{name, port, caPort, caFP}`.
- **Browser** browses, resolves each service to host/port, parses TXT for `name`/`caPort`/`caFP`, and maintains `found` (add on resolve, drop on remove). Delegate callbacks marshalled to the main actor.

Both types compile on both platforms ("support both macOS+iOS"); the wiring is Mac=advertise, iOS=browse.

## 4. Mac side

- **AppModel** (`#if os(macOS)` parts): `@Published var bonjourEnabled = false` (persisted in `SharedConfig`, default **off**), and a `BonjourAdvertiser` + a LAN CA server (`ProfileHTTPServer`, see below).
- **Lifecycle:** advertise iff `bonjourEnabled && isProxyRunning`. So toggling Bonjour while stopped does nothing until Start; stopping the proxy stops advertising. `startProxy`/`stopProxy` and the toggle all funnel through one `refreshBonjour()` helper.
- **CA-over-LAN:** generalize `ProfileHTTPServer` (remove the `#if os(iOS)` gate; add `bindHost: String = "127.0.0.1"` to `start`). The Mac starts one bound to `0.0.0.0` serving the **CA-only** profile (`ProfileGenerator().makeProfile(caCertificateDER:proxyHost:proxyPort:includeProxyPayload:false)`), and advertises its chosen port as `caPort` in TXT.
- **UI:** a "Discoverable over Bonjour" toggle in the Setup menu. Turning it **on** first shows the disclosure (§7); the status bar shows "Discoverable as <name>" while advertising.

## 5. iOS side

- **AppModel:** `@Published var captureTarget: CaptureTarget` where
  ```swift
  public enum CaptureTarget: Hashable, Sendable {
      case thisDevice
      case remote(DiscoveredProxy)
      case manual(host: String, port: Int)
  }
  ```
  plus a `BonjourBrowser` (started while the Capture tab is visible / Bonjour permission granted), and `@Published var manualHost/manualPort` for the fallback.
- **Capture control bar:** a target **Menu** — "This iPhone", each `browser.found` Mac ("<name> · host:port"), and "Manual…". Selecting a remote target the first time triggers the Local Network disclosure (§7) then the browse.
- **Start** (`startCapture()`): writes the target into `SharedConfig` (`remoteProxyHost/Port` = nil for on-device, else the target's host/port) via `pushRulesToEngine()`, ensures Mac-CA trust for remote targets (§6), then enables the VPN (`VPNController.startCapture`). **Stop** disables the VPN and `endCaptureSession()`.
- **While routing to a Mac:** the Capture flow list shows an info state ("Routing to <Mac> — flows are recorded on that Mac"), since no flows are captured locally. On-device target keeps the normal live list + sessions.

## 6. Mac-CA trust for remote targets (auto-offer)

The iPhone cannot directly probe trust of the **Mac's** CA (`CATrustProbe` only validates this device's *own* CA, since it signs the loopback leaf with the local CA key — which we don't have for the Mac). So trust is handled by **offer + confirm**:

- On selecting a Mac, if we have no persisted "installed" marker for that Mac's CA (keyed by the TXT'd CA fingerprint, see below), the iPhone offers to install it: open `http://<MacIP>:<caPort>/HTTrail-CA.mobileconfig` (host from Bonjour resolution, `caPort` from TXT) via `openURL` → Safari downloads → user installs & trusts the **Mac's** CA in Settings. This reuses the Mac's LAN CA server from §4; no new server on the iPhone. The install offer is idempotent (re-installing an already-trusted CA is harmless), so a wrong marker never blocks capture.
- **Confirmation** that trust actually took effect is the health-check's TLS test (§8): a TLS/trust failure re-surfaces the install offer; success sets the per-Mac marker so we don't re-prompt next time.
- The Bonjour TXT carries a short **CA fingerprint** (`caFP`, SHA-256 prefix of the Mac's root DER) so the marker is keyed to the actual CA, and a Mac that rotates its CA re-prompts. If `caPort == 0` (Mac not serving the profile), fall back to the manual instructions in §8.

## 7. App Store / privacy disclosure

- **Info.plist (both targets):** `NSLocalNetworkUsageDescription` = a clear purpose string ("HTTrail uses the local network to discover and connect to a Mac running HTTrail so this device's traffic can be captured there."), and `NSBonjourServices = ["_httrail._tcp"]`. macOS: add to `Resources/Info.plist`. iOS: add under the app target's `info.properties` in `iosapp/project.yml` (xcodegen writes the plist — content must be under `properties:`, per the known xcodegen gotcha).
- **In-app explicit disclosure:** the **first time** Bonjour is enabled (Mac: toggling Discoverable; iOS: choosing a remote target / starting browse), show a sheet stating exactly what local-network access is for and that it will prompt — shown **before** the OS permission prompt. A persisted flag (`bonjourDisclosureShown`) avoids re-showing.

## 8. Health check + manual fallback

After Start with a remote/manual target, the iPhone runs `CaptureHealthCheck`:
1. **Reachability:** TCP connect to `host:port`. Failure → banner "Can't reach <host:port>" + steps (Mac running & Started? same Wi-Fi? firewall?).
2. **TLS:** a test HTTPS request routed through the tunnel. A TLS/trust error → banner "Mac CA not trusted" + steps (install/trust the Mac CA — link re-opens the §6 profile URL). Connection success → healthy (clear banner).

The banner also always offers **Manual proxy setup** instructions: set this device's Wi-Fi HTTP proxy to `host:port` and trust the Mac CA — the non-VPN fallback if the VPN path fails entirely.

## 9. PacketTunnel extension change

`SharedConfig` gains `remoteProxyHost: String?` and `remoteProxyPort: Int?` (default nil). In `PacketTunnelProvider.startTunnel`:
- If `remoteProxyHost != nil`: **do not** start the local `ProxyServer`; call `applyNetworkSettings` with `NEProxyServer(address: remoteProxyHost!, port: remoteProxyPort ?? proxyPort)`. Rules/allowlist are irrelevant here (the Mac does interception).
- Else: current on-device behavior (local proxy at `127.0.0.1`, proxy settings to it).

Target is captured at tunnel start; switching targets requires Stop→Start (the existing "old extension keeps running until tunnel restart" gotcha applies). `engine-status` publishing continues for on-device mode.

## 10. Testing (`Tests/HTTrailCoreTests/`)

- **`BonjourServiceTests`** — start an advertiser on a loopback service with a TXT, run a browser, assert the service is discovered with the correct `name`/`port`/`caPort`, then assert removal on `stop()`. (Runs on the test host; bounded with an expectation timeout.)
- **`SharedConfigTests`** — `SharedConfig` round-trips the new `remoteProxyHost`/`remoteProxyPort`; absent fields decode to nil (back-compat with existing on-disk configs).
- **`ProfileHTTPServerTests`** — server bound to `127.0.0.1` (test) serves the payload with `Content-Type: application/x-apple-aspen-config`; a CA-only profile from `makeProfile(includeProxyPayload:false)` contains the root payload and no proxy payload.
- **`CaptureHealthCheckTests`** — reachability succeeds against a live local listener and fails against a closed port (classify reachable vs unreachable). TLS-trust branch verified by inspection (needs a device).
- Extension routing + UI wiring verified by build (macOS `swift build`, iOS simulator `xcodebuild`) + on-device run.

## 11. Out of scope

- Switching capture target mid-capture without Stop/Start.
- A Mac discovering/recording from another Mac (advertiser is Mac, browser is iOS).
- Supervised-device global-proxy profiles (we use the VPN transport).
- Recording route-to-Mac flows on the iPhone (they are recorded on the Mac by design).
