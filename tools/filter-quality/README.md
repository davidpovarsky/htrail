# Pureline filtering quality and server candidate

This package contains the reproducible CPU benchmark, frozen public labels, raw receipts, and downstream server candidate for 2026-11-27. The classifier is pinned to `davidpovarsky/AI-Image-Classifier` commit `5291eedb9b46fa978e36ccec4f5504b017afe809`; `runtime-contract.json` verifies 38 Python/default-configuration files before runtime import.

## Results and scope

The untouched portrait holdout has **240 unique images: 122 required blocks and 118 required allows**. Results are TP121, TN115, FP3, FN1: **99.180% block recall and 97.458% allow specificity**. These are portrait/biographical-photo results, not a claim about every website, app, video, format, or identity. See [the detailed validation report](../../docs/validation/FILTER_QUALITY_2026-11-27.md) and `evidence/verification-report.json`.

The supplemental 81 cases passed, but contain transforms of only eight calibration portraits plus nine nonperson originals. They must not be added to the independent holdout count. All 202 recorded pipeline replacements were changed, decodable images; 201 allow outcomes had no pipeline replacement. HTTP serialization needed a separate repair, described below.

## Candidate entry point and dependencies

Use `downstream/pureline_addon_candidate.py` as the mitmproxy script, with `candidate.toml` as the model/policy reference. The entry point preserves the existing V2 MIME sniffing and aggregate transport counters. It adds the corrected official decoded YOLOX model, official MobileCLIP2-S2 embedding contract, face fallback, the HTTP encoding fix, bounded static SVG inspection, and size-relative blur. V6 retains all-frame GIF/APNG/WebP inspection and two bounded model workers, and starts the 18-second image deadline at response headers. It caps raw and decoded image bodies before worker admission, reserves at most ten downloading/processing images by default, and kills/reaps a worker on cancellation or timeout. HTML, CSS, JavaScript and other known nonimage responses stream while image responses wait for inspection. See [the v6 HTTP input report](../../docs/validation/HTTP_INPUT_BOUNDS_2026-11-27.md) and [the preserved v5 runtime evidence](../../docs/validation/RUNTIME_BOUNDS_2026-11-27.md). The separate production `transport_diagnostics_v1.py` script remains an operator-managed companion; this package does not replace it.

Existing assets remain at `/srv/pureline-poc/models`, with YuNet and the pinned OpenCV vendor under `/srv/pureline-poc/official-candidate`. `PURELINE_CLASSIFIER_SOURCE` and `PURELINE_RUNTIME_ROOT` can locate an equivalently verified installation; model paths in the deployment TOML must also be adjusted explicitly. No model download or GPU activation occurs during startup. Runtime source/configuration byte identity is pinned in `runtime-candidate-20261127-header-bounded-v6.json`; the preceding v3, v4 and v5 manifests remain preserved. These manifests record artifacts, not a production deployment or live-browser acceptance.

Install SVG-only dependencies into the versioned package using the approved backend account:

```bash
python3 tools/filter-quality/install_svg_dependencies.py --python /srv/pureline-poc/.venv/bin/python
```

This installs `requirements-svg.lock` into `.vendor-svg`, separate from the shared inference environment. The worker uses CairoSVG2.9.1, defused XML, existing system `libcairo.so.2`, and the pinned dependency versions recorded in `evidence/svg-dependencies.json`. Keep the whole package layout together when copying a versioned release: the SVG worker resolves its dependencies and reviewed raster registry relative to its own file.

The staged v6 package reuses all 284 previously verified `.vendor-svg` files unchanged; no dependency installation was performed for this revision. Preserve the service's existing 2 GiB memory ceiling and hardening. Keep the package read-only and set `PYTHONDONTWRITEBYTECODE=1`; run validation scripts only in a writable checkout. Workers exchange image bytes over bounded private pipes and do not spool them to disk. Enabled SQLite caches and diagnostic directories receive a worker-specific suffix/subdirectory to keep a single writer per store. The two-worker, 100-image handler load used about 830 MiB peak combined RSS; this is measured RSS, not a cgroup enforcement test.

Production configuration must preserve its existing confdir, CA/peer state, listen port, resource limits, streaming behavior and diagnostics. Use a **new versioned decision-cache filename**, preserving the previous cache for rollback and its size/TTL settings. The benchmark config intentionally disables cache and diagnostics; an operator must compose production paths/settings explicitly. Promotion and service management are separate authorized operations, outside this package.

## Focused checks

Run through the approved backend Python environment:

```bash
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_packaged_runtime.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_http_serialization.py
python3 tools/filter-quality/check_evidence.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_animated_images.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_process_bounds.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_runtime_http.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/check_http_network_bounds.py
```

The HTTP regression uses real mitmproxy `Response` encoding, with stub decisions solely to isolate serialization. Its nine cases are not classifier accuracy samples. SVG/presentation checks use real models and save separate receipts. Read historical failed receipts as historical evidence; later focused regressions document the exact correction.

The animation format controls (26), process controls (12), runtime HTTP controls (11), and real-network controls (26) are also control tests, not new accuracy samples. `check_runtime_real_models.py` records actual-model animation probes and a deterministic 100-image load drawn from the frozen holdout. Its success flag means delivery and prior-action parity, including known classification mistakes. It does not redefine the holdout labels. The 100-image run delivered every image without timeout or overload at six concurrent clients; p50/p95/p99 were 3.728/6.806/7.328 seconds. A separate 100-at-once synthetic burst intentionally rejected 90 requests and demonstrates bounded overload handling only. Exact commands, source hashes, and limits are in the runtime bounds report.

To replay the corpus on an equivalent approved host:

```bash
/srv/pureline-poc/.venv/bin/python tools/filter-quality/restore_corpus.py
/srv/pureline-poc/.venv/bin/python tools/filter-quality/restore_corpus.py --manifest tools/filter-quality/corpus/supplemental.json
/srv/pureline-poc/.venv/bin/python tools/filter-quality/run_quality.py --split holdout --variant official --name unique-replay-name
```

The restorer validates every public asset SHA and fails on changed/unavailable originals. It does not silently relabel or substitute images. The acquisition scripts document the original collection; do not rerun them to replace a frozen evaluated manifest. Existing Oracle data/results symlinks are local convenience paths and are ignored by Git.

## SVG policy and presentation

Supported static SVG is rendered in a bounded subprocess, then inspected by the unchanged raster models. Normal allowed SVG and ordinary raster images preserve their original representation. The worker rejects external resources, XML entities/DTDs, scripting/event handlers, foreignObject/HTML, animation, unsupported rendering features, unsafe CSS and resource-limit violations. Only validated bounded inline PNG/JPEG/WebP resources are accepted. The legacy Creative Commons metadata namespace is recognized under the same restrictions as current CC metadata. Its targeted real-model and rejection checks are recorded in `evidence/svg-legacy-metadata-validation.json`; no curated exception was added.

For the narrow `isolation` and `mix-blend-mode:multiply` normalization path, an allowed result returns the **exact PNG submitted to classification**, with `x-local-image-filter-presentation: rasterized_allow`. It never returns the uninspected original SVG when renderer semantics differ.

`approved-ui-rasters.json` contains one explicitly reviewed content-policy exception for the exact normalized Wikipedia25 globe PNG. The raw model remains a false positive on that asset: **22/23 SVG UI assets were allowed by the raw model**. The exception is separately labeled with `x-local-image-filter-policy-exception: wikipedia-enwiki-25`; it is not a model-accuracy improvement. Changed pixels cannot match its SHA256.

Blocked images use a Gaussian blur radius floor of `max(configured_radius, min(width,height)*0.25)`. Classifications remain unchanged. The wrapper adds only the variance needed above the existing32px blur and returns valid PNG for the stronger presentation. Large-image output hashes therefore differ from the original holdout rewrite receipts. V4 rejected animated GIF as an uninspected format. V5 allows an original animation only after every composited displayed frame allows, within explicit frame, byte, pixel and time bounds; any blocked frame produces a static safe replacement. This adds bounded format support, not a general animation or video accuracy claim. V6 starts the 18-second deadline at response headers and includes body acquisition plus processing. DNS, connection establishment, TLS and time to first headers remain transport concerns. Large ambiguous binary responses are conservatively capped; known nonimage responses and uploads stream. Prebuffer size/deadline refusal can be a protocol error, while bounded decode/worker failures return a placeholder. The private HTTP adapter pins mitmproxy 12.2.3 and exact installed source hashes; review and rerun its network controls before an upgrade.
