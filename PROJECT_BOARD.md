# Project Board

## Completion pass — 27 November 2026

Asana reconciliation was read back on 27 November 2026 at 17:00:53 UTC: **47 tasks, 24 completed and 23 open**, compared with 19 completed and 28 open at intake. Five tasks closed in this pass: connection pooling, realistic streaming/framing, focused QA, upstream compatibility and this documentation synchronization. All updated task notes preserved their previous history. Local CoreML, production HTTPS and physical-device acceptance remain separate.

- Archived/published app source: d89d53106d5db87aaa4c9356c9114dbe76daa839, on product base 09dfa21d5b27557e77d181d7aa31888d749aa91c. Later evidence and lab diagnostics do not change the compiled app inputs.
- Native: 29 distinct core cases and 27 distinct Direct local-runtime cases pass. Bodyless pooling, next-request progress, bounded inspection/decode, strict defaults, OFF bypass and terminal-flow cleanup are repaired. The iOS 27 Vision adapter uses advertised CPU devices and passed the unchanged original repeated-inference smoke. The embedded standalone classifier UI/server still uses the unchanged vendor service and has separate runtime acceptance.
- Remote runtime: v6 passed 26 actual-network controls, 12 process controls and 11 HTTP controls. Earlier 100-image actual-model workload and 12 enabled-cache checks retain their v5 identities. Browser v6 has successful evidence for five distinct assets across runs; its initial SVG worker failure remains unexplained. Exact-input follow-ups passed.
- Production: v6 activated through registered SentinelX service management at 16:46:43 UTC, PID 1405719. All 9 verified-HTTPS requests passed: both workers' allow/block misses and hits plus exact SVG. The existing 2 GiB/128-task limits and all 7 profile/CA files are unchanged; peak cgroup memory was about 893 MiB, with no OOM/limit event. This is not physical iPad VPN acceptance.
- Apple: full Pureline 1.0 (602), including PacketTunnel and both model resources, was signed, exported, verified, uploaded and processed VALID; internal state READY_FOR_BETA_TESTING. Source 129 Swift inputs and 4 dSYM UUIDs matched. Tester-group readback returned HTTP403, so installation access is not claimed.
- Model resources: all 10 original numerical fixtures passed CPU_ONLY with original tolerances and semantics; the failing ALL negative control is retained. Vendor and dependency pins are unchanged.
- Integration owner alone accepts evidence, updates this board, publishes and reconciles Asana. Draft PR #3 remains a reviewable integration branch.

### Gates still requiring evidence

Physical iPad access is absent; simulator and Mac tests do not close historical iPad browsing, extension memory, VPN, effective OFF, termination and cross-app gates. Workflow-only commit 676d317039815f7b97131a35d96c3ab2c30701d7 is preserved separately; its publication requires OAuth workflow scope. This does not negate the completed authorized Scaleway archive/upload. Modal saved usage/spend caps remain unverified; the supported budget getter returned a permission denial for an unavailable workspace feature. No GPU deployment or T4 benchmark was started. Development Heartbeat has no registered Pureline project; milestones are recorded in Asana without relabeling the run.

Detailed evidence is indexed in [the completion report](docs/validation/PURELINE_COMPLETION_2026-11-27.md), [the production rollout](docs/validation/PRODUCTION_ROLLOUT_2026-11-27.md) and [Asana](https://app.asana.com/1/1219597879016953/project/1220424906877685/task/1220941302170999).

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
- [x] Narrow v4 legacy Creative Commons SVG metadata compatibility fix: four targeted cases passed and the actual Wikisource SVG rendered in Chromium through WireGuard, without a new curated exception.
- [x] Independent frozen portrait/biographic-photo holdout: TP121 / FN1 / TN115 / FP3 across 240 images. Additional resized/format controls are reported separately and do not inflate that denominator.

Implementation starts at b66864a8f022e913b9fb099b77b7e6f34676275c; the branch history and validation documents record subsequent fixes.

## Remaining acceptance work

- [x] Production v6 promotion and same-process HTTPS/cache acceptance completed through registered service management; rollback remains available.
- [ ] Existing physical iPad P0: successful handshake with Safari failing to load remains unresolved by this lab. Read-only Mac preflight found no physical device; do not close this gate on simulator evidence.
- [ ] Physical iPhone/iPad: shared-keychain access, system VPN permission, actual Network Extension start/stop, direct UDP, sleep/wake, reconnect, DNS, and IPv6 coverage.
- [ ] Measure third-party apps, certificate pinning, caches, animation/video, and representative group scenes separately from the portrait benchmark.
- [ ] Keep the known archival-group false negative and three holdout false positives visible. Do not tune repeatedly on that holdout and continue calling it unseen.
- [x] Full 602 signed archive, IPA validation, upload and Apple processing completed through the existing authorized Apple workflow.
- [ ] Verify tester installation access and physical-device acceptance; uploaded/processed status alone does not establish either.

No universal or perfect-filtering claim is supported by the current evidence.
