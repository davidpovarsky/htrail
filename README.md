# HTTrail

A native **Swift + SwiftUI** app that combines [Hoppscotch](https://github.com/hoppscotch/hoppscotch)
(API client) and [Charles Proxy](https://www.charlesproxy.com/) (HTTPS debugging
proxy) into one tool. No web stack — the only HTML in the app is the live
**preview/renderer** for HTML response bodies (via `WKWebView`).

It runs an intercepting **HTTPS proxy with its own Certificate Authority**, mints
per-host leaf certificates on the fly to decrypt TLS (MITM), captures every
request/response, and lets you compose and replay API requests.

## What works today

| Capability | Status |
|---|---|
| Root CA generation + persistence (P-256, self-signed, 10y) | ✅ |
| Per-host leaf cert minting signed by the CA (cached) | ✅ |
| HTTP proxy (absolute-form) | ✅ |
| HTTPS MITM via `CONNECT` → TLS terminate → forward → capture | ✅ (live-tested against real origins) |
| Charles-style flow list + inspector (headers / body / preview) | ✅ |
| HTML preview + image preview of response bodies | ✅ |
| Hoppscotch-style request composer (method, URL, params, headers, body modes, `{{env}}` vars) | ✅ |
| Response viewer (status, timing, size, pretty JSON, headers, HTML preview) | ✅ |
| macOS system-proxy toggle (`networksetup`, admin-prompted) | ✅ |
| **macOS one-click CA install + trust** (`security add-trusted-cert`, admin-prompted) | ✅ |
| iOS `.mobileconfig` profile (installs CA + proxy host:port) | ✅ |
| Reveal/export the root CA for trust install | ✅ |
| **Charles rules engine**: block, map local, map remote, rewrite request/response, throttle, breakpoints | ✅ |
| **SSL Proxying allowlist** (blind-tunnel non-listed hosts so pinned apps keep working) | ✅ |
| **Interactive breakpoints** — pause a flow, edit the body, continue | ✅ |
| Auth helpers (Bearer / Basic / API key in header or query) | ✅ |
| GraphQL request mode (query + variables) | ✅ |
| Environments with `{{variable}}` substitution | ✅ |
| Collections + request history (persisted to disk) | ✅ |
| Import cURL → request | ✅ |
| Code generation (cURL / Swift / JavaScript / Python) | ✅ |
| HAR 1.2 export of captured flows | ✅ |
| Edit-and-resend / "copy as cURL" from a captured flow | ✅ |
| WebSocket client (connect, send, live message log) | ✅ |
| SSE (Server-Sent Events) streaming client | ✅ |
| **Socket.IO** client (Engine.IO v4 handshake, emit/receive) | ✅ |
| **MQTT 3.1.1** client (connect/subscribe/publish over NIO) | ✅ |
| **Pre-request & test scripts** (JavaScriptCore, `pm.*` API) | ✅ |
| **OpenAPI 3 + Postman v2.1 import** → collections | ✅ |
| **Nested-folder collections** | ✅ |
| **Bandwidth shaping** (bytes/sec throttle) | ✅ |
| **iOS on-device capture VPN** (`NEPacketTunnelProvider` + App Group, proxy runs in extension) | ✅ wired in `iosapp/` (needs paid team entitlement to run on device) |

### Architecture

- **`HTTrailCore`** — dependency-light library (SwiftNIO + swift-certificates +
  swift-crypto). Contains the CA, the NIO MITM proxy engine, the flow model, the
  API-client runner, the system-proxy controller, and the iOS profile generator.
  Fully unit/integration tested via `swift test`.
  > Built in Swift 5 language mode because NIO `ChannelHandler`s are intentionally
  > non-`Sendable`.
- **`HTTrail`** — the SwiftUI macOS app.

## Build & run

```bash
# Tests (includes a live HTTPS MITM capture test)
swift test

# Run the app (packages a proper .app bundle so the window shows correctly)
./scripts/make_app.sh debug      # or: release
open dist/HTTrail.app
```

> Running the raw `swift run HTTrail` binary works but, without an `.app`
> bundle + `Info.plist`, the window server may not surface the window — always
> launch via the bundle from `scripts/make_app.sh`.

## Using it

1. **Start the proxy** (toolbar ▶ or ⌘P) — it listens on `127.0.0.1:9090`.
2. **Trust the CA**
   - **macOS:** Setup menu → *Install & Trust Root CA…* (one click, prompts for
     admin — adds the CA to the System keychain as an always-trusted root). Then
     toggle **System Proxy** to route this Mac's traffic through HTTrail.
   - **iOS (this device):** Setup tab → *Install CA Profile* (install + trust the
     CA), then *Start Capturing This Device* to provision the on-device capture
     VPN. The proxy runs inside the network extension, so capture continues while
     the app is backgrounded. Requires a paid Apple Developer team.
   - **iOS (another device via your Mac):** Setup menu → *Export iOS Profile…*.
     AirDrop/email the `.mobileconfig` to the device, install it (Settings →
     Profile), then enable trust under *Settings → General → About → Certificate
     Trust Settings*. The profile also points the device's HTTP/HTTPS proxy at
     this Mac's LAN IP.
3. **Capture** traffic appears live in the **Capture** tab; select a flow to
   inspect request/response headers, bodies (pretty-printed JSON), and the HTML
   preview.
4. **Compose** API requests in the **Compose** tab and hit Send (⌘↵).

## Remaining / nice-to-have

The major Hoppscotch + Charles feature surface is implemented, including the iOS
on-device capture VPN (`iosapp/PacketTunnel`). Still optional: drag-and-drop
collection re-organisation, request-level CA/cert pinning config, and a visual
diff between two flows.
