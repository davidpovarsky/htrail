# Pureline bounded runtime and animation validation — 2026-11-27

## Result and scope

The v5 downstream candidate fixes the known animated-GIF format rejection and replaces uncancellable thread execution with a bounded pool of persistent model processes. The final animation controls passed 26/26, process controls passed 11/11, and actual mitmproxy response/hook controls passed 11/11. A real-model load delivered 100 distinct frozen-holdout images at six concurrent clients with no timeout or overload. The classifier's weights, thresholds, labels and approved UI exception remain unchanged.

This report records runtime implementation and isolated validation. It does not establish production promotion, physical iPad acceptance, direct public-UDP connectivity, or live-browser rendering. Those gates have separate owners and receipts. No production or old-lab process, service policy, credential, CA or network route was changed by this work.

The source is based on htrail `f53ff65711af1b5f2552f44c5c24c8e5244a2cb0`. The upstream classifier remains pinned to `5291eedb9b46fa978e36ccec4f5504b017afe809`; the existing contract checks 38 upstream source/default-configuration files. The final downstream identity is [runtime-candidate-20261127-bounded-v5.json](../../tools/filter-quality/runtime-candidate-20261127-bounded-v5.json), SHA256 `e9b4424cce6a376c9ac2620cf5b5ad0ac0680264e5653042dc29eb812b13711b`, containing 18 runtime/dependency-contract files.

## What changed

### Every animation frame is inspected

The old upstream decoder rejects the public Pangea GIF with `animatedImageNotInspected` when `animated_image_mode = "replace"`. The real-model probe reproduces that rejection before testing the new adapter. The original failure was a format policy boundary, not a classifier prediction about the geography image.

`animation_pipeline.py` now walks every composited displayed frame of GIF, APNG and animated WebP. Pillow applies frame disposal and compositing before the complete frame is passed through the existing classifier. Frames are never sampled. Identical PNG encodings of the composited pixels may reuse a result within that animation; changed pixels require another classification. The original animation bytes are returned only if every inspected frame allows and the decoded frame count agrees with the validated file structure or decoder metadata. A blocked frame returns a static blurred/replaced image immediately, so no remaining original animation is exposed.

The decoder has explicit limits: 128 displayed frames, 4,194,304 pixels per frame, 33,554,432 total decoded frame pixels, 4,194,304 input bytes in the reference configuration, and the configured processing deadline. A malformed, unsupported, incomplete or over-limit animation fails closed. A bounded GIF block parser requires valid subblock boundaries and an end trailer. PNG/APNG chunk validation checks control CRCs, frame declarations and frame-control counts before Pillow can label an image static. This catches a reproduced case where a false `acTL` count of one made Pillow report one frame while a second `fcTL` frame remained in the file. Separate APNG default images are also inspected because clients may display them.

The final real-model probe inspected all 38 distinct Pangea frames and allowed the unchanged original GIF in 8.720 seconds. A two-frame fixture with a safe first frame and a blocked portrait second frame became a valid static PNG in 1.124 seconds. Static allow and block controls retained their prior actions. Fixture source, hashes, dimensions, timing and construction are recorded in [animation-validation.json](../../tools/filter-quality/corpus/animation-validation.json); the image payloads are local test fixtures, not committed runtime data.

### Bounded work and real cancellation

The parent addon now loads settings and performs HTTP orchestration without loading its own model copies. `runtime_factory.py` builds the unchanged real-model pipeline inside `pipeline_worker.py`. The default pool contains two workers and permits eight additional admitted requests to wait. Queue admission is atomic on the event loop. Requests beyond the ten admitted slots receive a valid fail-closed `inspection-queue-full` replacement immediately.

One 18-second processing deadline covers waiting for a worker, worker startup if a replacement is needed, image decoding/rendering, model inference and the worker's rewrite. It starts after the full HTTP response body is available. It does **not** bound origin DNS resolution, TLS negotiation, response headers or body-download time. Therefore this change does not establish the original cause of the historical image request that waited more than 90 seconds, or prove that every network request completes within 18 seconds. The mitmproxy response lifecycle and streaming boundaries are documented in its [event reference](https://docs.mitmproxy.org/stable/api/events.html) and [streaming documentation](https://docs.mitmproxy.org/stable/overview/features/).

On timeout, client disconnect, flow error or worker failure, the pool kills the private process group and waits for the worker to exit. SVG renderer children share that group. A worker that has not exited after the bounded reap attempt remains attached to its slot; no over-capacity replacement is spawned. Cancellation during process creation retains ownership of the newly created process. The focused tests check operating-system process disappearance, including a descendant, and successful recovery on a subsequent request. They do not merely assert that an asyncio task returned a timeout.

The worker protocol uses length-prefixed bounded JSON and base64 over private pipes; it does not use pickle or persist image bodies to disk. The wire-message cap is 32 MiB and input bytes are checked again inside the worker. Error diagnostics use sanitized exception classes, without raw image content or URLs. Enabled SQLite caches get worker-specific filenames; enabled diagnostics get worker-specific directories. The immutable code package itself requires no writes.

### HTTP behavior remains usable and fails closed

Image and ambiguous responses remain buffered for inspection. Known nonimage responses, including HTML, CSS, JavaScript and SSE, stream. A request arriving before runtime initialization receives a valid `runtime-not-ready` replacement for a known or sniffed image. Timeout, queue-full and worker-failure replacements are generated from empty bytes, so the parent does not decode an expensive or malformed original a second time. Existing content-encoding cleanup and no-store serialization remain in place.

The candidate's disconnect and flow-error hooks cancel the tracked inspection task. Serialization controls use actual installed mitmproxy `Response` objects; they verify a gzip-encoded allow response preserves its representation, and that replacements decode with correct headers. These controls isolate HTTP/lifecycle behavior with a test worker and are separate from actual-model evidence.

## Evidence

All evidence paths below are relative to `tools/filter-quality/evidence/`.

| Receipt | Workload and result | Interpretation |
|---|---|---|
| [animated-format-regression.json](../../tools/filter-quality/evidence/animated-format-regression.json) | 26/26 controls, real image decoders with a deterministic visible-pixel policy | GIF/APNG/WebP frame coverage, compositing/disposal, false declarations, corruption, bounds and safe/static paths; zero accuracy samples |
| [process-bounds-regression.json](../../tools/filter-quality/evidence/process-bounds-regression.json) | 11/11 process controls | Bounded admission, queue deadline, kill/reap, descendant cancellation, crash/message-size recovery, startup/cancellation races |
| [runtime-http-bounds-regression.json](../../tools/filter-quality/evidence/runtime-http-bounds-regression.json) | 11/11 actual HTTP/hook controls | Startup fail-closed, ambiguous sniffing, gzip serialization, nonimage streaming, timeout and disconnect handling |
| [real-animation-workers2-final.json](../../tools/filter-quality/evidence/real-animation-workers2-final.json) | 4/4 real-model controls on final source | Pangea preserved, late blocked animation caught, static allow/block actions preserved; CPU providers verified |
| [real-load-workers2-100.json](../../tools/filter-quality/evidence/real-load-workers2-100.json) | 100/100 distinct-image delivery and prior-action parity; six concurrent clients; zero timeout/overload | Sustained handler load using frozen holdout images; includes known model mistakes |
| [real-static-png-final.json](../../tools/filter-quality/evidence/real-static-png-final.json) | 3/3 focused actual-model replay after the final PNG parser hardening | Covers every PNG from the prior 100-image load; unchanged JPEG path and earlier load measurements are reused |

The process burst control submits 100 synthetic tasks at once: two execute, eight wait, ten finish and 90 receive explicit capacity rejection. This proves bounded overload handling, not usable delivery of a 100-image page. A separate sustained synthetic control delivers 100/100, and the actual-model workload above independently delivers 100 distinct images through the actual HTTP response handler. Neither synthetic workload adds classifier-accuracy samples.

The process receipt predates only the addition of observational worker-readiness metadata (`ready_info`); the final HTTP and real-model receipts exercise the resulting process-pool source. The 100-image load predates the final PNG/GIF count-consistency hardening. Its workload contains 97 JPEGs, whose path is unchanged, and three PNGs, all replayed on final source. The final real animation probe covers the changed animation path. Receipt source hashes preserve these boundaries instead of relabeling earlier runs as tests of later bytes. The initial one-worker animation receipt is retained as historical evidence.

### Measured load and memory

| Measure | Two-worker, 100-image handler load |
|---|---:|
| Distinct input hashes | 100 |
| Successful delivery and frozen-action parity | 100 |
| Timeout or overload replacement | 0 |
| Concurrent clients | 6 |
| p50 image processing latency | 3,727.65 ms |
| p95 image processing latency | 6,805.74 ms |
| p99 image processing latency | 7,327.81 ms |
| Startup | 5,436 ms |
| Peak sampled parent-plus-worker RSS | 870,060,032 bytes, about 830 MiB |
| Peak individual worker RSS | 400,756,736 and 395,968,512 bytes |

The final two-worker animation probe peaked at 862,113,792 bytes combined RSS. These measurements support using two workers inside the existing 2 GiB deployment budget, but are not a cgroup `MemoryMax` enforcement test or a universal maximum for every input. The existing memory ceiling and service hardening must be retained. This lane did not change them.

The 100-image subset has TP51, TN46, FP2 and FN1 against the original frozen labels. The false positives are `randomuser-men-68` and `wikipedia-14576147`; the false negative is `wikipedia-63005541`. Thus 100/100 delivery/parity does not mean 100% classification accuracy. The existing full independent holdout remains TP121, TN115, FP3 and FN1: 236/240 correct, 99.180% block recall and 97.458% allow specificity. The [earlier quality report](FILTER_QUALITY_2026-11-27.md) remains the source of that accuracy claim. No holdout labels, thresholds or weights were changed and no additional independent accuracy samples are claimed.

## Reproduction and staged package

Run checks from a writable checkout through the approved Oracle environment. The real-model driver uses the retained, hash-verified quality corpus at `/mnt/development/projects/pureline-quality-20261127/experiments/pureline-quality-20261127/.data`. The Pangea fixture must be restored under `tools/filter-quality/results/animation/pangea.gif` and must match its recorded SHA256.

```bash
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_animated_images.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_process_bounds.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_runtime_http.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_runtime_real_models.py --workers 2 --report real-animation-workers2-final.json
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_runtime_real_models.py --workers 2 --samples 100 --clients 6 --skip-animation --report real-load-workers2-100.json
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_runtime_real_models.py --workers 2 --samples 100 --clients 3 --skip-animation --only-mime image/png --report real-static-png-final.json
```

The final candidate is staged at `/mnt/development/projects/pureline-v5-browser-lab-20261127/candidate-package-v5`. The directory contains the manifest's 18 files at their relative paths, the v5 and parent manifests, and the unchanged 284-file `.vendor-svg` bundle from the verified v4 package. The SVG tree digest is `ce9897ee6a521476838d69cff59d784025315243cc517c2a8c338858c99b8f4c`, computed from sorted relative-path-to-SHA256 JSON with compact separators. Files and directories are root-owned and read-only. Set `PYTHONDONTWRITEBYTECODE=1`; keep mutable cache/diagnostic settings in the operator's separate configuration. This staging operation copied files only and did not start a process.

The lab-local `v5-stage-receipt.json` records source/vendor identity and four exact fixture paths. Its `fixtures` entries can be mapped to the existing fixture-origin loader's `filename`, `content_type` and `sha256` keys. The same normal filtering response hook still inspects those bytes. A synthetic fixture origin proves controlled integration only; it is not evidence about availability or latency of the original public origin.

Remaining acceptance concerns include rendered animation playback, representative browser-page responsiveness, physical iPad behavior, origin-network stalls, service memory enforcement and authorized production promotion. They must be recorded from observed results rather than inferred from this runtime report.

## Follow-up: immutable package with enabled stores

The [enabled-cache receipt](../../tools/filter-quality/evidence/runtime-cache-enabled.json) records 12/12 real-model cases run as the deployment user `chatgpt-agent` (uid 1002) against the unchanged root-owned, read-only v5 package. Both workers produced initial misses and repeat hits for a known allow and a known blur. A new worker pool then returned SQLite-backed hits for both images in both slots. Blocked cache hits still produced decodable replacements.

The two stores were `decisions-20261127-bounded-v5.worker-0.sqlite3` and `decisions-20261127-bounded-v5.worker-1.sqlite3`, each containing exactly the two expected content hashes. No unsuffixed shared database was created. Each `diagnostics/worker-N` directory recorded six events, two fresh inspections and four hits. Checked cache/diagnostic JSON contained no populated URL, credential or image-byte fields; no fixture image payloads or image files appeared in the temporary stores.

All four test workers were killed/reaped on pool closure, the temporary stores were deleted, and the package's 304 files remained byte-identical without generated files. This verifies the read-only import/runtime arrangement with `PYTHONDONTWRITEBYTECODE=1`; mutable database/diagnostic parent directories must remain writable by the service user. The runtime source and v5 manifest were not changed by this check.

`check_runtime_cache.py` accepts explicit `--package`, `--fixtures`, `--work` and `--report` paths, and verifies the exact candidate manifest before testing. It must run unprivileged with `PYTHONDONTWRITEBYTECODE=1`. It reuses the two existing public portrait fixtures and adds no independent accuracy samples.
