# Pureline image-filter quality and presentation — 2026-11-27

## Outcome and scope

The frozen classifier passed the requested 90% threshold on **both** sides of an independent 240-image holdout: 121 of 122 expected blocks were blocked, and 115 of 118 expected allows were allowed. Overall accuracy was 236/240 (98.33%). Four known errors remain and are recorded below.

These numbers measure the configured project policy on public portraits and biographical photographs. They do not establish universal Internet accuracy, complete video/animation coverage, or filtering across arbitrary iOS apps. Native VPN and third-party app acceptance require a physical device. Browser delivery and image presentation are separate checks described here and in [browser verification](BROWSER_WIREGUARD_2026-11-27.md) and [application verification](WIREGUARD_APP_2026-11-27.md).

The independent metrics come from [verification-report.json](../../tools/filter-quality/verification-report.json). The corpus, frozen receipts and errors are retained; no holdout image was removed after observing its prediction.

## Corpus and separation of calibration from evaluation

The original corpus contains 325 unique image originals from RandomUser portraits and Wikipedia photographs. Exact duplicates were removed, and the recorded source-group overlap between calibration and holdout is zero.

A composition audit reviewed all 142 Wikipedia fixtures before holdout inference. A biography subject label does not necessarily label every person, reflection or partial person in the image. Six ambiguous compositions were excluded through the recorded audit, leaving 79 calibration originals and 240 holdout originals. The original manifest, excluded identifiers and hashes remain available. The audit receipt explicitly records `holdout_inference_seen: false` at 01:13:35 UTC.

Calibration and model/threshold selection preceded the frozen holdout run. The holdout was not repeatedly used as a tuning set. Later HTTP, SVG and blur-presentation fixes do not change the frozen raster classifier thresholds. The one curated Wikipedia UI asset rule is recorded separately and does not contribute to the holdout metric.

Sources: [composition audit](../../tools/filter-quality/composition-audit.json), [frozen candidate](../../tools/filter-quality/candidate-freeze.json), and [holdout receipt](../../tools/filter-quality/evidence/official-holdout-frozen-v1/receipt.json).

## Independent holdout results

| Measure | Count | Observed rate |
|---|---:|---:|
| Correct blocking / block recall | 121 / 122 | 99.18% |
| Correct allowance / specificity | 115 / 118 | 97.46% |
| Precision among blocked images | 121 / 124 | 97.58% |
| Overall accuracy | 236 / 240 | 98.33% |
| False allowances | 1 / 122 | 0.82% |
| False blocks | 3 / 118 | 2.54% |
| Processing errors | 0 / 240 | 0% |

Confusion counts are TP 121, FN 1, TN 115 and FP 3. The report gives Wilson 95% intervals of 95.50–99.86% for block recall and 92.79–99.13% for correct allowance. These intervals describe the sampled test outcomes; they do not remove the limitations of source selection or prove performance on every image category.

The audited 79-image calibration subset had TP 41, TN 38 and no errors. Its performance is not independent evidence of generalization.

### Preserved holdout errors

| Public fixture identifier | Expected | Observed | Recorded reason |
|---|---|---|---|
| randomuser-men-68 | Allow | Blur | Several uncertain person classifications |
| wikipedia-63005541 | Block | Allow | No configured blocking rule matched in an archival group image |
| wikipedia-14576147 | Allow | Blur | NudeNet false-positive genital detection, score 0.4026 against threshold 0.30 |
| wikipedia-6729501 | Allow | Blur | Uncertain person classification and NudeNet false-positive genital detection, score 0.3816 |

The group false negative remains present in the browser gallery. It was not replaced with an easier example or excluded after the prediction. The reasons above report model outputs, not factual claims about the depicted people or content.

## Model/runtime provenance

The classifier source is pinned to AI-Image-Classifier commit `5291eedb9b46fa978e36ccec4f5504b017afe809`. The downstream candidate verifies source and runtime dependency hashes before starting.

The measured route uses the official Apple MobileCLIP2-S2 ONNX image encoder and prompt embeddings, a correctly decoded official YOLOX person detector, NudeNet and the YuNet face fallback. It uses real CPU inference with mock models disabled. No GPU service or recurring compute purchase was activated.

The configured woman and face-fallback score thresholds are 0.20. Other shipped policy rules are retained. The manifest and downstream wrapper validate official model provenance. The dependency contract intentionally references the existing verified assets under `/srv/pureline-poc`; large model files are not committed to the application repository.

See [runtime contract](../../tools/filter-quality/runtime-contract.json), [candidate configuration](../../tools/filter-quality/candidate.toml) and [entry point](../../tools/filter-quality/downstream/pureline_addon_candidate.py).

## Supplemental size/format checks

An additional 81 cases passed: eight calibration portraits transformed into 64-, 96- and 128-pixel JPEG, PNG and WebP images (72 cases), plus nine object/nature controls. Results were 36 expected blocks and 45 expected allows, with no classification or processing errors.

These transforms are correlated observations derived from calibration material. They are not 81 additional independent holdout images, and no confidence interval is presented for them.

A byte/decode audit covered 403 recorded outputs: the raw 82 calibration rows, the 240 holdout rows and the 81 supplemental cases. All 202 pipeline replacements changed and decoded successfully; all 201 allow outcomes requested no replacement. The raw calibration rows include the later composition exclusions, which is why this audit denominator differs from the audited calibration count. This is a pipeline byte/decode audit, not serialization of 403 HTTP responses or an expanded accuracy benchmark. Actual HTTP representation preservation is covered separately by the nine-case serialization regression and browser receipts.

See [supplemental receipt](../../tools/filter-quality/evidence/supplemental-calibration-v1/receipt.json) and the per-run checks in verification-report.json.

## Defect found only through actual browser delivery

Offline inference and Pillow decoding initially passed while real browsers failed to decode some blocked responses. Both WebKit and Chromium reproduced the problem. The proxy assigned replacement `response.content` while the old `Content-Encoding` header was still present. Mitmproxy recompressed the replacement; removing that header afterward left compressed bytes described as a plain image and could leave an incorrect length.

The fix invalidates representation headers before assigning replacement content, in both normal-policy and failure-replacement paths. A focused test uses actual mitmproxy serialization for identity, gzip and Brotli across both replacement paths and unchanged allowed images: **9/9 passed**. Subsequent browser runs verified decoded images on the wire.

The portable candidate retains the V2 wrapper's MIME sniffing, streaming handling and aggregate counters. Deploying only the base HTTP add-on would omit those behaviors.

See [HTTP regression](../../tools/filter-quality/evidence/http-serialization-regression.json) and the before/after browser evidence.

## Strong blur on large images

The previous fixed 32-pixel Gaussian radius was relatively weak on images with dimensions around 1536 pixels. The downstream presentation stage now uses:

    radius = max(configured_radius, min(width, height) * 0.25)

This changes how an already-blocked image is presented, not its classification. Allowed raster bytes remain unchanged. Four high-resolution controls at 1024 and 1536 pixels passed their block/allow and decode/preservation checks. The coordinating assistant visually inspected the 1265×1536 blocked output; recognizable image detail is obscured.

The inspected output SHA-256 is `004d0e1d608e95404a9a21ab4313d7f6a1c9c28f56788be8a04d77dcba8cdcb5`. Those four controls are separate from the independent 240-image benchmark.

## Static SVG support and a narrow curated UI rule

Actual Wikipedia browsing exposed excessive blocking of ordinary SVG interface assets. The downstream adapter now renders supported static SVG in a bounded subprocess before running the unchanged raster classifier. It limits input size, tree depth/nodes, output dimensions, CPU/time, memory and file descriptors. External resources, arbitrary file reads, scripts, animation, foreign HTML, unsupported rendering constructs and unvalidated embedded images are rejected. It does not allow all SVGs or all images from a domain.

Ordinary supported SVGs classified as allowed preserve their original validated representation. Blocked SVGs return a filtered PNG. Compositing that requires normalization returns the exact inspected raster when allowed, so an uninspected original cannot be substituted after classification.

The first strict presentation suite contained 50 cases:

| Group | Initial result |
|---|---:|
| Public Wikipedia UI SVGs | 22 / 23 allowed correctly |
| Embedded calibration portraits | 8 / 8 correct |
| Large raster controls | 4 / 4 correct |
| Malformed / external-resource / size-limit cases | 15 / 15 rejected as intended |

The initial total was **49/50**, not 50/50. The remaining Wikipedia anniversary globe first hit a rendering boundary, then was a raw-model false positive after normalization. This failure remains visible in the original receipts.

The exact normalized 100×100 PNG was visually inspected by the coordinating and reviewing assistants. It is a public Wikipedia puzzle-globe logo, with no person or nudity. A curated policy rule permits only the normalized PNG with SHA-256:

    bb0e4b77e584215801290c003052a2aa2b0a760adcba1894a2fcddcbad9a8153

This is a content-specific policy exception, not an improvement in measured model accuracy. The browser receives that exact inspected PNG. A changed-pixel control produced a different digest and did not receive the exception. Five representative resource/HTML boundaries continued to reject. The resulting focused **7/7** gate passed.

Final response metadata records the served allow decision consistently and retains the original model action as `modelActionBeforeOverride`. Raw upstream diagnostic records taken before the curated rule can still show the original model false positive. The report does not describe assistant inspection as an end-user review.

See [approved asset manifest](../../tools/filter-quality/approved-ui-rasters.json), [initial 50-case receipt](../../tools/filter-quality/evidence/svg-presentation-validation.json), [focused 7-case receipt](../../tools/filter-quality/evidence/svg-normalization-validation.json) and [inspected public logo](../../tools/filter-quality/evidence/wikipedia-globe-inspected.png).

### Live-runtime acceptance

The combined candidate was installed only into the isolated WireGuard laboratory, retaining its existing lab keys and CA. The 1536-pixel blocked JPEG was verified through actual WireGuard as a decodable strong-blur PNG. A live embedded-SVG request then exposed a worker-timeout discrepancy despite the direct worker/offline pass; the browser acceptance run was held while that runtime difference was investigated.

The same live embedded-SVG request subsequently passed in 1.88 seconds after shared disk pressure eased. A metadata-only probe confirmed the exact 5,601-byte pre-filter input matched the source fixture. No model, deadline or rendering bound was changed.

The frozen runtime was then staged under /srv with all 13 pinned runtime files and 284 vendor files (24.8 MB) byte-verified. Final readiness verified the public globe's exact approved PNG, the embedded portrait's policy-blurred PNG, and the large blocked JPEG's strong-blur PNG through real WireGuard. The separately retained curated metadata check passed.

The complete application then passed all four UI tests: eight WebKit pages with 60/60 decoded image instances and four native URLSession images with zero failures. Original timeout evidence is retained; a successful run does not guarantee immunity from later shared-host resource contention. Public-page exceptions and a bounded pending thumbnail observation are recorded in the browser report. Offline SVG checks alone are not used as proof of a live request.

## Performance and operational state

In the 240-image CPU holdout, median processing time was 1.269 seconds, p95 was 2.211 seconds and p99 was 3.946 seconds. These are pipeline measurements, not complete page-load times over the network.

A bounded read of the combined lab process after SVG/large-image probes observed RSS 388,928 KiB and a high-water mark of 437,268 KiB. This is an observed point-in-time process measurement, not a claim that every concurrency scenario fits the production service's 2 GiB budget.

Production still uses the previous V2 service. SentinelX rejected service management with `service_not_allowed`; the assistant did not modify that policy or restart through another route. [Prepared rollout and rollback](PRODUCTION_ROLLOUT_2026-11-27.md) preserve the old service, key material and cache for recovery. A new versioned cache avoids reusing old V2 decisions after an eventual authorized promotion.

## Remaining acceptance boundaries

Physical iPhone/iPad testing is required for shared-keychain access, system VPN permission, the native packet-tunnel lifecycle, direct UDP, DNS/IPv6, reconnect and sleep/wake. Certificate-pinned third-party apps, cached content, animation/video and unsupported formats require separate coverage decisions and tests.

The 90% target is met for both classes in the stated holdout. Four errors remain in that set, and the evidence does not support a perfect-filtering or universal cross-app claim.
