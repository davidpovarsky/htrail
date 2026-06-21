# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This file is scoped to `iosapp/` (the iOS app + Packet Tunnel extension). **Read the repo-root `../CLAUDE.md` first** — it covers the shared `HTTrailCore` library (CA, NIO MITM proxy engine, `AppModel`, persistence, importers, realtime clients) that this app is a thin SwiftUI shell over. Don't duplicate core logic here; add it to `HTTrailCore` so the macOS app inherits it too.

## Build, run, install

This is an **xcodegen** project — `project.yml` is the source of truth; the `.xcodeproj` is generated, so never hand-edit it. After changing `project.yml`, sources list, entitlements, or Info.plist keys, regenerate:

```bash
cd iosapp && xcodegen generate          # regenerates HTTrailiOS.xcodeproj

# Build both targets (app + PacketTunnel) signed for a device:
xcodebuild -project HTTrailiOS.xcodeproj -scheme HTTrailiOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=D62Y8JVXB9 build

# Install on the paired device:
xcrun devicectl device install app --device <DEVICE_UDID> \
  build/dd/Build/Products/Debug-iphoneos/HTTrailiOS.app
# Launch with console: xcrun devicectl device process launch --console --device <UDID> com.1moby.httrail
```

- **Tests live in `HTTrailCore`** (`swift test` from repo root). The app/extension stay thin; add coverage at the core level. There is no iOS-target test bundle.
- **A paid Apple Developer team is required** to run on device — the `packet-tunnel-provider` Network Extension entitlement is unavailable to free personal teams. Signing team is `D62Y8JVXB9`; app bundle `com.1moby.httrail`, extension `com.1moby.httrail.PacketTunnel`.
- Diagnose extension crashes/jetsam via the device's `.ips` reports and `os.log` (subsystem `com.1moby.httrail.PacketTunnel`).

## Two-process architecture (the thing to internalize)

The app renders only; the **Packet Tunnel extension is a separate process that does the actual capturing** and keeps running when the app is backgrounded. They never share memory — they coordinate exclusively through the **App Group `group.com.1moby.httrail`** (core's `AppGroup`/`AppPaths`/`SharedConfigStore`/`SharedFlowStore`):

- App writes rules / SSL allowlist / port / capture target into the shared config; the extension polls it (`startConfigSync`, ~1.5s) so edits take effect live, and publishes back detected pinned hosts + an `EngineStatus` heartbeat.
- Extension appends captured flows to the App Group; the app **tails them on a 1.5s timer** in `App.swift` (`refreshSharedFlows` / `refreshPinnedHosts` / `refreshCaptureStatus`).
- Both processes load the **same CA from the App Group container** so minted leaf certs chain to the root the user trusted on the device.

**When changing the App Group ID, update all three places:** `AppGroup.identifier` (core), `iosapp/HTTrailiOS.entitlements`, and `iosapp/PacketTunnel/PacketTunnel.entitlements`.

## PacketTunnelProvider (`PacketTunnel/PacketTunnelProvider.swift`)

`NETransparentProxyProvider` is macOS-only, so iOS uses a **"proxy-only" packet tunnel**: all IP routes are *excluded* (no packets routed through us), and `NEProxySettings` is injected so the system funnels HTTP/HTTPS at a proxy. Two modes, chosen from the shared config:

- **On-device:** runs the `HTTrailCore` `ProxyServer` bound to `127.0.0.1` inside the extension and points proxy settings there.
- **Remote (BYO-CA):** does *not* run a local proxy — points proxy settings at a Mac's LAN `host:port`; the Mac decrypts and records.

The extension runs under a **hard ~50 MB memory cap** — jetsam there manifests to the user as the VPN "flapping/disabling itself." This is why the core proxy streams large response bodies instead of buffering them; keep that constraint in mind for anything that allocates per-request.

## VPN provisioning & status (`Sources/VPNController.swift`)

`VPNController` is the VPN *provisioning* surface — it loads/creates the `NETunnelProviderManager`, saving which triggers the system "Add VPN configurations" consent prompt, and starts/stops the tunnel. Key invariants:

- An **on-demand connect rule** (`NEOnDemandRuleConnect`, `.any`) is set on start so iOS keeps the tunnel alive across app-switching/network blips. `disable()` **must clear on-demand before stopping**, or iOS instantly reconnects. On-demand saves are best-effort (a profile-managed config may reject app edits — start anyway).
- Status comes from `NEVPNStatusDidChange` plus a periodic reconcile poll (catches transitions missed while suspended). `phase` maps `NEVPNStatus` to core's `VPNPhase` for the status combiner.

## Capture targets & live status (`Sources/CaptureView.swift`)

Capture target is one of `thisDevice` / `remote(DiscoveredProxy)` / `manual(host,port)` (core `CaptureTarget`). Discovery uses Bonjour (`_httrail._tcp`) — browsing only starts **after** the Local Network disclosure sheet, so the OS permission prompt never precedes the explanation (App Store requirement). Discovered Macs surface as explicit "Capture on …" buttons (no hidden long-press).

**BYO-CA pairing (remote):** on start, the iPhone POSTs its own CA (cert *and* key, plaintext over LAN — intentional, same posture as Charles/Proxyman) to the Mac's pairing server; the Mac spins up a dedicated per-device proxy on an ephemeral port and returns it. The iPhone never installs the Mac's CA; the Mac never keychain-trusts the uploaded CA (in-memory only).

While capturing, `AppModel.startCaptureMonitor` runs a continuous loop (remote: reachability + periodic HTTPS-trust probe; on-device: extension heartbeat) feeding `captureHealth`. The banner is rendered from a single pure combiner, `CaptureHealthCheck.liveStatus(vpn:targetIsRemote:health:engineLive:)` → `CaptureLiveStatus` (unit-tested in core) — fold tunnel phase + Mac/engine health there, not in the view.

## View layer

`RootTabView` mirrors the macOS feature set as tabs — **Capture, Compose, Rules, Realtime, Setup** — all binding to the shared `@MainActor AppModel`. `SetupView` drives the two capture-provisioning flows documented in `../ios/README.md` (on-device VPN+CA profile; export a CA+proxy profile for *another* device). Breakpoints (`model.pendingBreakpoint`) are presented globally from `App.swift` since they can fire from any tab. Platform-native code (VPN, UIKit) stays in this target behind the shared model; everything reusable belongs in `HTTrailCore`.
