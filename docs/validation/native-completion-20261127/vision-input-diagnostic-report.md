# Pureline Vision input/backend diagnosis — 2026-11-27

The original integrated model smoke executed on the iOS 27 simulator and failed with `visionFailed`; the other 25 runtime tests passed. This diagnostic does not replace that failed acceptance check.

The diagnostic used the same fixture and prepared both resident models before Vision, matching the failed smoke. It made exactly three requests: the current bounded ImageIO image with default Vision compute selection; the exact prior UIImage/CI normalization and resize path with default selection; then one supported-stage CPU request on the bounded image, because both defaults failed.

| Input | Dimensions | Pixel format | Color space | Compute selection | Result |
| --- | --- | --- | --- | --- | --- |
| Bounded ImageIO | 942×2048 | 8 bits/component, 32 bits/pixel, alphaInfo 6 | sRGB | Default | Vision code 9: Could not create inference context |
| Prior UIImage/CI | 942×2048 | 8 bits/component, 32 bits/pixel, alphaInfo 1 | DeviceRGB | Default | Same Vision code 9 |
| Bounded ImageIO | 942×2048 | Same bounded format | sRGB | Advertised CPU for main stage | Success, 0 detections |

Both formats used 3,776 bytes per row. The request was `VNDetectHumanRectanglesRequest`, `upperBodyOnly=false`, orientation `.up`, with its unchanged default revision. The supported-stage API advertised GPU and CPU for `VNComputeStageMain`; the third request selected CPU through the documented `setComputeDevice(_:for:)` API. The deprecated `usesCPUOnly` property was not used.

These controlled observations support compute-backend incompatibility in this simulator rather than a newly introduced image-decoder regression. The diagnostic makes no claim about detector accuracy or physical-device inference. A downstream compatibility policy and a passing rerun of the unchanged original integrated smoke are still required before that acceptance gate can close.

Temporary diagnostic source SHA256: `8395e621009b6e1e286b25de73186997cf8b5150661a88901110a34b824407a3`. The one observational test completed; both build and execution exited 0. The temporary file was removed and Xcode project regenerated; all original source/project hashes were verified restored. No vendor, model, threshold, request revision, or production source changed during the diagnostic.

The machine-readable `vision-input-diagnostic-receipts.json` contains the exact commands, source hashes, observations, original failed-smoke receipt hash, and evidence hashes. `VisionComputeDeviceSDK27.txt` captures the installed ARM simulator SDK declarations used to implement the supported API.
