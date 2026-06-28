# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

HTTrail is a native **Swift + SwiftUI** app combining a Hoppscotch-style API client and a Charles-style intercepting HTTPS debugging proxy. It runs its own Certificate Authority, mints per-host leaf certs on the fly to MITM TLS, captures every request/response, and lets you compose/replay requests. No web stack — the only HTML is the `WKWebView` live preview of HTML response bodies.

See `README.md` (feature matrix + usage) and `ios/README.md` (iOS capture paths) for product-level detail.

## Build, run, test

```bash
swift test                       # full suite incl. a LIVE HTTPS MITM capture test against real origins
swift test --filter testHTTPSMITMCapture   # single test (by method name)

./scripts/make_app.sh debug      # build + package dist/HTTrail.app  (or: release)
open dist/HTTrail.app

./scripts/make_icons.sh          # regenerate all app icons from branding/logo.svg (needs rsvg-convert)
```

- **Always launch the macOS app via the `.app` bundle**, not `swift run HTTrail`. Without the bundle + `Info.plist` the window server may not surface the window. `make_app.sh` also ad-hoc codesigns so WKWebView/network APIs run without Gatekeeper friction.
- `swift test` opens a real outbound TLS connection — it needs network access and will fail offline.
- iOS app: `cd iosapp && xcodegen generate` (regenerates `HTTrailiOS.xcodeproj` from `project.yml`), then build in Xcode. Running on a device needs a **paid** Apple Developer team (the `packet-tunnel-provider` Network Extension entitlement is unavailable to free personal teams). Signing team is `D62Y8JVXB9`. See the project memory for device-install commands.

## Distribution & release

Full procedure in **`docs/DEPLOY.md`**. Two paths:

- **Direct download** — `make_app.sh release` (ad-hoc signed, un-sandboxed full-feature build), published as `HTTrail-macOS.zip` on the GitHub release; the site links the stable `releases/latest/download/` URL.
- **App Store** (macOS + iOS) — build/sign locally (`make_mas.sh DISTRIBUTION=1` for the sandboxed MAS variant; xcodegen/xcodebuild for iOS), then the manual `.github/workflows/deploy.yml` ("Deploy to App Store") uploads + submits via repo secrets.

The App Store **signing/submission tooling is private and git-ignored**: `scripts/appstore/` (`asc.py` — the App Store Connect API helper) and `docs/appstore/` (key IDs + the submission runbook). Never move these into the tracked tree or paste their key IDs into public files; CI runs `asc.py` from the encrypted `ASC_PY_B64` secret, not a checkout.

## Architecture

Two SPM targets plus a separate iOS Xcode app, all built on one shared core:

- **`HTTrailCore`** (`Sources/HTTrailCore/`) — dependency-light library: the CA, the SwiftNIO MITM proxy engine, the flow/workspace model, the API-client runner, realtime clients, persistence, the system-proxy controller, and the iOS profile generator. Deps: swift-nio, swift-nio-ssl, swift-certificates, swift-crypto, swift-asn1. **Fully unit/integration tested via `swift test`.**
- **`HTTrail`** (`Sources/HTTrail/`) — the SwiftUI **macOS** app (thin: `HTTrailApp.swift` + `Views/`).
- **`iosapp/`** — the **iOS** app + Packet Tunnel network extension, a standalone xcodegen project that depends on `HTTrailCore` as an SPM package.

### Critical: language mode split

`HTTrailCore` builds in **Swift 5 language mode** (`swiftSettings: [.swiftLanguageMode(.v5)]` in `Package.swift`) even though tools-version is 6.0. This is deliberate: NIO `ChannelHandler`s are event-loop-confined and intentionally non-`Sendable`. Don't "fix" this by enabling strict concurrency on the core target.

### Shared model, platform-specific views

`AppModel` (`Sources/HTTrailCore/UI/AppModel.swift`, `@MainActor ObservableObject`) is the single application model used **identically** by both apps — keeping it in the core guarantees feature parity. The macOS views (`Sources/HTTrail/Views/`) and iOS views (`iosapp/Sources/`) are **separate** SwiftUI layers that both bind to this shared `AppModel`. Platform-native affordances (macOS system proxy, Finder reveal; iOS VPN) are conditionally compiled with `#if os(...)` / `#if canImport(AppKit)`.

`FlowBridge` (FlowSink) hops captured flows from NIO event-loop threads onto the main actor via `DispatchQueue.main.async` so SwiftUI can observe them.

### The proxy engine (`Sources/HTTrailCore/Proxy/`)

The MITM data flow: plain HTTP (absolute-form URI) is proxied directly; HTTPS arrives as `CONNECT host:443` → answer `200` → terminate TLS with a leaf cert minted by `CertificateAuthority` for that host → read decrypted HTTP → forward to the real origin over a fresh TLS connection → emit a `Flow` for both directions.

- `ProxyServer.swift` — NIO bootstrap, listens on `127.0.0.1:9090`.
- `ProxyHandlers.swift` — CONNECT handling, per-host TLS server context from minted leaf material.
- `DecryptedProxyHandler.swift` — the decrypted request/response path + capture.
- `GlueHandler.swift` — bidirectional byte pumping between client and origin channels.
- `InterceptEngine.swift` — the Charles **rules engine** (`RuleKind`: block / mapLocal / mapRemote / rewriteRequest / rewriteResponse / throttle / breakpoint) plus the SSL-proxying allowlist (non-listed hosts are blind-tunnelled so pinned apps keep working).

### CA & cert trust

`CertificateAuthority.swift` generates a self-signed P-256 root (10y, persisted) and mints/caches per-host leaf certs chaining to it. `CATrustProbe.swift` checks trust status; `SystemProxyController.swift` toggles the macOS system proxy via `networksetup` (admin-prompted); `ProfileGenerator.swift` + `ProfileHTTPServer.swift` build and serve the iOS `.mobileconfig` (CA + proxy/VPN payload).

### iOS two-process sharing

The iOS app renders only; the **Packet Tunnel extension** (`iosapp/PacketTunnel/`) runs the MITM proxy so capture survives backgrounding. The two processes coordinate through the **App Group `group.com.1moby.httrail`**:
- `AppGroup.swift` — group container + `captured-flows.ndjson` (extension appends, app tails).
- `AppPaths.swift` — on iOS prefers the App Group container (so both processes read the *same* CA); falls back to per-app Application Support on macOS/tests/missing entitlement.
- `SharedConfigStore.swift` / `SharedFlowStore.swift` — config + flow exchange across the boundary.

When changing the App Group ID, update it in **all three** places: `AppGroup.identifier`, `iosapp/HTTrailiOS.entitlements`, and `iosapp/PacketTunnel/PacketTunnel.entitlements`.

### Other core areas

- `APIClient/` — `RequestRunner`, `CurlConverter` (import), `CodeGenerator` (cURL/Swift/JS/Python export), `ScriptRunner` (pre-request & test scripts via JavaScriptCore with a `pm.*` API), `Importers` (OpenAPI 3 + Postman v2.1 → collections).
- `Realtime/` — WebSocket, SSE, Socket.IO (Engine.IO v4), MQTT 3.1.1 (over NIO) clients.
- `Model/` — `Flow`, `Workspace`. `Persistence/JSONStore.swift` — disk-backed collections/history/environments. `Export/HARExporter.swift` — HAR 1.2.

## Conventions

- Tests live in `Tests/HTTrailCoreTests/`; all logic is exercised at the `HTTrailCore` level (the UI apps stay thin). Add coverage there.
- Keep shared logic in `HTTrailCore` so both platforms inherit it; only put truly platform-native code behind `#if os(...)` in the app targets.
