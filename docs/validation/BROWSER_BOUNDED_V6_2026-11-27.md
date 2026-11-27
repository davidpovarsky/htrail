# Bounded v6 browser and transport validation — 27 November 2026

## Result and limits

The unchanged v6 candidate has successful rendered evidence for five distinct assets across runs: four raster/animation cases in the initial run, followed by the public HTTPS SVG in targeted diagnostic runs. **The initial five-asset run failed on the SVG. It is retained and is not relabeled as a clean 5/5 run.** The original worker failure remains unexplained and was not reproduced by the subsequent controlled checks.

This exercises Chromium through actual WireGuard encryption in the Mac userspace client and isolated Oracle server, carried over a framed UDP/SSH connection. It is not a physical iOS Network Extension test, public direct-UDP test, independent accuracy sample, whole-article latency test, or production rollout.

The frozen manifest is `runtime-candidate-20261127-header-bounded-v6.json`, SHA256 `a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d`. Its 20 runtime files and the unchanged SVG dependency tree were verified during immutable staging. The lab used two actual-model workers, eight queued requests, a 4 MiB body cap, and the unchanged 18-second header-based inspection budget. Its cache was disabled.

## Browser route and identity

Chromium 159.0.8154.6 / Playwright 1.65.1 used a fresh profile for every run. The explicit proxy was loopback TCP18530, followed by the existing wireguard-go userspace client, a private SSH carrier, and the Oracle candidate's loopback UDP18531 listener. A separate peer and CA were generated for this lab. No production key, global trust store, system proxy, firewall, or host route was changed by the browser experiment.

TLS verification remained enabled. Chromium's narrowly scoped CA-SPKI exception was:

`+WxkqBkmofeBCsyUjFYRhpUMdqyPeSnuzwtTA2fJRcY=`

The readiness record required the exact candidate manifest, current parent PID, two live warmed workers and header capacity10. The final harness also required valid pre/post WireGuard counter snapshots from the same client run. The original client health field `connected` is an integer counter, not a Boolean; the first harness's incorrect Boolean check is preserved in the failed receipt. Its raw traffic counters still establish transport progress, but the historical receipt itself was not edited to say PASS.

## Initial rendered run

| Asset | Observed result | Browser evidence |
| --- | --- | --- |
| Pangea GIF, 38 composited frames | Allow; original 316,480 bytes and source hash retained | Decoded200×160; three different rendered-frame hashes |
| Two-frame late-blocked GIF | Blur; static PNG replacement | Decoded128×128; three identical rendered captures |
| Static allowed JPEG | Allow; original5,276 bytes and source hash retained | Decoded128×128 |
| Static blocked JPEG | Blur;979-byte JPEG | Decoded128×128; output SHA256 `e207d17fcebf558e97358e0bae26474770e9c0c96b45fccb10b83e2790e73aec` |
| Public Wikisource SVG | Safe worker-failure placeholder | Decoded320×180 PNG; expected-original check failed |

The original SVG failure completed after7,249ms. It returned an intact safe placeholder, with no browser request failure, rather than the expected SVG. The existing worker IPC exposed only an outer `InspectionFailure`; its original exception class was discarded. No cause can be reconstructed from that receipt.

A preceding attempt did not launch Chromium because a previously available recoverable browser binary was absent. It ran zero fixtures. The exact matching headless-shell version was restored into the isolated v6 directory; that prelaunch failure is retained separately.

## Targeted investigation and final SVG observation

The cached public SVG was verified as16,160 bytes with SHA256:

`211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95`

A single renderer-only diagnostic passed in726.75ms with the same5-second renderer limit. A single actual-model worker request then allowed the same bytes in959.62ms after normal warmup. Both ran under the originally observed runtime identity/environment; they did not reproduce a HOME-related failure, and no such cause is claimed.

A subsequent targeted browser run allowed and rendered the original gzip-encoded SVG in1,918ms. A lab-only observer recorded the renderer's successful exit. Its initial parent-input observation missed the request because transparent-mode mitmproxy replaces `request.host` with the destination IP. That observer condition was corrected to `request.pretty_host`, and the worker independently records the exact renderer stdin hash. These are diagnostic changes outside the candidate manifest, with15 focused passthrough/redaction checks.

The final targeted run `chromium-v6-svg-input-identity-20261127` passed:

- Parent decoded input, renderer stdin, and browser decoded response all matched the same16,160-byte SHA256 above.
- The renderer exited0 in704.58ms.
- Chromium decoded410×430 pixels and displayed the original SVG; elapsed asset time was1,856ms.
- The original gzip representation was retained; encoded Content-Length was5,662.
- The response had action `allow`, reason `policy`, and no policy-exception header.
- Valid before/after WireGuard snapshots showed increased traffic and no client errors.

The final gallery has SHA256 `cfafc76dfe36621b42dfa6770332dd6239190a876c934ca10e98287fb3b07baa`, identical to the preceding SVG gallery that was visually inspected. The initial gallery was also inspected: the allowed controls were visible, both blocked controls were strongly blurred, and the SVG failure placeholder was visible.

These follow-ups resolve the current input/transport/render identity checks. They do not erase or explain the first worker failure, establish continuous reliability, or expand the number of distinct accuracy cases.

## Fresh process telemetry and cleanup

The v2 transport companion publishes a new PID/epoch at startup, flushes a stopped lifecycle on graceful shutdown, and records only bounded aggregate counts and error categories. Three successive candidate parents had distinct epochs; the last was PID1333134, epoch `8756ccda60b04b2bba4caf091500780f`. Its final snapshot counted two requests/two successful responses, a DNS query/response, and established client/server TLS without error categories. Intermediate counters are coalesced; readers must correlate the PID/epoch with the live process rather than treat an old timestamp alone as a health verdict.

The old production diagnostic file predated its production PID and therefore was not fresh iPad evidence. The new companion's six focused regression checks and actual lab lifecycle observations are separate from any physical-device diagnosis.

All processes created for this v6 browser lab were stopped gracefully. Oracle's final receipt records no remaining owned processes and closure of the lab's SSH control connection. Mac's proxy and relay stopped, with TCP/UDP18530–18532 free. The earlier lab and production process were still live at that cleanup checkpoint. Private profiles remain protected and are not committed.

## Evidence

All raw summaries, screenshots, staging/readiness facts, fixed-schema observer records, focused diagnostics and cleanup receipts are under:

[`tools/wireguard-lab/evidence/chromium-bounded-v6-20261127/`](../../tools/wireguard-lab/evidence/chromium-bounded-v6-20261127/)

The initial failed summary, the two successful targeted summaries, and the prelaunch failure retain their original run IDs and outcomes. The final harness is [browser_bounded_v6_validation.cjs](../../tools/wireguard-lab/browser_bounded_v6_validation.cjs); diagnostic observation is implemented by [lab_worker_observer.py](../../tools/wireguard-lab/lab_worker_observer.py) and its sibling launcher. The immutable candidate itself remains unchanged.
