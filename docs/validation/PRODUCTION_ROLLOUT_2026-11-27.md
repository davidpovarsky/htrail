# Pureline filtering service rollout — prepared, not applied

## Observed state and management boundary

The production system service `pureline-poc.service` remains active on Oracle with the V2 configuration. At the preflight, its PID was 3542726, service user was `chatgpt-agent`, and its memory ceiling was 2 GiB. Its existing WireGuard listener is UDP 51820. No production service configuration, CA, peer configuration, firewall, global route, or live process was changed by this run.

SentinelX returned `service_not_allowed` for the purpose-built service status operation. Its registered service map contains nginx, docker, and sentinelx-cloud-core, but not pureline-poc. The assistant did not change SentinelX policy or use a shell restart to work around this boundary. An operator must enable the relevant service-management capability before a managed rollout can proceed.

The exact proposed configuration and systemd drop-in are retained under `deploy/pureline-wireguard-20261127/`. They are reviewable artifacts, not installed settings. The candidate entry point is the complete downstream wrapper; deploying only the base HTTP correction would lose MIME/stream handling and the model/SVG adapters.

## Prepared release layout

The intended immutable release directory is:

    /srv/pureline-poc/releases/20261127-wireguard-verified

Copy the final committed package from `tools/filter-quality/` into that directory: downstream Python sources, runtime_contract.py, runtime-contract.json, approved-ui-rasters.json, requirements-svg.lock, and the packaged runtime checker. Also copy the exact isolated `.vendor-svg` dependency directory used by the passing lab, verifying its recorded package versions/hashes. Do not copy the corpus, result images, Git metadata, lab WireGuard profiles, or the lab-only fixture-origin hook.

Install the prepared `production.toml` at the release root. Keep release code and dependencies root-owned and read-only to the service user. The existing models, pinned classifier source, YuNet model, OpenCV vendor directory, and Python environment remain at their validated paths under `/srv/pureline-poc`; do not create a second multi-gigabyte model copy.

The proposed production configuration uses the measured official model paths, existing concurrency/body/time limits, CPU inference, a new versioned cache database, and the previous bounded diagnostic settings. Old V2 cache entries must not be reused. Cache miss/hit behavior under this enabled production cache is a rollout gate; the offline quality benchmark deliberately disabled its cache.

## Preflight gates after service management is enabled

1. Record the active unit and drop-ins and back up their text to a protected operations directory. Hash the existing WireGuard profile and CA files locally without printing their contents. Confirm UDP 51820 is owned by this service, and loopback TCP 18530 is unused.
2. Verify the final source/package hashes against the committed acceptance reports. Run the packaged runtime checker as the service user. Check readability of model files and dependencies, writable access to the existing cache/diagnostic directories, and available disk space.
3. Start a temporary candidate with separate laboratory keys on loopback, retaining the production unit's 2 GiB memory budget. Measure peak memory while processing concurrent image requests. Run a fresh and then cached allow/block request, plus SVG normalization, and confirm no stale V2 result is returned.
4. Preserve the existing `81-transport-diagnostics.conf`, working directory, service user, memory ceiling and hardening. Install only the prepared `90-verified-candidate.conf`. Reload systemd configuration and restart through the authorized service-management capability.
5. Check active state, a new healthy PID, the expected WireGuard socket and unchanged CA/profile hashes. The additional regular-proxy listener is explicitly bound to `127.0.0.1:18530`; it enables same-process HTTPS smoke checks without reusing the owner's iPad WireGuard private key.
6. Use the existing production CA for HTTPS verification. Confirm an allowed raster is byte-identical, a blocked image is changed and decodable, strong blur holds on a large image, and the known Wikipedia logo is returned as the exact inspected PNG. Verify Content-Type, Content-Encoding and Content-Length together. Do not use TLS-verification bypasses.
7. Run physical iPhone/iPad acceptance: profile/keychain import, VPN permission, packet-tunnel lifecycle, direct UDP, DNS/IPv6, reconnect/sleep-wake and representative third-party apps. Browser/benchmark evidence does not close this gate.

## Rollback

If startup, memory or same-process smoke checks fail, remove only the newly installed `90-verified-candidate.conf`, reload systemd and restart through the authorized service capability. The original unit and `81-transport-diagnostics.conf` restore the original V2 command. Preserve the candidate logs and receipt for diagnosis. Existing CA/peer material and the old V2 cache remain untouched, so rollback does not require new device profiles.

Do not delete old artifacts or model assets as part of the rollout. A successful native archive is not proof of server promotion, a signed iPad installation or cross-app filtering. At the end of this implementation run, this rollout was prepared but not executed.
