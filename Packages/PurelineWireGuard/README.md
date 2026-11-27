# WireGuard manifest compatibility overlay

The upstream revision in Vendor/WireGuard declares Swift tools 5.3 while using macOS 12 and iOS 15 platform constants introduced in PackageDescription 5.5. This downstream manifest changes only the minimum tools API to 5.5. Sources are symlinked directly to the pinned, unmodified upstream submodule. The actual Go C archive is built by scripts/build_wireguard_bridge.py.

Apple SDK 27 requires an explicit sys/types.h import before the upstream kernel-control declarations. Our umbrella adds that import then includes the unmodified upstream header. Cryptographic implementation files are symlinks to upstream.
