# iPad Safari image-grid diagnosis — 2026-11-11

## User-reported failure (observed screenshots)
- WireGuard tunnel and remote model filtering confirmed by a single image that is unblurred without VPN and blurred only with VPN.
- Safari image searches and a shopping image grid display grey placeholders and broken-image icons while VPN is enabled.
- This is **not acceptable** and is **not evidence that all image decisions were blocks**.

## Server-side evidence (before patch)
- Image diagnostics captured **238 completed image classifications**, 207 **allow** and 31 **blur**, zero model-module failures.
- Per-minute: 17:49 UTC 114 images (53 seconds accumulated inference), 17:50 UTC 83 images (61.7 seconds accumulated inference), 17:51 UTC 35 images (26.5 seconds accumulated inference). The v1 image semaphore was **one in-flight AI analysis**, creating a likely head-of-line queue and possible browser timeouts.
- Blur actions were often triggered by `uncertain >= 0.90` from the MobileCLIP ONNX port. The ONNX version is not parity-tested against the iOS CoreML baseline; investigate false positives separately.
- Before the patch, `responseheaders` set `.stream=True` **for every non-image response**, including HTML, JavaScript, CSS and JSON. This may affect website compatibility but has not been established as the browser root cause.
- A Bing JPEG explicitly allowed by the model was **byte-for-byte SHA-identical** direct vs through the proxy, so there was no evidence of universal image-body corruption.

## Isolated v2 implementation (do not silently modify filtering rules)
- `pureline_addon_v2.py` keeps regular HTML, JavaScript, CSS and JSON bodies buffered (default mitmproxy behavior); still streams video/audio, SSE/NDJSON and larger non-image bodies.
- Buffers image responses for AI inspection, including octet-stream image headers detected conservatively from image magic bytes.
- Adds only aggregate, content-free transport metrics (counts of 4xx/5xx, image allow/blur/replace, transport errors) to `diagnostics/transport-summary.json`. No image content, hostnames, paths, URLs, cookies or credentials are logged.
- `pureline-v2.toml.example`: max parallel images 2 and max concurrent inference 2, vs 1 in v1. The systemd CPU quota increased from 120% to **150%** on two-vCPU Torah Social (MemoryMax remains 2G). Existing content policy and thresholds unchanged.

## Actual checks before deployment
- Five Python unittest cases passed, including image magic bytes, buffering HTML/JS/CSS/JSON, streaming media/event streams and privacy-conscious metrics.
- V2 staging via local HTTPS interception: HTML fetched correctly; approved Bing JPEG matched direct bytes exactly; previously blocked public Unsplash JPEG was returned blurred with valid JPEG bytes and HTTP 200.
- Four image requests concurrently, two no-person and two people images: all **HTTP 200**; two `allow` (~0.9/1.1 s) and two `blur` (~6.6 s); valid JPEG signatures.
- 2026-11-11 18:06 UTC: live `pureline-poc.service` switched to addon v2 and config v2, systemd restart confirmed running, `MemoryMax=2G`, `CPUQuota=150%`. Prior service file backed up at `/etc/systemd/system/pureline-poc.service.bak-20261111-qa`. No other services touched.

## Unverified, must test next
**Safari on the actual iPad has not yet been retested.** With VPN enabled, reload the same Google image search and the same shopping image grid in a new Safari private tab and compare with VPN off. Check images allowed, blurred, any broken icons, page load latency, and exact timings; then inspect aggregate transport counters and service journal if issues persist.

If images are still missing, do *not* relax filtering or assume the two-thread patch fixed it. Investigate upstream status failures, TLS / HTTP2 / QUIC / DNS behavior, 304/range and image response framing with a **time-limited, consented diagnostic** that never records private URLs or bodies.
