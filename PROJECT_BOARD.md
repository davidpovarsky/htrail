# Project Board

This is a lightweight working-memory document. Detailed execution state is in [Asana](https://app.asana.com/1/1219597879016953/project/1220424906877685/task/1220941302170999) and the reports in docs/validation.

## Discoveries

- iOS Simulator does not run a Network Extension packet-tunnel VPN. Simulator UI and WebKit tests must remain separate from physical-device VPN acceptance. The 2026-11-27 laboratory uses genuine WireGuard encryption in a Mac userspace route, with an explicitly documented SSH/TCP carrier.
- The pinned WireGuard upstream manifest declares tools 5.3 while using platform constants introduced in 5.5. SDK 27 also needs an explicit sys/types.h import at the C module boundary. Packages/PurelineWireGuard provides these narrow overlays without modifying the submodule.
- In mitmproxy, assigning response.content while Content-Encoding is present may recompress new bytes. Remove invalid representation headers before assigning a rewritten image; otherwise browsers can receive a compressed body with plain-image headers and a wrong length.
- A classifier decision and a valid Pillow output do not establish browser delivery. Actual WebKit, URLSession, and Chromium decoding exposed the HTTP defect that the offline image audit missed.
- Fixed-pixel blur is relatively weak on high-resolution images. Presentation strength and classifier accuracy must be measured separately.

## Implemented on the WireGuard integration branch

- [x] Secure WireGuard profile parsing, shared-keychain references, remote-mode lifecycle, sanitized traffic statistics, and truthful simulator status.
- [x] Official Go C bridge builds for iOS device and simulator arm64, with pinned inputs and verified platform/link outputs.
- [x] Full Pureline Remote variant of the existing app, preserving the default local-model build while explicitly excluding local inference in Remote.
- [x] Actual device Release archive and Simulator Debug builds; full app installed and launched in its own iPad simulator.
- [x] Thirteen profile/state/statistics unit tests and post-HTTP-fix focused-host UI verification, with six WebKit pages (51 decoded image instances) and four native-client images.
- [x] Final full-app UI suite: four tests passed, eight WebKit pages with 60/60 decoded image instances and a 4/4 native URLSession client, against the frozen /srv filtering runtime.
- [x] Independent frozen portrait/biographic-photo holdout: TP121 / FN1 / TN115 / FP3 across 240 images. Additional resized/format controls are reported separately and do not inflate that denominator.

Implementation starts at b66864a8f022e913b9fb099b77b7e6f34676275c; the branch history and validation documents record subsequent fixes.

## Remaining acceptance work

- [ ] Production promotion: prepared configuration and rollback exist, but SentinelX service management returned service_not_allowed for pureline-poc. Enable the service capability through the operator; do not bypass policy with shell restarts.
- [ ] Existing physical iPad P0: successful handshake with Safari failing to load remains unresolved by this lab. Read-only Mac preflight found no physical device; do not close this gate on simulator evidence.
- [ ] Physical iPhone/iPad: shared-keychain access, system VPN permission, actual Network Extension start/stop, direct UDP, sleep/wake, reconnect, DNS, and IPv6 coverage.
- [ ] Measure third-party apps, certificate pinning, caches, animation/video, and representative group scenes separately from the portrait benchmark.
- [ ] Keep the known archival-group false negative and three holdout false positives visible. Do not tune repeatedly on that holdout and continue calling it unseen.
- [ ] Sign/export or distribute only through the existing authorized Apple workflow when that delivery is requested; current native build evidence alone is not a signed-device installation.

No universal or perfect-filtering claim is supported by the current evidence.
