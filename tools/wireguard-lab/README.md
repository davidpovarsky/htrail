# Pureline isolated WireGuard laboratory

Owner: WireGuard transport lane. Run ID: pureline-wg-lab-20261127.

This tool drives real encrypted WireGuard traffic through the existing Pureline
filter implementation in a separate laboratory mitmproxy process. It does not
implement, emulate, or prove an iOS Network Extension.

## Route

Mac HTTP CONNECT / ordinary HTTP listener 127.0.0.1:18520 -> official wireguard-go
userspace netstack -> loopback UDP 18521 -> framed TCP datagram relay -> pinned
Oracle-to-Mac reverse SSH forward on loopback TCP 18522 -> isolated Oracle
WireGuard server 127.0.0.1:18521 -> Pureline addon -> origin.

There is a real WireGuard handshake and encrypted payload between netstack and
mitmproxy. UDP datagrams use an additional framed TCP/SSH carrier on the interhost
leg. This route deliberately does not test direct internet UDP reachability,
kernel routing, iOS NE activation or arbitrary third-party app interception.

## Isolation

The existing UDP51820 service, its peer keys, CA, firewall, routes, model files,
cache and diagnostics are never edited. Runtime secrets and the test CA private
key live only in /srv/pureline-poc/lab-20261127 (mode0700). The unique laboratory
client credential is transported only via existing pinned SSH to the Mac
runtime directory, mode0600. No raw secret is committed or printed.

All listeners are loopback-only. The proxy supports public-web port80/443
traffic from an explicitly configured test client. It must not be published.
No system-wide proxy or trust settings are changed by this tool.

## Source and dependency

main.go uses golang.zx2c4.com/wireguard pinned in go.mod/go.sum.
Upstream reference:
https://git.zx2c4.com/wireguard-go/plain/tun/netstack/examples/http_client.go

datagram_relay.py uses only Python standard-library asyncio.

Cross compilation (on Oracle, no Apple SDK used):
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o bin/pureline-wg-proxy-mac .

The exact pinned dependency and source hash are retained in the Git receipt.
Runtime logs must never contain keys, full URLs, headers or image content.

## Consumer contract

HTTP CONNECT proxy: 127.0.0.1:18520 (no proxy transport TLS; loopback only).
Public test CA certificate on Mac:
~/builds/pureline-wireguard-lab-20261127/mitmproxy-ca-cert.pem

For URLSession or WKWebsiteDataStore use ProxyConfiguration(httpCONNECTProxy:
.hostPort(host:"127.0.0.1",port:18520),tlsOptions:nil), with direct failover
disabled. Trust the public lab CA only inside the dedicated test environment.
Do not add the private CA key or client JSON to application bundles.

Health: http://127.0.0.1:18520/__pureline_lab_health
Returns aggregate requests, successful connections, errors, byte counters and
WireGuard last-handshake/tx/rx metadata; never UAPI secret fields.

The Mac UDP relay binds its first client's source address. Restart this isolated
relay when restarting the netstack client, so a new ephemeral UDP port is valid.

## Evidence boundary

A successful HTTP status alone is insufficient. Evidence must include a fresh
WireGuard handshake, bidirectional bytes, HTTP/DNS/TLS tests, actual image filter
response header/body integrity, and browser render evidence owned by the UI lane.
Model accuracy belongs to the independently labelled holdout lane. Neither
substitutes for a physical iOS device test.


## Rendered Mac browser validation

`browser_validation.cjs` launches a dedicated Chromium profile with Playwright.
The dependency is locked in `browser/package-lock.json` (Playwright 1.65.1;
observed Chromium Headless Shell 159.0.8154.6). Install only in the isolated Mac
runtime; no user's normal browser profile or cookies are used.

The browser proxy is explicit: `http://127.0.0.1:18520`. Only localhost is
excluded, to load local gallery HTML on port18524. Every external gallery image
and every public-page request uses the WireGuard route. TLS errors are not
globally ignored: `ignoreHTTPSErrors:false`, with
`--ignore-certificate-errors-spki-list` restricted to the public lab CA key.
No system keychain, system proxy, default route or firewall is changed.
The CA private key is never copied to the Mac or this repository.

Prepare `browser-runtime` from the locked package files, then install the
dedicated browser there with `PLAYWRIGHT_BROWSERS_PATH` set to its `browsers`
subdirectory. Serve this repository's `gallery` directory on loopback18524:

```sh
python3 -m http.server 18524 --bind 127.0.0.1 --directory gallery
```

For an already prepared lab, run:

```sh
PURELINE_LAB_ROOT=/Users/m1/builds/pureline-wireguard-lab-20261127
export PURELINE_LAB_ROOT
export NODE_PATH="$PURELINE_LAB_ROOT/browser-runtime/node_modules"
export PLAYWRIGHT_BROWSERS_PATH="$PURELINE_LAB_ROOT/browser-runtime/browsers"
export PURELINE_BROWSER_RUN=choose-a-new-run-id
export PURELINE_BROWSER_PAGES=block,thumbnails
node browser_validation.cjs
```

Use a new run ID/profile for each acceptance pass. Omitting
`PURELINE_BROWSER_PAGES` visits the complete configured sequence. Set
`PURELINE_BACKEND_REVISION` to the verified deployed candidate revision for the
receipt. Output is in the runtime `evidence/<run-id>` directory. The harness
records screenshots, decoded DOM image dimensions, image-response actions,
content hashes, network failures, cache metadata and tunnel counters. Public
image URLs retain only an allowlist of nonsecret static-resource query keys;
other query parameters, cookies, authorization headers and unrelated browsing
activity are not recorded. Earlier run receipts omitted all query strings.

Gallery pages deliberately reuse quality-test fixtures. Each page has at most
ten images, and the manifest retains expected labels and original public URLs.
The gallery is an integration check, not additional independent accuracy data.

## HTTP serialization correction discovered in a real browser

`pureline_http_addon.py` is a lab-local copy of the deployed base HTTP addon
with one correction in both replacement paths: remove obsolete origin
representation headers **before** assigning `response.content`. The content
setter uses the existing Content-Encoding. Removing that header afterward
produced compressed image bytes labelled as an uncompressed JPEG, with an
incorrect declared Content-Length.

The first corrected V2 lab wrapper imported this local module. It is retained
as historical source evidence. The final active runtime uses the equivalent
module in the quality package, together with its bounded SVG and strong-blur
adapters. The production source and service remain unchanged. The quality
lane verifies actual mitmproxy identity/gzip/Brotli serialization for policy
blur, failure replacement and allowed passthrough.

## Frozen runtime and controlled fixtures

The v3 frozen runtime is
`/srv/pureline-poc/lab-20261127/candidate-package-v3-frozen`, with entrypoint
`downstream/pureline_addon_candidate.py`. Its versioned source/config manifest
is `tools/filter-quality/runtime-candidate-20261127-fc8c4247.json`, SHA-256
`4a6868b7afa5d575ca62f62288022ebb5cec3aaac2463aec29f9e52aba04c970`.
The exact copy verified all 13 manifest files and 284 SVG vendor files. Runtime
keys and CA material remain outside the repository. A later isolated revision
must receive a new directory, manifest and receipt; preserve prior evidence.

`fixture_origin.py` is a separate lab-only mitmproxy script. It answers only
six fixed, hash-verified GET fixtures at the reserved HTTP host `192.0.2.1`
and prefix `/pureline-lab-20261127/fixtures/`. The ordinary response hook still
runs the real filter. The fixture hook does not return policy decisions and
does not need an external listener, host route or public firewall change.
It supports `svg.html` and `highres.html`; their embedded photographs and
large derivatives reuse calibration sources, so they are integration checks,
not additional independent accuracy observations.

The script also retains narrowly scoped input metadata and sanitized error
classes for diagnosing worker failures. It must not log arbitrary URLs,
headers, payloads or exception text. Public fixtures and lab evidence are the
only supported content for this diagnostic route.

## Acceptance evidence

Before/after receipts and browser screenshots are retained under `evidence`.
The final v3 pass is `evidence/chromium-frozen-v3/`. SVG5/5 and highres4/4
rendered with the expected actions. Public pages retain explicit coverage
failures and an unresolved original browser completion, with a later
successful single-request retry recorded separately. The negative TLS control
confirms an untrusted fresh browser rejects the lab CA without its SPKI pin.

See `../../docs/validation/BROWSER_WIREGUARD_2026-11-27.md` for the complete
results, known gaps, runtime hashes and evidence interpretation.
