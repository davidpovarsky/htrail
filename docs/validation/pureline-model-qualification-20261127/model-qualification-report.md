# Pureline CoreML conversion qualification — 2026-11-27

## Outcome

The production MobileCLIP2-S2 trace/float16/iOS 17 package is qualified for the existing iOS 27-and-later CPU_ONLY runtime policy. All 10 original numerical verification fixtures pass with the original thresholds. Both MobileCLIP2-S2 and the original NudeNet model remain present in the full app source resources. The remote-only project is not used as proof for these local-model tasks.

The original ALL-compute-units verification failed and remains preserved. The downstream adapter explicitly selects the existing product policy; it does not change the model, fixtures, tolerances, classifier thresholds, or OR decision semantics. No vendor source was changed.

## Numerical evidence

| Compute units | Samples | Minimum embedding cosine | Same top category | Maximum score difference | Outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| CPU_ONLY (product policy) | 10 | 0.9998859455775914 | 10/10 | 0.0008430468728841678 | Pass |
| CPU_AND_GPU (bounded diagnosis) | 10 | 0.9999508182614345 | 10/10 | 0.0006793133953771346 | Pass |
| ALL (original and adapter negative control) | 10 | 0.9662132062064158 | 10/10 | 0.02391627318066153 | Fail |

Unchanged numerical gates: minimum embedding cosine >=0.995; maximum score difference <=0.03; finite outputs; original normalization, softmax, and top-category checks. The adapter additionally requires all 10 fixtures and all 10 top-category matches. Default CPU_ONLY returns exit 0. Explicit ALL returns exit 1, proving that the wrapper does not silently turn the original failure into success.

## Exact provenance

- Vendor classifier commit: `5291eedb9b46fa978e36ccec4f5504b017afe809`.
- Downstream verifier adapter and prepare call-site commit: `0655d1d7e2e2998188adf2068da7743cfc449341`.
- Apple ml-mobileclip commit: `aecfb5453d022e9deff12f81a150ea8f35194baa`.
- open_clip commit: `54c9754a94baacac5b2d9b1c76318078d48912af`, with the pinned Apple inference-only patch and mobileclip2 overlay.
- Apple MobileCLIP2-S2 checkpoint revision: `72424e7025436db18f15c3eff6ee8c7c15ad4481`.
- Checkpoint SHA256: `37c2d839a856491f2fcc82c40dc28672dbd0907235b4cd4c38dfff6457f0c09f`.
- Original verifier SHA256: `e55600060d8aa63b8944b46fba24aa7f90064c582c90b6574bcb95c6a6703b09`.
- Original converter SHA256: `8ca2cf1416655a5d1698fb5a9138f5850242a9b813120fa7d6c1a79f2b52e03d`.
- Downstream adapter SHA256: `4c0198b820079746359e0299fcd43dedbace1c31e5e0a85ef43405152e8983f6`.
- Runtime MobileCLIPService source SHA256: `11a5aff0a8e4f0fd31610688c151d4dd9675e9356f42941a691a8c90a997c9ca`.

Only the production trace/float16/iOS 17 conversion was generated. Python 3.11 ran the vendor-pinned package versions: torch 2.8.0, torchvision 0.23.0, coremltools 9.0, numpy 2.0.2, pillow 11.3.0, huggingface_hub 0.34.4, open_clip_torch 3.2.0 and timm 1.0.19. The existing vendor runtime already restricts MobileCLIP to CPU_ONLY on iOS 27+ with reason `ios27MPSGraphSDPAWorkaround`.

## Qualified resources

The MobileCLIP encoder package has 71,735,075 bytes and tree SHA256 `d051afb7eeb6619fb1f510cd7bccf34e812f7e4f3d430c1e86d48591448bf78f`. Tree hashes use the original converter algorithm: sorted file relative paths followed by file bytes. Prompt embedding SHA256 is `8f411353a134d8c32fd9d6e309bc228481fce5b8dd46e867a864c0f4d139aedf`. Preserved NudeNet tree SHA256 is `573ea21255941b761dda7d0c61d213a46c7712027724d6dffb37d7cedca37292`.

The encoder, prompt embeddings, generated manifest, original conversion report and model license were copied only after qualification into the existing full-product Models directory. The converter report retains its original null verification field; the separate qualification receipt records the later successful explicit-policy verification. The original failed-ALL evidence is retained without overwriting it.

## Reproduction and adapter contract

Run the existing preparation script on a supported Mac with its pinned vendor submodule. Its verifier call now invokes `scripts/verify_image_filter_conversion.py --vendor-root <vendor> --compute-units CPU_ONLY --checkpoint <checkpoint> --models <converted-directory> --output <verification.json>`.

The adapter loads the original verifier and invokes its original main function. It supplies an explicit CoreML model-loading compute-unit option, verifies original verifier/converter SHA256 values, preserves the original exit verdict, and independently checks the fixture count and numerical gates. It does not duplicate or skip the fixture loop. The full contract was exercised against the same converted package for both passing CPU_ONLY and failing ALL.

## Acceptance limits and retained evidence

Numerical conversion parity is not an image-filter quality corpus or physical-device memory result. No physical iPad is connected to the current Mac, so direct physical PacketTunnel inference, jetsam behavior, VPN routing and device UX remain separate acceptance gates. Simulator/native validation and signed distribution receipts are recorded separately.

Machine-readable receipt: `model-qualification-receipts.json`. It contains all resource hashes, metrics, source pins, original evidence paths and SHA256 hashes. Original cache: `/Users/m1/caches/pureline-mobileclip2s2-72424e7`. Source build tree: `/Users/m1/builds/pureline-wireguard-app-20261127`. No signing credentials, private provisioning contents, tokens, or certificates are included.
