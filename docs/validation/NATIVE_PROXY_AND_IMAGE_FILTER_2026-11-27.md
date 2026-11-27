# Native proxy and image filter validation — 2026-11-27

## Scope and source identity

This report covers the **local HTTrail/Core ML path**. It does not certify the
remote WireGuard/Oracle worker, production deployment, physical iPad browsing,
or Network Extension memory stability.

- Repository: `davidpovarsky/htrail`.
- Isolated branch: `codex/pureline-native-completion-20261127`.
- Base: `f53ff65711af1b5f2552f44c5c24c8e5244a2cb0`.
- Independently validated generic proxy component:
  `dbf70afbe89f40dbd73ddf8b31a9c8c9b1b876d6`.
- Vendor pin, unchanged: `5291eedb9b46fa978e36ccec4f5504b017afe809`.
- Source hashes, commands, log hashes, and original receipt paths are in
  [the native core receipt bundle](native-completion-20261127/core-receipts.json).
  [The frozen source manifest](native-completion-20261127/frozen-source-manifest.json)
  identifies the exact accepted core and downstream files.
  The [runtime interim receipt bundle](native-completion-20261127/runtime-interim-receipts.json)
  preserves initial launch failures and the first actual 25/26 runtime result.
  The [Vision diagnostic report](native-completion-20261127/vision-input-diagnostic-report.md)
  and [machine-readable observations](native-completion-20261127/vision-input-diagnostic-receipts.json)
  retain the controlled backend comparison before the production repair.
  The [final runtime receipt bundle](native-completion-20261127/runtime-final-receipts.json)
  records the unchanged repeated-inference smoke and request-policy assertion.
- Implementation ownership was split from integration. Only the Apple build
  owner scheduled Mac checks; the final source was held unchanged during each
  check. No duplicate model benchmark or full unrelated test suite was run.

## Reproduced fixes

### Request streaming, pooling, and framing

`streamRequestBodies=true` previously sent bodyless GET/HEAD requests through the
dedicated upload connection, bypassing the configured upstream pool. The upload
route now requires a declared nonempty body or transfer encoding and excludes
WebSocket upgrades. Bodyless GET/HEAD/empty POST retain the ordinary pooled path;
large uploads still stream with bounded capture.

The upload path also left client `autoRead` disabled after request completion.
A test-only negative control reproduced a successful POST followed by a stalled
GET on the same client socket (`curl` exit 28). Restoring reads at both upload-end
transitions made that regression and the 2 MiB bounded-upload test pass.

Real local socket coverage includes HTTP GET/HEAD/POST, HTTPS GET/HEAD/GET against
an ephemeral certificate-authority fixture, WebSocket text/binary frames,
keep-alive, explicit origin close, pool hit/miss/reused events, and complete-body
capture. A separate raw-origin test covers true EOF-delimited responses without
either `Content-Length` or `Transfer-Encoding`, in streaming and inspected modes.

### Additive response disposition hook

`ProxyServer.streamingResponseDispositionPolicy` is an optional generic hook:

```swift
enum StreamingResponseDisposition {
    case stream
    case inspect(maximumBytes: Int, failureResponse: CapturedResponse? = nil)
    case respond(CapturedResponse)
}
```

It takes precedence over the older optional integer inspection policy. Leaving
the new hook nil preserves the existing HTTrail default and its explicit legacy
fail-open behavior. Pureline supplies the new hook through its downstream adapter.

A supplied fallback replaces the response before original bytes are forwarded
when the buffer cap is exceeded, the origin response is truncated/stalls, or the
inspector throws. Early replacements discard the unread origin connection;
fully consumed allowed responses remain eligible for reuse. HEAD replacements
emit headers without a body. The tests verify received bytes, not just a policy
return value.

## Local filtering behavior

The two models and their OR decision policy remain enabled in the default
configuration. Model thresholds, model files, the vendor checkout, bundle
identifiers, entitlements, and signing configuration were not changed by this lane.

| Condition | New built-in/default behavior |
| --- | --- |
| Direct filtering OFF or configuration disabled | Stream normally; reserve no inspection bytes and invoke no classifier. |
| Image over encoded-byte limit, insufficient memory, or full inspection admission queue | Return a safe SVG placeholder before origin bytes. |
| Unknown/chunked image length | Reserve the whole configured cap, then inspect within that cap. |
| Compressed/unsupported encoded image or partial `206` image | Apply the configured failure action; the default is a placeholder. |
| SVG MIME or `.svg`/`.svgz` path | Explicitly unsupported locally; replace at headers by default. SVG embedded images are not claimed as classified. |
| ImageIO reports more than one frame | Reject before model preparation; apply the unsupported-image failure policy. Frame zero cannot approve the remaining frames. |
| Model preparation or classification failure | Apply `modelUnavailable` or `classifierError`; the default is a placeholder. |
| Fully inspected allowed raster | Return the original complete body. |
| Model policy blocks | Return the generic SVG placeholder with `Cache-Control: no-store`; remove stale representation/range headers. |

All five failure actions and queue overflow now default to `block` in both the
typed configuration and bundled JSON. **An explicitly stored/imported `failOpen`
value remains supported.** Older `active.json` files are not silently migrated;
restoring/importing strict defaults is required to change such a configuration.
Diagnostic events identify configured fail-open decisions.

The generic inspection fallback is currently chosen from `imageTooLarge` and
also covers incomplete origin framing/idle failures. Mixed custom failure
actions do not provide independent transport-failure controls. Classifier and
model-preparation failures use their own downstream actions. All strict default
actions agree on replacement.

The default resource limits remain 4 MiB encoded image bytes, 2,048 pixels on the
longest side, 12 million total pixels, one active inspection, two queued
reservations, one inference at a time, and a 16 MiB hard reserved-byte ceiling.
These are admission/raster bounds, not proof of total Core ML resident memory.

## Decode and lifecycle changes

ImageIO creates a bounded, orientation-correct thumbnail directly from the
encoded source. The old `UIImage`/full Core Image raster followed by resizing was
removed. The returned raster is checked against dimension and area limits.

`PurelineCompletionFlowSink` releases request reservations on every terminal
completed/failed Flow, including upstream failures with no response. Previously
the response observer could not see that failure path. A released queued waiter
now resumes with `false`; lower runtime concurrency limits no longer promote
more inspections/inferences than the new limit permits. Filtering OFF is checked
again after waiting for inference admission.

The existing vendor MobileCLIP policy already selects `cpuOnly` on iOS 27 and later. A
focused assertion locks that policy to the qualified model path; this lane did
not change vendor compute units. The Apple owner separately verified numerical
parity of the exact restored FP16 package using that policy. Model preparation
remains lazy and retryable, and both models remain available.

### Vision inference-context compatibility

The first integrated smoke exposed a separate Vision failure on the installed
iOS 27 simulator. A one-shot diagnostic preserved the original fixture and
called the same two-model preparation first. Both the bounded ImageIO raster
and exact prior UIImage/Core Image raster were 942 × 2,048, 8-bit/32-bpp inputs;
their different color-space/alpha formats both failed automatic Vision with
`com.apple.Vision`, code 9, `Could not create inference context`. The bounded
image succeeded when the request used its advertised CPU compute device. This
control supports a compute-device cause rather than a decoder regression; no
speculative raster normalization was added.

`PurelineHumanDetectionService` is a downstream adapter for iOS 27 and later.
It creates the same human and face requests, keeps default request revisions,
`upperBodyOnly=false`, observation mapping, and face expansion unchanged, then
selects a supported CPU device for every advertised stage. Missing CPU support
throws into the configured classification-failure action. Older OS versions
delegate to the unchanged vendor service. The vendor UI, model files, model
thresholds, and vendor compute-unit choices remain unchanged.

The adapter uses Apple's public
[`supportedComputeStageDevices`](https://developer.apple.com/documentation/vision/vnrequest/supportedcomputestagedevices)
and [`setComputeDevice(_:for:)`](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:))
APIs, verified against the installed SDK. It does not use deprecated
`usesCPUOnly`. The original repeated-inference smoke and a new assertion for
both actual request factories passed as the acceptance checks for this repair. The
diagnostic's successful observation collection is not model acceptance or
physical-device performance evidence.

## Validation receipts

| Check | Result | Interpretation |
| --- | --- | --- |
| P-NATIVE-PROXY v1 | PASS: 20/20, exit 0 | 18 streaming tests plus two WebSocket tests. Superseded streaming coverage was rerun below. |
| P-NATIVE-UPLOAD negative control | Expected failure: one test, three assertions; curl 28 | Test-only addition on the old handler reproduced POST success followed by GET stall. |
| P-NATIVE-UPLOAD fixed | PASS: 2/2, exit 0 | Same-client POST→GET and 2 MiB complete upload with bounded capture. |
| P-NATIVE-STRICT | PASS: 26/26, 0 failures, 5.23 s, exit 0 | Includes cap, truncated/stalled origin, inspector error, replacement at headers, explicit stream, and allowed pooled inspection. Source hashes unchanged. |
| P-NATIVE-CLOSE-DELIMITED | PASS: 1/1, 0 failures, 0.064 s, exit 0 | True EOF-delimited origin in streaming/inspected modes; test-only extension, production code unchanged. |
| P-NATIVE-RUNTIME initial execution | 25/26 passed; one actual failure retained | Bounded decode/orientation, animation rejection, OFF, resource policy, reservation lifecycle and MobileCLIP CPU policy passed. Original repeated-inference smoke failed at the vendor Vision human-detection request; its repair is recorded below. |
| P-NATIVE-VISION diagnostic | Both default decoder controls failed; supported CPU succeeded | Same fixture and preceding model preparation. One observational test; not an acceptance substitute. |
| P-NATIVE-VISION-CPU repair | PASS: 2/2, 0 failures; build and test exit 0 | Unchanged original repeated-inference smoke plus the new human/face request-policy assertion. All four source/target hashes unchanged. Retain the 25 unaffected runtime passes. |
| PacketTunnel/app compile | PENDING | Runtime tests do not compile the extension bridge; the Apple owner verifies the full app/extension separately. |
| Source scope and whitespace | PASS | `git diff --check`; no vendor/model/lockfile/WireGuard/workflow/server changes in this lane. |

There are 29 distinct accepted core cases: 27 streaming cases and two retained
WebSocket cases. There are 27 distinct accepted runtime cases: 25 unaffected
passes from the initial run, the repaired original smoke, and one added request
policy assertion. Earlier stage counts overlap and must not be added as distinct
cases. The first strict-check
dispatch was interrupted by a 30-second orchestration timeout before compiler or
test results; its separate receipt is retained. The identical retry passed. That
interruption is not recorded as a product failure.

The first runtime attempts failed before any test method ran. Incremental ad hoc
simulator signing supplied the missing resource seal; explicit test language
`en` and region `US` resolved the remaining XCTest host launch failure. The
resulting 26-method run is retained separately from those launch attempts. Both
model resources loaded, and the MobileCLIP model smoke passed, before Vision
reported cancellation of `VNDetectHumanRectanglesRequest`. The integrated model
smoke subsequently passed with the same fixture and original assertion after
the downstream device policy was applied. The observational diagnostic was
retained as causal evidence and was not counted as an acceptance substitute.

The final simulator smoke prepared the models in 982 ms and completed its three
inferences in 1,190, 294, and 233 ms. Its footprint observations are retained in
the receipt as simulator measurements; they do not establish a physical
Network Extension memory ceiling or resolve the user's termination report.

## Remaining limits

There is no new absolute deadline or cancellation guarantee around Core ML
prediction. Upstream idle/framing fallback is distinct from a model inference
deadline. This work does not prove background/sleep-wake behavior or fix a
physical iPad termination diagnosis without `.ips`/Jetsam evidence.

The policy covers intercepted image responses. Browser cache/304, inline
`data:`/`blob:` images, images embedded in HTML, pinned TLS applications,
unintercepted traffic, QUIC/HTTP3, and IPv6 require the separate acceptance plan.
There is no claim of universal interception. The local runtime deliberately
replaces unsupported SVG/animated images under strict defaults; it does not
claim the remote worker's all-frame/SVG capabilities.

Forced decryption remains the user's intentional override. Existing pinning and
anti-bot expiry behavior was preserved; unit/socket checks do not certify the
named ChatGPT endpoints on the user's physical device.

## Asana closure recommendations

The source inventory contained **47 tasks: 19 completed and 28 open**, retrieved
at `2026-11-27T14:29:53.016Z` from project `1220424906877685`. The following table
is a recommendation against that inventory, not an Asana write. Root owns task
updates and must substitute the final receipts before closing conditional rows.

| Task ID | Outcome | Recommendation after final checks |
| --- | --- | --- |
| 1220424989463409 | Bodyless streaming bypasses pool | Close after integration/publication of the validated core commit: corrected code and final 27 streaming cases passed. |
| 1220424989508502 | Realistic streaming/pool/framing regression | Close after integration/publication: true close-delimited check passed in addition to HTTP/HTTPS/method/upload/reuse and two WebSocket cases. |
| 1220425375883024 | Focused regression and suitable QA | Close this automated repair pass only after runtime, extension compile, close-delimited check, and source review pass; physical QA stays separate. |
| 1220425375725708 | Upstream/vendor compatibility | Close after integration-document update and final diff review; hooks are generic/additive and vendor pin/source unchanged. |
| 1220424906966604 | Asana/PROJECT_BOARD source-of-truth sync | Root may close the dated synchronization pass once both are updated with final SHAs, receipts, and remaining gates. |
| 1220441940127638 | Signed build and TestFlight upload | Close only on signed archive/export, App Store validation, confirmed upload/build identity, and package/entitlement evidence from Apple owner. |
| 1220456803435813 | No browsing on physical iPad | Keep open: requires synchronized device reproduction, root cause, and successful IP/HTTP/HTTPS/user acceptance. |
| 1220425162643059 | Collect `.ips`/Jetsam report | Keep open: no physical system crash report was obtained by this lane. |
| 1220424906967724 | Branch map/merge plan and product gate | Keep integration gate open; candidate/source mapping does not satisfy physical merge/release acceptance. |
| 1220425375875174 | Direct filtering OFF acceptance | Keep open: automated no-model/no-reservation checks support it, but device effective-state/ACK/restart A/B requirements remain. |
| 1220425375688898 | Forced decrypt on pinned ChatGPT hosts | Keep open: preserve override; inspect actual user setting and validate named endpoints/WebSocket on device. |
| 1220441939759254 | Model termination root cause/fix | Keep open: bounded decode and lifecycle repairs do not prove the physical termination cause or remedy. |
| 1220425375557209 | No-AI browsing/protocol baseline | Keep open: local sockets are not the requested live-site/iPad rendering and protocol baseline. |
| 1220467012829839 | Representative accuracy and FP/FN | Keep open unless root's independent corpus and user acceptance satisfy all stated gates; local changes are not a new accuracy corpus. |
| 1220463839994749 | Original-byte/privacy/interception acceptance | Keep open: new socket safety cases pass, but cache/inline/pinning/QUIC/IPv6/CA and physical coverage remain separate. |
| 1220465992561672 | Modal billing/usage controls | Keep open absent current independent account/billing evidence; no GPU was started by this lane. |
| 1220461357904448 | Representative T4 end-to-end benchmark | Keep open: native CPU/Core ML checks cannot close a GPU/page-load benchmark. |
| 1220424906770661 | Physical model A/B and 30–60-minute soak | Keep open: requires the actual device, profile restarts, two-model stages, and soak evidence. |
| 1220465992561470 | Physical remote QA/load/stability | Keep open: device browsing, filtering, user acceptance and soak remain required. |
| 1220424989488981 | Host compatibility/bypass repair | Keep open: baseline without models and actual host-specific behavior remain unverified; do not infer anti-bot cause. |
| 1220441940126414 | Two models within extension memory budget | Keep open: physical high-water/termination evidence and architecture acceptance remain. |
| 1220424906593890 | Diagnostics and reproducible protocol | Keep open: terminal/resource diagnostics improved, but fresh correlated physical-device evidence remains missing. |
| 1220467013046239 | Restore Oracle→Modal path | Keep open: depends on browsing, cost, deadline, rollout and physical acceptance; native work is independent. |
| 1220461357710919 | Pipeline queue/deadline/cancellation | Keep open unless root separately proves the active remote path; local bounded admission is not an absolute Core ML deadline. |
| 1220470755711164 | Master/handoff | Keep open while critical gates remain; update current outcomes without erasing history. |
| 1220941302170999 | Latest integration/quality/deployment report | Keep open while production/physical gates remain; append final candidate evidence accurately. |
| 1220768772450481 | Main physical VPN browsing blocker | Keep open until device DNS/TLS/HTTP/QUIC acceptance is demonstrated. |
| 1220432453343477 | Pureline Remote iPad acceptance | Keep open until the user confirms working browsing/filtering with corresponding current server evidence. |

The broad user authorization allows implementation, validation, and release
work. It does not supply missing physical-device evidence or change connector
service/workflow permissions. None of those gates should be represented as
completed by this native report.
