# Pureline Remote VPN V3 — Official model parity, detection fix, field QA

Date: 2026-11-11 UTC. Status: *deployed to trial server and smoke-tested; iPad field QA remains open*.

## Root cause

The on-server third-party YOLOX Nano ONNX had **raw**, undecoded [1,3549,85] head outputs. The pipeline's YoloXDecoder mistakenly assumed that cx/cy/width/height were already decoded pixel coordinates. For a 600x900 portrait, this yielded tiny ~0.2%-0.8%-wide boxes at the top-left rather than the actual person. MobileCLIP then classified near-empty crops as "uncertain" (~0.9), causing false positives and missed women. On one public portrait the old pipeline returned seven tiny people boxes; corrected YOLOX yields one plausibly located box.

Decoder contract (stride 8/16/32):
- xy = (raw_xy + grid_xy) * stride;
- wh = exp(raw_wh) * stride.
A diagnostic offline wrapper is preserved in `official-candidate/yolox_decode_diagnostic.py`. Live V3 **does not use that wrapper**: it uses a separately built model exported with `model.head.decode_in_inference = True`, verified on a public person image via CI.

## Verified official research models

1. **MobileCLIP2-S2 from Apple's original** `apple/MobileCLIP2-S2` checkpoint revision `72424e7025436db18f15c3eff6ee8c7c15ad4481`, SHA-256 `37c2d839a856491f2fcc82c40dc28672dbd0907235b4cd4c38dfff6457f0c09f`. Image ONNX and matching text prompt embeddings are exported together using the source repo's pinned pipeline. GitHub Actions `43083737160`: success, including 10/10 PyTorch-vs-ONNX parity samples. Model ONNX SHA-256 `f1502d3980e31bbb99fdf1f81e23598a6f4267ca4fc451f1a889eb709444996f`. Models are not tracked in Git.
2. **YOLOX Nano from Megvii official checkpoint** exported with correct onnx decoder. GitHub Actions `43086742558`: success, model SHA-256 `72d105dbb8e6b4b2e8f8b37127c4fa330ada5b40c08e7270de96a3eb96ed290d`; verified person boxes against a public sample.
3. Original **NudeNet320n** retained.
4. OpenCV **YuNet** `face_detection_yunet_2026may.onnx`, source OpenCV Zoo, sha256 `ebafce4e3c118d6554634be5c27ab333b4c047a9a8c3faf1d7cf93101c22f0f0`, is a **face fallback only when YOLOX fails to find a person**, mirroring the original Swift/Vision pipeline's expanded-face crop semantics. Tested on 2 female + 2 male portraits + nature (4 faces, 0 nature).

Model files remain under `/srv/pureline-poc/models`, and YuNet under `/srv/pureline-poc/official-candidate` on the private Linux test host. No model weights, samples, images, WireGuard profiles, keys or CA credentials are committed. **Apple MobileCLIP model license is research-only, not cleared for commercial distribution.**

## Candidate policy A/B

Original policy: `woman_min_score=0.42`, `face_fallback_woman_min_score=0.48`, `uncertain_min_score=0.90`. Keeping original policy with fixed detections: 7/8 public woman portraits blurred, 8/8 public male portraits allowed, one landscape allowed. One woman portrait had a significant `woman=0.2493` probability and escaped the original 0.42 threshold.

Experimental, explicit V3 research overlay changes **only** `woman_min_score=0.20` and `face_fallback_woman_min_score=0.20`, leaving other defaults unchanged. Result on small public set: 8/8 women blurred, 8/8 men allowed, landscape allowed; ~0.9 sec for each typical single-person 600 px portrait on the isolated staging process. **These 17 examples do not establish robust accuracy or false positive rates.** Further balanced, labeled benchmarking across real sites remains mandatory. A/B compared both models and found third-party RuteNL and official S2 yielded virtually identical scores on five images with the buggy detector: this eliminated model-version mismatch as the principal cause.

## Transport and actual WireGuard tests

The deployed `pureline-poc.service` uses:
- `pureline_addon_v3_candidate.py` (name on server), derived from `pureline_addon_v2.py`; the versioned `pureline_addon_v3.py` here is equivalent.
- `config/pureline-v3-official-trial.toml` (example in Git).
- `mitmdump --mode wireguard@51820` / `MemoryMax=2G` / `CPUQuota=150%`.
- Reserves existing proxy behavior: buffered image responses, existing streamed audio/video/SSE, fail_action=replace for eligible image errors, and additive aggregate metrics.

On staging proxy 127.0.0.1:18082: ordinary HTML 200; problematic woman photo returned HTTP 200, `x-local-image-filter: blur`, valid replacement JPEG (~1.34s); man photo returned HTTP 200, `x-local-image-filter: allow`, **byte-for-byte identical** original JPEG (~1.15s); nature HTTP 200 allow.

On **actual isolated Linux WireGuard namespace** against live V3: HTTPS 1.1.1.1 returned 200, man image HTTP 200 allow (~1.20s). A separate tunnel fetch for the formerly missed woman portrait returned `x-local-image-filter: blur`, valid JPEG, ~1.13s; filtered bytes differ from original. Live V3 service active, `NRestarts=0`, no recent journal warnings. Original V2 unit backed up at `/etc/systemd/system/pureline-poc.service.bak-20261111-before-v3`.

## Important limitations

- **User's physical iPad has not been retested after V3 deployment.** Reconnect Passepartout on home Wi-Fi, open new private Safari tab, revisit image grid to inspect any remaining omissions or first-paint flashes. Browser cache/previews, inline/data image content, unsupported TLS pinning, IPv6/QUIC and non-MITM paths can still bypass inspection. It is incorrect to claim that zero unscreened images ever reach the device.
- There is no ground-truth benchmark outside this tiny research set. Tuning to 0.20 was not validated broadly; verify false positives on families, illustrated people, small faces, photos of boys etc. Keep a record of failures using *only authorized, non-sensitive public test imagery*.
- All server image and TLS data are sensitive: do not log URLs, raw image bytes, browser history or credentials; the trial CA and WireGuard profile should be removed from the device when finished.
- No changes to the original source application, network security rules or unrelated Torah Social services.

## Revert the trial to V2

```bash
sudo cp -p /etc/systemd/system/pureline-poc.service.bak-20261111-before-v3 /etc/systemd/system/pureline-poc.service
sudo systemctl daemon-reload
sudo systemctl restart pureline-poc.service
sudo systemctl is-active pureline-poc.service
```

Use test/dev only. Protect server private keys, CA certificate private key, test image content, logged HTTPS payloads and personal navigation. Do not merge this proof-of-concept branch as production without license review and expanded QA.
