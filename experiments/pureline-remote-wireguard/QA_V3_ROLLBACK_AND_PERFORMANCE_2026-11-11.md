# Pureline remote V3 regression and rollback — 2026-11-11

## Real-device result

User retested the V3 proxy on an iPad with Passepartout connected to the Torah Social WireGuard tunnel. Result: websites/image-heavy pages became extremely slow or stalled; numerous apparently permitted photos were blurred; unusable for actual accuracy evaluation. This *overrules* all prior positive synthetic results. Do not redeploy V3 unchanged or claim the product works.

## Immediate action: production-safe rollback in experiment only

At ~20:25 UTC, restored `/etc/systemd/system/pureline-poc.service` from `/etc/systemd/system/pureline-poc.service.bak-20261111-before-v3`, `systemctl daemon-reload`, and restarted only `pureline-poc.service`. Verified active V2 with `pureline-v2.toml` and `pureline_addon_v2.py`; no recent warnings, zero restarts. Actual isolated WireGuard namespace test returned HTTPS 200, image HTTP 200; `x-local-image-filter: blur` on known male image, demonstrating that V2 is **also not an accurate general solution**. User should disconnect VPN while unusable. No other Torah Social services were changed.

## Quantitative evidence from V3 server diagnostic data (privacy-preserving aggregate analysis)

- 652 analyzed images, 440 allowed, **212 blurred** (32.5%). Extremely few cached: 2 hits / ~652 analyses (0.3%).
- MobileCLIP module accumulated 754.5 s / 652 images (1.157 s per analyzed image on average).
- Last 50: mean total analysis 1.488 s, p95 **10.795 s**, maximum 12.257 s.
- For V3 events: allow 440 with mean 461ms / p95 ~1.203s; blur 212 with mean 3.798s / p95 ~11.612s. Multiple-person images with up to 12 crops can require ~10 seconds. Burst queues lengthen end-to-end page latency beyond these per-image figures (queue waiting isn't included in totalDurationMs).
- Reasons for 212 blur decisions (reason log overlap): **54 had only 'uncertain' classification triggers**, 37 had both woman and uncertain, 115 had woman-only, other cases involved nudity rules. An automatic `uncertain>=0.90` rule is a possible false-positive contributor, but some ambiguous cases might be genuinely restricted; do not drop it without labeled QA.
- V3 lowered `woman_min_score` from default 0.42 to 0.20, after only **8 women, 8 men, 1 nature** curated samples. This threshold was inadequately validated for the user's broader site content and may over-blur.
- Source iPad screenshots/reports additionally indicate missed images and first-paint flashes on earlier versions; cannot claim that no unfiltered image reaches iPad (browser cache, pinned TLS, data URLs, unmatched image streams, HTTP3/QUIC).
- V3 diagnostics reported aggregate transport errors, but no proof they explain all page stalls.

## Independent dynamic INT8 compression trial — REJECTED

A **staging-only** dynamic QInt8 ONNX quantization was built from the exact official Apple MobileCLIP2-S2 image encoder using onnxruntime 1.27.0 on the two-vCPU Linux ARM64 host. Model size fell from 143 MB to 36.8 MB, but inference time **rose from ~0.63 s to ~1.42 s** per 256x256 image, and cosine similarity to original vectors on public fixtures was near zero or negative. Top classes disagreed on four of five fixtures, including misclassifying nature as woman. **Quantized model must NOT be deployed.** Models/fixtures are not committed in Git. Comparison log: `/srv/pureline-poc/official-candidate/bench-quant.log`.

## Next engineering criteria

1. **Performance gate first**, then real-world accuracy. On a representative image-grid request burst (e.g., 40–100 safe public photos across portraits, landscapes and groups), measure network success, body integrity, image latency p50/p95/p99 *including queue waits*, page-load time, CPU and per-module time. Avoid benchmarking 17 samples only.
2. Evaluate more efficient classification strategies on this CPU (without bypassing inspection or releasing original bytes before decision). Do not assume dynamic quantization is harmless; validate cosine, ranks, decisions and wall time. Batching/alternate small models require fresh accuracy validation.
3. Either provision adequate dedicated compute (the host is only **2 ARM64 vCPUs** and hosts unrelated services), or honestly communicate that filtering all images with two models plus person crops cannot remain low-latency on this host. Streaming uncategorized content without inspection violates user requirement; returning neutral placeholders on overload can preserve privacy but not UX.
4. Calibrate with a substantial **labeled, representative** corpus; record true positives, false positives, false negatives by relevant image types. Compare original threshold 0.42 vs experimental 0.20 and uncertain-only options; avoid anecdotal claims.
5. Continue to run TLS, WireGuard, page-compatibility and fail-closed/no-original-byte tests. App/extension concerns, certificate-pinned traffic and non-HTTP image data remain unresolved.
6. Keep live V2 active only for optional controlled testing; recommend disabling Passepartout for routine browsing. Do not represent any current version as production-ready.

No client secrets, browsing histories, image bytes, private URLs or user photos included in this report.
