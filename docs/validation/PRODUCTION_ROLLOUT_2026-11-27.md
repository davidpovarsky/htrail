# Pureline production rollout — v6 activated and checked

## Outcome

The frozen v6 candidate was activated on Oracle on **27 November 2026 at 16:46:43 UTC** through the registered SentinelX service operation. The production process is PID **1405719**, replacing V2 PID 3542726. Its two model workers are 1405775 and 1405776. Nine sequential, certificate- and hostname-verified HTTPS checks passed in the actual production process, with **zero request retries**. The service remained active without an automatic restart or cgroup OOM/limit event.

This establishes production startup, same-process HTTPS filtering, representation integrity, both worker caches and the sampled resource envelope. It does **not** establish physical iPad WireGuard connectivity, Safari or third-party application acceptance, an extended soak, perfect classification or a resolution of the historical iPad browsing failure.

The earlier immutable v5 package remains on **HOLD**. Its independent review found pre-worker HTTP buffering/decompression and startup-readiness gaps. It was never activated. The successful v5 browser and workload evidence remains version-scoped; v6's new HTTP boundary controls are recorded separately.

## Candidate and configuration identities

| Item | Exact identity |
| --- | --- |
| Release directory | `/srv/pureline-poc/releases/20261127-wireguard-header-bounded-v6` |
| Runtime manifest | `runtime-candidate-20261127-header-bounded-v6.json` |
| Manifest SHA256 | `a6bbb87f9ea665e51ae4f964c843483626195f76caaa57358a76d94b270e641d` |
| Production configuration SHA256 | `8198c25521d3064a636215cf399a000dd4dd6030b91f463221d8ba609bc6d4eb` |
| Installed 90 drop-in SHA256 | `b96fd1c08f5974d8578d1e8f8cf5c4453c8f6653141c05cf6f29769641906727` |
| Transport companion SHA256 | `a0ee233586eae1628631b28e771dcaa081e5fcef1cf975f795dc4ddc858a69ad` |
| Transport epoch | `fab0b43a4106448fb975de9006b96c19` |
| Probe source SHA256 | `0fcab2dc78362fe4c8222bbe9595f09411e9098ebad21e30db89c9b40092554b` |

The release contains 310 root-owned, read-only files: the 20-file runtime contract, the 284-file isolated SVG dependency tree, four manifest generations, production configuration and transport companion. Existing official models, pinned classifier source and Python environment are reused at their validated paths. The corpus, lab-only hooks, lab keys and Git metadata are not deployed.

The production configuration uses two killable model workers and eight queued image requests, a 4 MiB representation limit and a single 18-second budget from response headers through acquisition, queueing, decode, inference and rewriting. DNS, connection establishment, TLS and time to response headers precede that budget. Known nonimages and uploads stream. The process-local transport adapter validates its reviewed mitmproxy source hashes and changes no installed vendor files.

A fresh versioned cache and diagnostic directory live outside the immutable release. Workers use separate SQLite files. URL, original-image and crop persistence are disabled.

## Authorization and service registration

The initial service-management attempt returned `service_not_allowed` because Pureline was absent from SentinelX's registered service map. The user's explicit instruction authorized completion and server administration. The documented operator-approved registration workflow was therefore completed:

1. Preserve the original policy and full unit/drop-ins in a protected root-only operations directory.
2. Use the structured, YAML-validated editor to add only `pureline-poc` with actions `status, restart, is-active, is-enabled`. An independent structural comparison confirmed all other configuration unchanged; the pre-existing unrestricted execution setting was not changed.
3. Restart the already registered SentinelX agent through its purpose-built operation. The brief disconnection was followed by capability and Pureline status readback.
4. Validate a complete merged unit preview with `systemd-analyze verify`, preserve the existing 81 drop-in, and install only `90-verified-candidate.conf`.
5. Reload the systemd manager using the existing authorized execution capability, confirm `NeedDaemonReload=no` and the exact effective command, then restart Pureline using **`sentinel_restart(service="pureline-poc")`**. The restart returned zero.

No raw Pureline service restart, alternate credential or replacement service alias was used. The private policy backup and individual private profile hashes are not committed. Sanitized registration, preflight and activation receipts accompany this report. The preview's old comment said “not installed”; the installed file has an accurate rollout comment. That comment-only difference explains the two drop-in hashes.

## Live startup and filtering acceptance

The probe first required the exact new parent PID and start identity, the expected source/config paths, ownership of the loopback listener, and two exact worker children. It observed both worker main threads waiting on their private stdin protocol after readiness; it did not read pipe contents, deploy a health endpoint or infer readiness from the early base startup log.

Both worker caches were empty before traffic. The only requests were the following nine, sent sequentially through `127.0.0.1:18530` using HTTPS CONNECT and the existing production CA:

| Requests | Expected and observed result |
| --- | --- |
| 1–4: allow, block, block, allow | Four cache misses, covering each public JPEG in each worker |
| 5–8: allow, block, block, allow | Four cache hits, two in each worker |
| 9: public Wikisource SVG | Cache miss; policy allow; exact decoded original bytes |

The allowed JPEG stayed byte-identical: 5,276 decoded bytes, SHA256 `d1a3e08d4e37d6ee2b7de1db8df87c1dc7acd8ffb004caaf980917de518a60c9`. Its gzip representation was 4,981 bytes and its decoded image was 128×128.

The blocked source hash was bound to the exact fresh cache entries in both workers. Each response was the expected decodable 128×128 blurred JPEG: **979 bytes**, SHA256 `e207d17fcebf558e97358e0bae26474770e9c0c96b45fccb10b83e2790e73aec`, with no Content-Encoding and `Cache-Control: no-store`. Exact output identity prevents an original-prefix-plus-replacement response from passing.

The SVG remained `image/svg+xml`, with 5,662 gzip bytes and 16,160 decoded bytes. Its SHA256 was `211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95`; the XML parsed as a 410×430 SVG. The response took 1,333 ms. It used the production models and renderer, with no curated exception.

JPEG miss latencies were 954–1,163 ms and hit latencies were 46–49 ms. These nine sequential checks are a smoke test, not a production throughput benchmark. All response status, filter reason, cache state, MIME, encoding, length and decoded identity assertions passed.

After the JPEG requests, both caches contained exactly the two public source hashes. The final SVG added one entry to worker 0. Diagnostics recorded five inspections and four hits, and the checks found no nonempty private URL/authorization/cookie/image fields or image spool files. This narrow check is not a general privacy certification.

Both worker PIDs and the parent identity remained unchanged. Transport counters persisted a lower bound of seven 2xx responses; the companion flushes on events and can lag the final response. The nine independently checked HTTP responses, common PID and common epoch establish this run's actual result. No extra request was sent just to flush counters.

## Resource limits and preserved deployment state

The original service user/group, working directory, read-write path, `PrivateTmp`, `ProtectHome`, `NoNewPrivileges`, **2 GiB MemoryMax** and **128 TasksMax** remain unchanged.

The 100 ms sampler observed a peak of 936,042,496 bytes, five processes and ten tasks including threads. The kernel's cgroup lifetime counters recorded 936,079,360 bytes (about 893 MiB) and twelve tasks. Readback showed zero OOM, OOM-kill, memory-max and pids-max events, no automatic service restart and an active/running service. This short observation is not a physical Network Extension memory measurement.

UDP **0.0.0.0:51820** and TCP **127.0.0.1:18530** are owned by PID 1405719. The additional proxy listener is loopback-only. All **seven existing WireGuard/CA profile files remained byte-identical**; their contents and private hashes were not published. No device key, CA trust, firewall or global routing change was needed.

## Rollback retained

Rollback was prepared before activation and was not needed. If a later verified regression requires it:

1. Remove only the newly installed `90-verified-candidate.conf`, retaining the base unit and `81-transport-diagnostics.conf`.
2. Reload the systemd manager through the permitted operation.
3. Restart `pureline-poc` through the registered service capability.
4. Verify the original V2 effective command, active state, expected sockets and unchanged profile identities.

The old V2 code/cache and protected unit backups remain available. Do not activate the held v5 package or weaken service limits as a substitute for diagnosis.

## Evidence and remaining gates

- [Frozen v6 stage receipt](../../deploy/pureline-wireguard-20261127/v6-staging-receipt.json)
- [Service registration](../../deploy/pureline-wireguard-20261127/service-registration-receipt.json)
- [Activation preflight](../../deploy/pureline-wireguard-20261127/activation-preflight.json)
- [Activation identity](../../deploy/pureline-wireguard-20261127/activation-start.json)
- [All nine production requests and resource measurements](../../deploy/pureline-wireguard-20261127/production-smoke-receipt.json)
- [Service, socket, hardening and profile postflight](../../deploy/pureline-wireguard-20261127/production-postflight.json)
- [Production configuration](../../deploy/pureline-wireguard-20261127/production.toml) and [installed drop-in](../../deploy/pureline-wireguard-20261127/90-verified-candidate.conf)
- [V6 HTTP input-boundary acceptance](HTTP_INPUT_BOUNDS_2026-11-27.md) and [browser evidence](BROWSER_BOUNDED_V6_2026-11-27.md)

The earlier v6 browser SVG worker failure remains recorded and unexplained; subsequent exact-input diagnostic runs and this production SVG request passed. The successful follow-ups do not erase that failure or prove a long-running reliability rate.

Physical iPhone/iPad acceptance still requires profile/keychain access, system VPN permission, actual Network Extension start/stop, direct UDP, DNS/IPv6, reconnect/sleep-wake, effective OFF configuration, representative apps, memory/termination evidence and soak. Those gates remain open.
