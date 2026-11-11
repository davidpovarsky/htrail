# Pureline remote WireGuard image-filter experiment

**Status (2026-11-11):** Fully operational end-to-end in a Linux network namespace on the Torah Social host. Public/iPad connectivity is **not** verified: Oracle Cloud inbound UDP/51820 is blocked upstream of the host, and the instance principal has insufficient permission to change VNIC security rules. No changes were made to the current Pureline Build 601.

## Runtime architecture

Test iPad → WireGuard VPN → mitmproxy 12.2.3 (userspace WireGuard mode) → supported HTTPS MITM → this isolated Python addon → the existing `CrossPlatformImageFilter` ONNX pipeline from `davidpovarsky/AI-Image-Classifier` at commit `5291eedb9b46fa978e36ccec4f5504b017afe809` → image allow/blur/replace.

The addon recognizes misleading `application/octet-stream` image responses by JPEG/PNG/GIF/WebP/AVIF/HEIC signatures, does not inspect unrelated clear non-image streams, and reuses the existing model classification and policy stack. The existing upstream repository is not modified.

Host installation path: `/srv/pureline-poc`. Python 3.12 virtualenv with mitmproxy 12.2.3 and onnxruntime 1.27.0 (CPU). The unit `pureline-poc.service` is a separate service with MemoryMax=2G and CPUQuota=120%. `pureline-firewall.service` adds/removes host UDP/51820 rule. No existing Docker services were stopped.

Research models on server (none committed to this repository):
- MobileCLIP2-S2 ONNX visual encoder + precomputed text embeddings derived from the four original prompt groups. Origin: `RuteNL/MobileCLIP2-S2-OpenCLIP-ONNX` revision `5ee5cc157edb6159c20e8d72b14a1a59feea3310`.
- NudeNet320n: `deepghs/nudenet_onnx` revision `44956a0587943016350c7815f9e0dec089d45cae`.
- YOLOX nano people detector: model output [1,3549,85]; model hashes verified against a private on-server manifest.

**Model parity with the iOS Core ML and Apple Vision baseline is NOT established.** MobileCLIP2 research license restricts commercial use. The proxy is not a production privacy/security product.

## Test evidence

- Both models and the YOLOX person detector load through ONNX Runtime CPU; local doctor passes.
- Sample image with no people: ~180ms; ten-person photo: all models completed, blur decision in ~7.6 seconds.
- Local HTTPS interception of a JPEG mislabelled `application/octet-stream` yielded `x-local-image-filter: blur` and a rewritten JPEG.
- Isolated Linux WireGuard namespace: real encrypted handshake; HTTPS request to 1.1.1.1 returned 200; image from images.unsplash.com through the tunnel returned 200, `x-local-image-filter: blur`, uncached ~5.63 seconds.
- External UDP probe captured zero packets at the VM NIC. Oracle Cloud VCN/NSG/security-list rule still requires an authorized account to add inbound UDP/51820.

## Installation and security

Do not publish client `.conf` profiles, WireGuard private keys, mitmproxy CA private keys, screenshots, images, diagnostic bodies, model weights or `wg-profile/` to GitHub. The test client profile and public CA certificate are available separately as private artifacts. Trusting the CA permits this server to inspect sensitive HTTPS traffic. Use only on your own iPad with explicit trust; disable afterward. Certificate-pinned apps and some Apple traffic cannot be intercepted; not all images or applications are covered. IPv6 coverage unverified.

The supplied `pureline.toml.example` is for the research host. Correct deployment still requires model weights + expected manifest, validated environment, trusted CA and UDP/51820 cloud access. No secret files are included.

Stop the trial: `sudo systemctl stop pureline-poc.service pureline-firewall.service`. Disable restart: `sudo systemctl disable pureline-poc.service pureline-firewall.service`.

The smoke test script uses a **temporary network namespace** and existing client credentials on server disk, then cleans up; it does not change the host default route.
