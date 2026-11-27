# Pureline completion and evidence index — 27 November 2026

## Delivery status and scope

The native proxy/local-filter repairs and bounded remote-runtime revisions are
implemented with versioned evidence. **Build 602 has passed signed archive,
IPA verification and Apple validation. Upload and TestFlight processing remain
pending.** Production activation and physical iPad acceptance remain open.

The published app source is
`d89d53106d5db87aaa4c9356c9114dbe76daa839`, on the integrated branch in
[draft PR #3](https://github.com/davidpovarsky/htrail/pull/3). The vendor remains
pinned to `5291eedb9b46fa978e36ccec4f5504b017afe809`. Subsequent diagnostic-observer
work is separate from the archived app inputs. Post-archive verification matched
129 repository Swift inputs to the app source, retained nine package pins and
matched four dSYM UUIDs to the signed binaries.

| Distribution evidence | Observed result |
| --- | --- |
| Full HTTrailiOS Release archive, including PacketTunnel | Signed archive passed; exit 0, 180.5 seconds |
| Exported build 602 IPA | 170,165,569 bytes; package/signature verification passed |
| IPA SHA256 | `c08dd6284f13270b5a786d1a01c56f2417cc59f30e0cfc917c42df3a817b9c48` |
| Apple validation | altool 27.0.5, exit 0, `VERIFY SUCCEEDED`, no errors |
| Upload and processing | Pending; validation is not delivery confirmation |

## Native repairs and model qualification

Bodyless GET/HEAD/empty POST requests now use the upstream pool when request
streaming is enabled. Actual uploads retain streaming. A separate upload bug
left client reads paused after completion: the negative control reproduced a
successful POST followed by a stalled GET on the same connection, and the fixed
handler passed that regression and a complete 2 MiB upload with bounded capture.

An optional generic response-disposition hook supports streaming, bounded
inspection and replacement before origin bytes. Socket controls cover cap
overflow, truncated/stalled origins, inspector failure, header replacement,
allowed-response reuse and true EOF-delimited bodies. An absent hook preserves
upstream behavior. Pureline's strict defaults use safe replacements; explicitly
saved/imported `failOpen` values remain supported and are not silently migrated.

The downstream path decodes directly into its raster budget, rejects unsupported
multi-frame images before model preparation, treats local SVG explicitly as
unsupported, and releases admission reservations on every terminal flow,
including failure without a response. OFF avoids model preparation and
inspection. No absolute Core ML prediction deadline or physical memory guarantee
is claimed.

The iOS 27 Vision failure was isolated using the same fixture after model
preparation: both bounded ImageIO and prior Core Image inputs failed automatic
Vision with an inference-context error; the bounded image succeeded with its
advertised CPU device. A downstream adapter now selects supported CPU devices
per stage on iOS 27+, preserving request revisions, observation mapping and face
expansion. Older OS versions delegate to the unchanged vendor detector. The
original repeated-inference smoke passed without changing its assertions.

This repair validates **ImageFilterCore's Direct VPN filtering pipeline**.
PacketTunnel calls that analyzer directly. Remote WireGuard and legacy remote
proxy forwarding intentionally use different paths. The embedded standalone
classifier UI/local server still uses the unchanged vendor services; its separate
inference path is not covered by this CPU-policy acceptance claim. A successful
archive does not establish every embedded UI path's runtime behavior.

The restored MobileCLIP2-S2 trace/FP16 package passed all ten original numerical
fixtures under the existing CPU_ONLY product policy: minimum cosine
0.9998859456 and maximum score difference 0.00084305. Original tolerances,
fixtures, thresholds and OR semantics were retained. The ALL-device negative
control still fails; it was not hidden by the verifier adapter. Both MobileCLIP
and NudeNet resources remain present. See the
[native report](NATIVE_PROXY_AND_IMAGE_FILTER_2026-11-27.md) and
[model qualification report](pureline-model-qualification-20261127/model-qualification-report.md).

## Remote runtime and evidence boundaries

The remote animation adapter inspects every composited displayed frame, with
explicit byte/frame/pixel limits and structural consistency checks. Original
animation bytes are allowed only after every inspected frame allows. Persistent
model processes provide bounded admission, real process-group cancellation,
kill/reap and recovery; cache and diagnostics stay outside the immutable package.

V6 closes a separate pre-worker gap: image bodies are bounded before buffering,
compressed output is bounded before accumulation, and one 18-second budget runs
from response headers through body acquisition, queueing, decoding, inference
and rewrite. It does not include DNS, connection establishment, TLS or the wait
for response headers. Known nonimages and uploads stream. Some early failures
refuse the image request; later decode/worker failures return a safe placeholder.
Neither path should release an uninspected original prefix.

The process-local transport adapter verifies the reviewed mitmproxy source pins;
it changes no installed vendor files or global body limit. The v6 manifest is
`runtime-candidate-20261127-header-bounded-v6.json`, SHA256
`a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d`.
See [HTTP input bounds](HTTP_INPUT_BOUNDS_2026-11-27.md) for the compatibility
consequences and source-upgrade contract.

| Evidence | Accepted scope |
| --- | --- |
| Native core: 29 distinct cases | 27 streaming/socket cases plus two retained WebSocket cases; staged reruns are not additional cases |
| Direct local runtime: 27 distinct cases | 25 unaffected passes, the repaired original smoke and one new Vision-policy assertion |
| V6 real-network controls: 26/26 | Actual mitmdump/socket lifecycle with a deterministic classifier subprocess |
| V6 process controls: 12/12 | Admission, remaining header budget, cancellation, kill/reap, recovery and overload |
| V6 HTTP/hook controls: 11/11 | Final-source response serialization and lifecycle behavior |
| V5 actual-model workload: 100/100 deliveries | 100 distinct frozen inputs, six clients, no timeout/overload; original hashes and three known classification mistakes retained |
| V5 enabled-cache controls: 12/12 | Per-worker persistent misses/hits, restart reuse and private diagnostics in an immutable package |
| Animation evidence | 26 decoder controls; actual models inspected all 38 Pangea frames, caught a blocked later frame and retained static controls |

The model workload, cache and animation receipts remain version-scoped to their
recorded sources; unchanged paths are reused rather than relabeled as new v6
quality runs. The independent holdout remains 236/240 correct, with TP121, TN115,
FP3 and FN1. Successful delivery is not perfect classification. Details are in
[runtime bounds](RUNTIME_BOUNDS_2026-11-27.md) and
[filter quality](FILTER_QUALITY_2026-11-27.md).

## Browser follow-up and open gates

The v6 browser run passed its first four rendered cases, then the public HTTPS
SVG produced a worker-failure result. Renderer and same-actual-model diagnostics
passed. A targeted browser follow-up on the unchanged v6 manifest subsequently
loaded the SVG in 1,918 ms with decoded SHA256
`211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95`.
Thus five distinct cases have successful evidence **across runs**; this is not one
clean 5/5 v6 run. The initial failure is retained, its cause remains unknown and
unreproduced, and observer input-hash wiring is being corrected separately
without changing the candidate. The earlier
[clean v5 browser run](BROWSER_BOUNDED_V5_2026-11-27.md) retains its own identity.

The 310-file v6 production package is staged, root-owned and read-only; it has
not been activated. Remaining gates are:

- Supported production service control: `service_not_allowed` remains; no access
  policy workaround was used. Preserve the [rollout/rollback plan](PRODUCTION_ROLLOUT_2026-11-27.md).
- Physical iPad availability and synchronized browsing/filtering, effective OFF
  configuration, reconnect, CA/network behavior, memory/termination evidence and
  soak. Simulator and Mac/Oracle transport results do not satisfy these gates.
- Confirmed upload and processing of the validated IPA before claiming
  TestFlight availability.
- The separate workflow-only commit `676d317039815f7b97131a35d96c3ab2c30701d7`
  remains preserved locally; OAuth workflow scope still blocks its publication.
- Saved workspace usage/net-spend caps remain unverified. The supported SDK
  environment-budget getter returned a permission denial because that feature
  is unavailable for the workspace; absent/default environment fields do not
  establish workspace caps. [Modal's budget documentation](https://modal.com/docs/guide/budgets)
  distinguishes these controls.

No universal interception, flawless classification, physical VPN success or
production deployment is inferred from the completed software and laboratory
checks above.
