# WireGuard Apple bridge build — 27 November 2026

## Result

The pinned upstream Go bridge compiled and linked for both **arm64 iOS device**
and **arm64 iOS Simulator**, using **Xcode 27.0 (27A266a)**, Apple SDK 27.0,
**Go 1.26.5**, and minimum iOS 17.0. This verifies the native library's build
integration; no VPN tunnel or traffic was started by this check.

| SDK | Archive bytes | SHA-256 | Linked Mach-O platform |
| --- | ---: | --- | --- |
| iphoneos | 3,663,008 | c3247ddae40eafdcc54558857e99cd8468812e59b1a25352fc5b0d7fef284273 | IOS |
| iphonesimulator | 3,663,008 | 8dd402e012d90aa8657f34b678a31bfd4db3ab9b83b2d0232e1f2ea1d3e241fc | IOSSIMULATOR |

Completed at 01:13:15 UTC on 27 November 2026. The two-platform build and
verification command finished successfully in approximately 31 seconds.

## Inputs and isolation

- WireGuard Apple submodule: 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1.
- Upstream module: golang.zx2c4.com/wireguard/apple.
- Upstream wireguard-go pin: v0.0.0-20230209153558-1e2c3e5a3c14.
- Unmodified upstream files are verified against SHA-256 values by the build
  script. Go module resolution uses the upstream go.sum and -mod=readonly.
- No vendor file, shared Go installation, Xcode selection, or machine network
  configuration was changed.
- The upstream Makefile does not map iphonesimulator to a Go platform. The
  downstream script uses GOOS=ios, GOARCH=arm64, and the appropriate clang
  target (arm64-apple-ios17.0 or arm64-apple-ios17.0-simulator).
- Upstream's goruntime-boottime-over-monotonic.diff changes Darwin timers to
  mach_continuous_time so suspended time counts. The script applies exactly
  those three symbol changes to a private APFS copy-on-write Go runtime overlay.
  It checks the expected original symbols before writing. It never patches the
  installed toolchain or silently omits the upstream timer behavior.

## Reproduction

Run on the configured Apple runner:

    python3 scripts/build_wireguard_bridge.py \
      --source-root "$PWD" \
      --go /Users/m1/toolchains/go1.26.5/bin/go \
      --platform both \
      --minimum-ios 17.0 \
      --output-root /Users/m1/caches/DerivedData/pureline-wireguard-20261127/WireGuard

For an Xcode prebuild action, select the current SDK with
--platform "$PLATFORM_NAME" and pass the project's deployment target using
--minimum-ios "$IPHONEOS_DEPLOYMENT_TARGET".

Archives are written to:

    <output-root>/iphoneos/libwg-go.a
    <output-root>/iphonesimulator/libwg-go.a

Each directory also contains build-receipt.json, build.log, link.log,
link-platform.txt, and the generated C header. Point LIBRARY_SEARCH_PATHS
at <output-root>/$(PLATFORM_NAME) and retain the official WireGuardKit
module/header wiring.

The script uses one build lock and reuses an artifact only when source,
runtime overlay, SDK, compiler target, script identity, archive checksum, and
link-check checksum match the existing successful receipt.

## Verification performed

1. Actual Go c-archive compilation against each installed Apple SDK.
2. lipo -archs: exactly arm64.
3. nm -gU: all eight upstream bridge exports exist.
4. A C program calling wgVersion() linked against the real archive using
   the SDK's clang, Foundation, Security, and resolv.
5. vtool -show-build: the linked programs identify IOS and IOSSIMULATOR
   respectively, both with minimum OS 17.0 and SDK 27.0.

A successful Simulator build does **not** imply an operational iOS packet
tunnel. Network Extension packet-tunnel providers cannot run inside iOS
Simulator. Physical-device tunnel lifecycle and cross-app filtering require
separate evidence.

## Asset search

The older Build 601 and associated QA run currently expose no downloadable
GitHub artifacts, and the htrail Actions cache list is empty. The inspected
Windows checkout's old CI directories retain conversion-verification JSON
files but no generated MobileCLIP CoreML package. Oracle's known remote
research artifacts are ONNX assets, not the required CoreML package.
No model conversion was started as part of this bridge work.
