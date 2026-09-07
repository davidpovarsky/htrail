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
- Generic hook/change: opt-in request caps/streaming, response inspection closures, and runtime event callback.
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
- Generic hook/change: opt-in chunked request forwarding with backpressure, bounded preview capture, bounded body-rule inspection, and failure events.
- Original/default behavior: the existing buffered request path is used when `streamRequestBodies == false`.
- Pureline caller: `PacketTunnelProvider` enables the option with Pureline limits.
- Likely merge conflict risk: medium-high; this is the only substantial upstream seam because request streaming must live in the NIO data path. It is feature-gated and leaves the original path intact.

## `Sources/HTTrailCore/Proxy/StreamingProxyHandler.swift`

- Exact reason: inspect candidate images without unbounded response buffering while retaining transparent fallback.
- Generic hook/change: optional bounded streaming-response inspector. Unknown-length bodies that cross the cap flush held bytes and continue streaming unchanged.
- Original/default behavior: nil inspector preserves the original immediate streaming path.
- Pureline caller: `ImageFilterProxyBridge.configure(server:diagnostics:)`.
- Likely merge conflict risk: medium-high; response streaming is an upstream hotspot, though the new branch is opt-in.

## `Sources/HTTrailCore/Proxy/InterceptEngine.swift`

- Exact reason: restore TLS-incompatible hosts before listening, observe decisions, and skip body-only rules after a safe inspection cap is exceeded.
- Generic hook/change: Codable `PinnedHostInfo`, `PinningEvent`, restore API, body-inspection toggle, and `requiresBufferedRequest` query.
- Original/default behavior: no restored entries or callbacks; existing `processRequest` still inspects the body exactly as before.
- Pureline caller: `PacketTunnelProvider`, `PurelineCompatibilityBypassStore`, and request streaming.
- Likely merge conflict risk: medium; additive pinning/request-rule seams around existing logic.

## `Sources/HTTrailCore/Proxy/ProxyRuntimeEvents.swift`

- Exact reason: distinguish operational upstream failures from ordinary origin HTTP statuses without product-specific logging in HTTrail.
- Generic hook/change: neutral event model and conservative error classifier.
- Original/default behavior: no effect without a callback.
- Pureline caller: `PacketTunnelProvider` maps events into bounded diagnostics.
- Likely merge conflict risk: low; new generic file.

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

## Existing integration files modified

- `iosapp/PacketTunnel/PacketTunnelProvider.swift`: installs Pureline policy, restores bypasses before listener start, enables normal upstream certificate verification, connects bounded capture/diagnostics, and records lifecycle/settings/runtime events. Depends on HTTrail's generic server/engine seams.
- `iosapp/PacketTunnel/ImageFilterProxyBridge.swift`: selects plausible raster responses, enforces the image cap, installs the streaming inspector, and fails open. Depends on HTTrail's response-inspection seam and `ImageFilterCore` facade.
- `iosapp/ImageFilterIntegration/Core/DirectImageSafetyAnalyzer.swift`: extension-safe NudeNet-only adapter for the current block policy. MobileCLIP is not loaded by PacketTunnel. Depends on vendor `NudeNetService` and `NudityFilterPolicy` without modifying them.
- `iosapp/ImageFilterIntegration/Core/ExtensionSafeDiagnosticLogService.swift`: unchanged; remains the app-extension-safe implementation expected by vendor source compiled into `ImageFilterCore`.
- `iosapp/Sources/SetupView.swift`: exports the bounded PacketTunnel diagnostic ZIP.
- `iosapp/RuntimeTests/IntegratedRuntimeTests.swift`: downstream tests for diagnostics, capture budgets, persistence, fail-open limits, model selection, lazy preparation, and full vendor-pipeline availability.
- `iosapp/project.yml`: compiles shared Pureline sources directly into the app/extension (avoiding an extension framework), and removes MobileCLIP model resources from PacketTunnel only. Main-app resources, identifiers, entitlements, signing, profiles, and vendor targets are unchanged.

# Runtime policy summary

- Request preview: 256 KiB.
- Response preview: 512 KiB.
- Aggregate retained body budget: 8 MiB across 200 recent flows.
- Body-dependent request-rule inspection: 1 MiB, then original bytes stream unchanged.
- Image inspection: 4 MiB, one serialized NudeNet inference at a time.
- TLS compatibility bypass TTL: 24 hours, persisted with expiry and restored before listening.
- Upstream TLS: full verification enabled only by the Pureline PacketTunnel caller.
- Failure policy: classifier errors, oversized payloads, resource pressure, unsupported bounded inspection, capture limits, and diagnostic failures never truncate or block network payloads. TLS-incompatible hosts are blind-tunneled; force-decrypt remains authoritative.
