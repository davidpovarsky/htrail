# Pureline downstream integration

Pureline is the downstream product layer joining two independently updateable upstreams:
HTTrail and `Vendor/AI-Image-Classifier`. Product policy, persistence, diagnostics,
resource limits, and image-filter choices remain in `iosapp/PurelineIntegration`,
`iosapp/ImageFilterIntegration`, and `iosapp/PacketTunnel` wherever possible.

# HTTrail upstream modifications

## `Sources/HTTrailCore/Model/Flow.swift`

- Exact reason: request capture previews need an explicit truncation marker just as responses already had.
- Generic hook/change: optional `CapturedRequest.bodyTruncated` Codable field and initializer argument.
- Original/default behavior: nil by default; existing callers and old persisted JSON decode unchanged.
- Pureline caller: `PurelineBoundedFlowSink` and the opt-in streaming upload path.
- Likely merge conflict risk: low; one additive model property.

## `Sources/HTTrailCore/Proxy/ProxyServer.swift`

- Exact reason: a constrained Network Extension needs opt-in request streaming, bounded response inspection, and runtime observability.
- Generic hook/change: opt-in request caps/streaming, response inspection/observation closures, runtime event callback, and an optional bounded upstream HTTP/1.1 pool configuration.
- Original/default behavior: request streaming remains off, inspectors/callback remain nil, capture cap remains 10 MiB, and upstream verification remains false unless a caller opts in.
- Pureline caller: `PacketTunnelProvider` and `ImageFilterProxyBridge`.
- Likely merge conflict risk: medium; additive configuration at the main proxy construction seam.

## `Sources/HTTrailCore/Proxy/ProxyHandlers.swift`

- Exact reason: carry the generic server options into plain HTTP, MITM, and blind-tunnel paths.
- Generic hook/change: constructor plumbing plus a blind-tunnel failure event.
- Original/default behavior: all new arguments default to the prior behavior.
- Pureline caller: options installed by `PacketTunnelProvider`.
- Likely merge conflict risk: medium; CONNECT pipeline construction is an upstream hotspot, but behavior changes only when hooks are installed.

## `Sources/HTTrailCore/Proxy/DecryptedProxyHandler.swift`

- Exact reason: avoid retaining complete ordinary uploads and enforce a bounded body-inspection fallback.
- Generic hook/change: opt-in chunked request forwarding with backpressure, bounded preview capture, bounded body-rule inspection, failure/timing events, and pooled-channel checkout for eligible ordinary responses.
- Original/default behavior: the existing buffered request path is used when `streamRequestBodies == false`.
- Pureline caller: `PacketTunnelProvider` enables the option with Pureline limits.
- Likely merge conflict risk: medium-high; this is the only substantial upstream seam because request streaming must live in the NIO data path. It is feature-gated and leaves the original path intact.

## `Sources/HTTrailCore/Proxy/StreamingProxyHandler.swift`

- Exact reason: inspect candidate images without unbounded response buffering while retaining transparent fallback.
- Generic hook/change: optional bounded streaming-response inspector/observer, complete-response framing checks, benign TLS-peer-close classification, and safe return of reusable HTTP/1.1 channels. Unknown-length bodies that cross the cap flush held bytes and continue streaming unchanged.
- Original/default behavior: nil inspector preserves the original immediate streaming path.
- Pureline caller: `ImageFilterProxyBridge.configure(server:diagnostics:)`.
- Likely merge conflict risk: medium-high; response streaming is an upstream hotspot, though the new branch is opt-in.

## `Sources/HTTrailCore/Proxy/InterceptEngine.swift`

- Exact reason: restore TLS-incompatible hosts before listening, observe decisions, and skip body-only rules after a safe inspection cap is exceeded.
- Generic hook/change: Codable `PinnedHostInfo`, `PinningEvent`, restore API, generic expiring `CompatibilityBypassInfo`, body-inspection toggle, and `requiresBufferedRequest` query. Forced decryption remains authoritative.
- Original/default behavior: no restored entries or callbacks; existing `processRequest` still inspects the body exactly as before.
- Pureline caller: `PacketTunnelProvider`, `PurelineCompatibilityBypassStore`, and request streaming.
- Likely merge conflict risk: medium; additive pinning/request-rule seams around existing logic.

## `Sources/HTTrailCore/Proxy/ProxyRuntimeEvents.swift`

- Exact reason: distinguish operational upstream failures from ordinary origin HTTP statuses without product-specific logging in HTTrail.
- Generic hook/change: neutral event model and conservative error classifier, including pool, TCP/TLS/TTFB/total timing, timeout category, anti-bot, and benign TLS-close events.
- Original/default behavior: no effect without a callback.
- Pureline caller: `PacketTunnelProvider` maps events into bounded diagnostics.
- Likely merge conflict risk: low; new generic file.

## `Sources/HTTrailCore/Proxy/UpstreamConnectionPool.swift`

- Exact reason: fresh TCP/TLS setup for every page resource was a measured performance bottleneck.
- Generic hook/change: new neutral pool keyed by scheme/TLS + host + port, with per-origin/global limits, health checks, idle expiry, and explicit eviction.
- Original/default behavior: the pool is absent unless a caller sets `upstreamConnectionPoolConfiguration`; HTTrail therefore retains its prior behavior.
- Pureline caller: `PacketTunnelProvider` opts into 2 idle connections per origin, 8 globally, and 15 seconds idle TTL.
- Likely merge conflict risk: low; new file plus additive constructor plumbing in proxy hotspots.

## Upstream tests

- `Tests/HTTrailCoreTests/StreamingProxyTests.swift`: verifies full-byte large upload/download forwarding, bounded capture, oversized inspection bypass, and inspector fail-open.
- `Tests/HTTrailCoreTests/RulesAndConvertersTests.swift`: verifies restored bypass, expiry, force-decrypt, and unchanged HTTrail defaults.
- Merge conflict risk: low; focused additive tests.

# AI-Image-Classifier upstream modifications

No source file under `Vendor/AI-Image-Classifier` is modified. The submodule remains pinned at
`5291eedb9b46fa978e36ccec4f5504b017afe809`. Its original UI, local server, MobileCLIP pipeline,
NudeNet pipeline, diagnostics, and tests remain intact.

# Pureline-owned integration files

## New files

- `iosapp/PurelineIntegration/Diagnostics/PurelinePacketTunnelDiagnostics.swift`: bounded 400-event/512-KiB App Group ring buffer, lifecycle marker, sanitization, and unexpected-run detection. Depends on HTTrail `AppPaths` only.
- `iosapp/PurelineIntegration/Diagnostics/PurelineDiagnosticArchive.swift`: creates an exportable ZIP containing sanitized PacketTunnel events and summary without adding a dynamic framework.
- `iosapp/PurelineIntegration/Capture/PurelineBoundedFlowSink.swift`: 200-flow, 8-MiB aggregate body budget with 256-KiB request and 512-KiB response previews. Depends on HTTrail `FlowSink`, `Flow`, and `SharedFlowStore`.
- `iosapp/PurelineIntegration/TLS/PurelineCompatibilityBypassStore.swift`: persists host plus expiry in the App Group and prunes expired entries. Depends on generic HTTrail `PinnedHostInfo`.
- `iosapp/PurelineIntegration/FailOpen/PurelineRuntimePolicy.swift`: single source of resource limits and pass-through decisions. Uses public `os_proc_available_memory` only.
- `iosapp/ImageFilterIntegration/Core/PurelineFilterConfiguration.swift`: versioned Codable contract, built-in combined profile, semantic validation, hard ceilings, and SHA-256 revision identity shared with `ImageFilterCore`.
- `iosapp/PurelineIntegration/Configuration/*`: atomic App-Group store, active/last-good/revision/acknowledgement files, JSON document import/export, UI state, and bundled default.
- `iosapp/PurelineIntegration/ImageFiltering/PurelineInspectionAdmissionController.swift`: synchronous pre-buffer reservation plus bounded active/queued bytes and inference admission.
- `iosapp/PurelineIntegration/Compatibility/PurelineAntiBotCompatibilityStore.swift`: separate expiring anti-bot evidence store and conservative strong-challenge detector.

## Existing integration files modified

- `iosapp/PacketTunnel/PacketTunnelProvider.swift`: installs Pureline policy, restores bypasses before listener start, enables normal upstream certificate verification, connects bounded capture/diagnostics, and records lifecycle/settings/runtime events. Depends on HTTrail's generic server/engine seams.
- `iosapp/PacketTunnel/ImageFilterProxyBridge.swift`: selects plausible raster responses, enforces the image cap, installs the streaming inspector, and fails open. Depends on HTTrail's response-inspection seam and `ImageFilterCore` facade.
- `iosapp/ImageFilterIntegration/Core/DirectImageSafetyAnalyzer.swift`: extension-safe two-model adapter. It reuses vendor Vision detection, person cropping, `MobileCLIPService`, and `NudeNetService`, while applying Pureline's downstream combined policy and short-circuiting only after a definitive block.
- `iosapp/ImageFilterIntegration/Core/ExtensionSafeDiagnosticLogService.swift`: unchanged; remains the app-extension-safe implementation expected by vendor source compiled into `ImageFilterCore`.
- `iosapp/Sources/SetupView.swift`: exports the bounded PacketTunnel diagnostic ZIP.
- `iosapp/Sources/ImageFilterTabHostView.swift`: Pureline-owned configuration status/import/export/default controls above the untouched embedded vendor UI.
- `iosapp/RuntimeTests/IntegratedRuntimeTests.swift`: downstream tests for diagnostics, capture budgets, persistence, fail-open limits, model selection, lazy preparation, and full vendor-pipeline availability.
- `iosapp/project.yml`: compiles shared Pureline sources directly into the app/extension (avoiding another dynamic extension framework) and bundles both on-device model resources in PacketTunnel. Identifiers, entitlements, signing, profiles, and vendor targets are unchanged.

# Runtime policy summary

- Request preview: 256 KiB.
- Response preview: 512 KiB.
- Aggregate retained body budget: 8 MiB across 200 recent flows.
- Body-dependent request-rule inspection: 1 MiB, then original bytes stream unchanged.
- Image inspection: 4 MiB per image, one active inspection, two queued reservations, a 16-MiB hard aggregate ceiling, and one inference at a time by default.
- TLS compatibility bypass TTL: 24 hours, persisted with expiry and restored before listening.
- Upstream TLS: full verification enabled only by the Pureline PacketTunnel caller.
- Failure policy: classifier errors, oversized payloads, resource pressure, unsupported bounded inspection, capture limits, and diagnostic failures never truncate or block network payloads. TLS-incompatible hosts are blind-tunneled; force-decrypt remains authoritative.

# Pureline configuration architecture

- Schema: required, complete Codable JSON schema version 1. Missing fields, malformed JSON, unknown schema versions, invalid probabilities, impossible stage combinations, and unsafe resource values are rejected.
- Built-in file: `iosapp/PurelineIntegration/Configuration/PurelineDefaultFilterConfiguration.json`; the equivalent typed `.builtIn` value is the recovery fallback when bundle/App-Group files are unavailable.
- App Group location: `group.com.davidpovarsky.pureline` support directory, under `PurelineFilterConfiguration/`. `active.json`, `last-good.json`, `revision.json`, and `packet-tunnel-acknowledgement.json` are written atomically.
- Revision: every valid install increments a monotonic sequence and records the SHA-256 hash of sorted normalized JSON. PacketTunnel independently decodes, validates, and hash-checks the active file before swapping actor state, then writes an acknowledgement carrying the same revision/hash and apply timestamp.
- Hot apply: the existing 1.5-second shared sync loop applies threshold, stage, model-toggle, queue, and memory-policy changes without an app rebuild or VPN restart. Enabling is lazy. Disabling stops new calls immediately; already loaded vendor singleton memory is explicitly reported as unload-deferred rather than claimed as reclaimed.
- Recovery: invalid input never changes active or last-good. A missing/corrupt active file falls back to validated last-good, then the typed built-in default.
- Hard ceilings: 16 MiB/image, 16 MiB total reserved inspection bytes, 4096 pixels maximum dimension, 20 million pixels, 24 crops, concurrency 2, queue depth 8, and 512 MiB maximum configurable memory guard.

# Pureline filter policy

MobileCLIP2 classifies Vision-selected person/face/whole-image fallback crops as woman, man, uncertain, or not-person. NudeNet evaluates exposure classes on the normalized full image and, when enabled, sequentially on person crops. The downstream decision is a boolean OR: a configured MobileCLIP person-policy trigger or any configured NudeNet class threshold blocks.

The default MobileCLIP values come from `CrossPlatformImageFilter/config/default.toml`: woman 0.42, woman-over-man margin 0.10, face fallback 0.48, whole-image fallback 0.58, uncertain 0.90, and no-margin woman 0.70. NudeNet thresholds also come verbatim from that CrossPlatform combined policy.

This choice is deliberate because the vendor iOS `NudityFilterPolicy.swift` is a separate standard/strict UI policy and differs materially: exposed breast 0.45 vs 0.30, female/male genitalia 0.35 vs 0.30, anus 0.35 vs 0.30, buttocks 0.50 vs 0.35; its strict belly/armpit values are 0.90/0.95 vs CrossPlatform 0.75/disabled-at-1.01, and it does not include the combined profile's covered-class thresholds. These defaults are not silently merged.

`shortCircuitOnBlock=true` may skip later work after either model produces a definitive block because the final rule is OR. `false` runs all enabled stages for diagnostic comparison. Model preparation uses independent retryable single-flight tasks for MobileCLIP and NudeNet; concurrent callers await one task and failures reset to unloaded.

# Pureline networking

- Upstream reuse: PacketTunnel opts into persistent HTTP/1.1 reuse keyed strictly by TLS mode, host, and port. Only responses with complete framing and keep-alive semantics return to the pool. `Connection: close`, parser/TLS errors, inactive channels, handler failures, idle expiry, and capacity pressure discard/evict the channel. WebSockets and streaming uploads retain their dedicated paths. HTTP/2 is intentionally deferred until post-pool device measurements.
- Diagnostics: bounded events report pool hit/miss/eviction, TCP setup, TLS handshake, TTFB, total request time, HTTP protocol, and differentiated connect/TLS/read timeout categories without URL queries or credentials.
- Pinning: the 24-hour persistent certificate-pinning evidence store remains separate and is restored before listening.
- Anti-bot: a normal 403 remains an origin status. A temporary one-hour `antiBotIncompatible` bypass is created only for a 403 with at least two Cloudflare-specific header signals plus a known challenge-body marker. It is persisted separately from pinning, applies only to subsequent connections, and does not attempt to solve or circumvent a challenge. Forced decryption overrides both bypass classes.
- TLS closes: a complete framed response followed by `uncleanShutdown` is informational (`benignTLSPeerClose`); missing bytes against Content-Length remain a failed/truncated flow.
