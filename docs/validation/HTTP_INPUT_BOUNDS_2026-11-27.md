# Pureline v6: bounded HTTP input before image inspection

## Result and reason for the revision

V6 adds a verified input boundary before mitmproxy buffers image bodies, then carries one deadline from response headers through body acquisition and worker processing. The final manifest is [runtime-candidate-20261127-header-bounded-v6.json](../../tools/filter-quality/runtime-candidate-20261127-header-bounded-v6.json), SHA256 `a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d`, containing 20 runtime/contract files. The immutable v5 package, its manifest and its receipts remain historical evidence.

Review found a real gap in v5: the worker queue and byte checks happened only after the HTTP body had already been buffered, and `Response.content` could decompress that body without an output limit. Multiple slow/chunked responses or compressed expansion could therefore consume parent memory before reaching the worker controls. The v5 model, cache and post-body tests were valid within their stated scope; they did not prove this earlier boundary.

V6 preserves the classifier, model files, thresholds, animation adapter, SVG policy and worker persistence behavior. It changes HTTP acquisition, decoding, readiness and the worker's available time budget. All new tests described here are transport/control evidence, with zero new independent accuracy samples.

## Boundaries enforced

| Boundary | V6 behavior in the reference configuration |
|---|---|
| Raw image/ambiguous body | At most 4,194,304 bytes; checked before appending each data event |
| Bodies admitted at response headers | At most two worker slots plus eight queued slots, including bodies still downloading |
| Decoded HTTP content | At most 4,194,304 output bytes; gzip, deflate and Brotli use bounded decompression |
| Image deadline | 18 seconds from image/ambiguous response headers through body acquisition, queue, content decode, model inference and rewrite |
| Silent body stall | Core wakeup aborts the origin stream and refuses the client response without forwarding an original prefix |
| Image before model readiness | Refused at response headers; the worker pool is published only after every warm-up handshake succeeds |
| Upload bodies | Streamed with the public `requestheaders` seam; the filter does not retain or rewrite them |
| Known nonimage responses | Streamed; the global mitmproxy body limit is not changed |
| Client/flow failure | Header reservation released; an active worker is killed/reaped through the existing pool |

The deadline begins at response headers. DNS resolution, connection establishment, TLS negotiation and time to first response headers remain transport concerns and are not included in this deadline. The historical image request that waited more than 90 seconds still has no proven original root cause. A reproduced silent body stall after headers is now bounded by the new mechanism.

An image known to exceed the raw cap, an over-limit chunked image, or a body deadline receives a protocol-error refusal (502 in the HTTP/1 tests). Header overload and warm-up refusal kill the flow at the supported header-hook boundary. These paths can appear as a failed image request. Decode or worker failures after bounded acquisition return the existing valid no-store placeholder. Original image bytes never reach the client before an allow decision in the inspected path.

Ambiguous types, including a missing Content-Type or `application/octet-stream`, remain conservative image candidates until their bounded bytes can be sniffed. Consequently a large generic binary download with an ambiguous type is also capped. Properly identified nonimage responses, including HTML, CSS, JavaScript, SSE and document/media types, stream normally. This compatibility consequence is intentional and separate from the preservation of large uploads and known nonimage downloads.

## Why a pinned adapter is necessary

The installed mitmproxy 12.2.3 implementation has no public per-flow body-size limit. Its `body_size_limit` option applies to request and response bodies, including large uploads and nonimages. Setting `stream_large_bodies` would expose an image prefix before a verdict. A response streaming callback is synchronous and sends headers before the asynchronous response hook can classify and replace a body. Replacing `flow.response` in `responseheaders` does not stop origin buffering: the core later assigns the collected origin bytes to the response.

`downstream/http_body_bounds.py` therefore installs a process-local adapter at the reviewed `HttpStream`/`HttpLayer` methods. It reuses mitmproxy's existing protocol-error command pair and checks the image cap before the original receive buffer appends data. Request and known nonimage paths call the original implementation. It changes no installed vendor file and mutates no global proxy option.

The adapter verifies mitmproxy version 12.2.3 and exact SHA256 values for four installed source files: HTTP layer, generic layer, events and commands. A changed version or source raises a fatal startup rejection. The real negative control injects an incorrect expected pin only in a test addon; the process exits 78 and no unfiltered image is delivered. Deployment should also call `verify_transport_source()` during its pre-exec validation, alongside the existing classifier contract. This private API seam must be reviewed and its network controls rerun before upgrading mitmproxy. It is not an assumed compatibility promise for future releases.

Core wakeups normally retain their issuing stream in a command routing table until the timer fires. V6 substitutes weak routing only in the owning HTTP layer, preventing a completed image body from being retained until its old deadline. Outer CONNECT layers keep their normal routing. When the wakeup arrives, a dead weak reference is ignored; a live incomplete body is aborted. A wakeup queued while the asynchronous model hook runs is harmless after body completion; the worker separately receives only the remaining header budget. The HTTP and verified HTTPS CONNECT tests cover both active timeouts and completed-stream cleanup.

Content decoding reads `raw_content` and does not call the unbounded `Response.content` getter on an incoming image. Gzip and deflate use `decompressobj` with a remaining-output cap. Brotli 1.2.0 is drained through its bounded-output API; its C decoder can return a chunk larger than the requested buffer hint, so the code checks each chunk against the remaining budget before extending the accumulated output. Up to two content-encoding layers and up to 32 concatenated gzip members are accepted. Unsupported, malformed, truncated or over-limit encodings fail closed. Allowed compressed representations remain byte-identical on the wire.

## Validation and evidence reuse

The final [real-network receipt](../../tools/filter-quality/evidence/http-network-bounds.json) contains 26 passing controls against actual mitmdump and real loopback sockets. The classifier subprocess is deterministic for these controls, so HTTP lifecycle behavior is exercised without repeating model-quality measurements. The tests use a 0.8-second deadline to make timeout failures deterministic; deployment retains 18 seconds.

The controls verify warm-up refusal; unchanged gzip SVG, small/large Brotli and deflate representations; known/chunked/ambiguous oversize refusal; bounded gzip/Brotli expansion and malformed gzip replacement; a silent stalled body; a shared body-plus-worker deadline; ten header reservations; cleanup after body disconnect; actual worker termination after inspection disconnect; streamed 8,388,625-byte uploads with zero buffered request bytes; unchanged HTML of the same size; prompt SSE delivery; completed-image weak-reference cleanup; and fatal source-pin mismatch.

The completed-image control uses more than 3 MiB of response bytes and observes zero retained completed-image bytes and zero strong image-wakeup routes before the deadline fires. The silent-stall control observes the origin connection being closed. The HTTPS controls establish a real CONNECT tunnel and verify both the origin certificate and intercepted certificate against temporary, narrowly scoped test CAs. They check allow preservation, completed-stream cleanup and silent-body timeout. No system trust setting or production CA is changed.

The [HTTP regression](../../tools/filter-quality/evidence/runtime-http-bounds-v6-regression.json) passes 11/11 on final source. The [process regression](../../tools/filter-quality/evidence/process-bounds-v6-regression.json) passes 12/12, including the new remaining-header-budget case, expired-budget refusal without a spawn, kill/reap, recovery and bounded overload. The 100-at-once synthetic burst still completes ten and intentionally rejects 90; it is a safety control, not a successful 100-image page.

The earlier actual-model 100-distinct-image workload, all-frame animation controls and immutable enabled-cache test are reused for their unchanged paths and are identified by their original source hashes. The 100-image handler workload delivered 100/100 with no timeout/overload, about 830 MiB peak combined RSS, and the same three known classification mistakes in its subset. The 12-case cache probe established per-worker SQLite persistence and private diagnostics as the unprivileged deployment user. These results are recorded in [the v5 runtime report](RUNTIME_BOUNDS_2026-11-27.md), and are not relabeled as new full-network or model-accuracy tests of v6.

## Deployment contract and remaining gates

The versioned package keeps the 20 manifest files at their listed relative paths, plus the unchanged 284-file `.vendor-svg` bundle. Keep it root-owned and read-only with `PYTHONDONTWRITEBYTECODE=1`. Preserve the existing 2 GiB service ceiling and hardening. The two-worker cache suffixes and diagnostic subdirectories remain unchanged, outside the code package.

A lab-only readiness endpoint may read `ctx.master.addons.get("purelineverifiedfilter")`. Readiness requires a non-null, open `pool`, live worker processes and each worker's `ready_info`. The old base log message occurs before warm-up completes and is not readiness evidence. Readiness polling must have an explicit timeout and its own receipt before browser image acceptance begins.

Run the network check from a writable checkout using `/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_http_network_bounds.py`. It creates temporary loopback listeners, its own proxy process/configuration and temporary CA material, then closes the processes/listeners and removes the temporary directory. It starts no service, changes no global route, and records no raw image spool.

Production promotion, physical iPad acceptance, direct public-UDP behavior and broad website compatibility remain separate observed gates. Browser acceptance must use the immutable v6 manifest; the prior v5 browser result cannot establish behavior of changed runtime bytes. This report claims the bounded transport behaviors above, not universal end-to-end request latency or error-free classification.
