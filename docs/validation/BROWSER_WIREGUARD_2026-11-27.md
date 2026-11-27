# Mac browser validation through real WireGuard — 2026-11-27

## Status and scope

The isolated Mac browser route is working and has exposed a real defect that
HTTP-status and offline image tests missed. Chromium received policy-blurred
images that did not decode. The HTTP serialization correction now makes the
same blocked portraits and 48/72-pixel thumbnails render as blurred images.
The classifier, weights and thresholds did not change for this correction.

This document covers the Mac Chromium lane. Native iOS URLSession, WKWebView,
simulator build, signing and physical-device VPN evidence are owned by the
application lane. The independent labelled holdout is owned by the quality
lane. Browser fixture counts below must not be added to that holdout.

The first public-page pass also exposed unsupported decorative SVG content and
one animated-GIF analysis failure. These remain coverage findings at this
checkpoint; a bounded format adapter is under validation in the quality lane.
A subsequent public-page run will be recorded separately after that candidate
is installed.

## Real route and trust boundary

The browser used Chromium Headless Shell **159.0.8154.6**, driven by Playwright
**1.65.1**, on the Mac's arm64 host. It had a dedicated new persistent profile
inside the lab runtime.

The route was:

1. Chromium's explicit HTTP CONNECT proxy at `127.0.0.1:18520`.
2. Official WireGuard Go userspace netstack and actual WireGuard encryption.
3. A loopback datagram relay and pinned SSH carrier between Mac and Oracle.
4. Isolated Oracle WireGuard mitmproxy on `127.0.0.1:18521`.
5. The official-model Pureline CPU candidate and then the public origin.

The interhost carrier wraps WireGuard UDP datagrams in TCP/SSH. This proves a
real WireGuard handshake and filtered traffic; it does not prove direct
internet UDP reachability or kernel VPN routing. No GPU was started.

Local HTML at `http://127.0.0.1:18524/` bypassed the proxy. Its image sources
were original public HTTPS URLs, and all those external requests used the
proxy. Public Wikipedia pages were also navigated through the proxy. There
was no browser direct fallback configured for public origins.

TLS was scoped to this profile: `ignoreHTTPSErrors:false`, with Chromium's
SPKI allowlist containing only the lab CA public-key hash:

`8oH7pg/cFaARtlf2hEbN/y+oMCvFIuE3zG4MXzUB5s0=`

There was no blanket certificate-error switch and no global trust-store
change. The CA private key remained on Oracle. Browser storage, proxy settings
and browsing history were isolated from the user's normal browser. The
production service on UDP51820, its peer keys and the host default routes were
not modified.

## Evidence collected

The harness records HTTP response actions and reasons, body SHA-256 and size,
DOM `complete`/natural image dimensions, screenshots, request failures, elapsed
time and WireGuard health. A policy header alone is insufficient: a displayed
image must also decode. The browser itself rendered the screenshots.

The local galleries have at most ten images per page. The source manifest
retains each fixture's expected policy label and original public URL. They
reuse benchmark fixtures and transformations, so they establish integration
behavior, not independent classification accuracy.

The initial sequence also scrolled eight viewport increments on each public
page. This is bounded browsing, not a claim that every lazy image in a long
article was requested. Public pages are unlabelled coverage observations.

### Initial candidate, before HTTP correction

Evidence directory: `tools/wireguard-lab/evidence/chromium-rendered-v1/`.

| Page | DOM images | Decoded | HTTP image actions | Finding |
|---|---:|---:|---|---|
| Allow gallery | 10 | 10 | 10 allow | Portraits visibly preserved |
| Block gallery | 10 | 4 | 10 blur | Six rewritten RandomUser images were broken |
| Mixed, first page | 10 | 5 | 5 allow, 5 blur | Five rewritten images were broken |
| Mixed, second page | 10 | 9 | 5 allow, 5 blur | One rewritten image was broken |
| Objects | 9 | 9 | 9 allow | Nonperson controls visibly preserved |
| Groups | 2 | 2 | 2 allow | Known archival group-image false negative reproduced |
| Published thumbnails, first page | 10 | 2 | 8 blur, 2 allow | All eight rewritten small images were broken |
| Published thumbnails, second page | 6 | 6 | 6 allow | Allowed 48/72-pixel images decoded |
| Wikipedia Nature | 62 | 19 | 19 allow, 24 replace | SVG coverage and GIF failure; remaining DOM images include lazy content |
| Wikipedia Albert Einstein | 69 | 22 | 17 allow, 25 replace, 7 blur | Real page loaded; many replacements did not decode |
| Wikipedia Golda Meir | 46 | 16 | 11 allow, 22 replace, 6 blur | Real page loaded; many replacements did not decode |

The sequence finished at **01:38:00.798 UTC**, entirely before the correction.

The known group miss is fixture `wikipedia-63005541`, an archival Viola Alberti
group still. It remains labelled BLOCK and visibly allowed in this run. It was
not removed, relabelled or used for threshold tuning after holdout exposure.

### HTTP bug and correction

Both base-addon rewrite branches assigned `response.content` before removing
the original Content-Encoding. The mitmproxy setter encoded the replacement
using that stale header. The addon then removed the encoding header and set
Content-Length to the uncompressed replacement length.

A direct Mac request through the same WireGuard proxy, with browser-style
`Accept-Encoding: gzip, deflate, br, zstd`, made the defect concrete:

| Check | Before | After |
|---|---|---|
| HTTP/action | 200 / blur | 200 / blur |
| Content-Type | image/jpeg | image/jpeg |
| Content-Encoding header | absent | absent |
| Declared Content-Length | 979 | 979 |
| Actual response bytes | 921 | 979 |
| First bytes | 1f8b0800 — gzip | ffd8ffe0 — JPEG |
| Decoded intended image | Invalid HTTP representation | JPEG, 128 × 128 |

The corrected output SHA-256 was
`e207d17fcebf558e97358e0bae26474770e9c0c96b45fccb10b83e2790e73aec`,
the same intended blur bytes previously inspected offline.

The minimal correction invalidates origin representation headers before
assigning replacement bytes, for both normal policy rewrites and failure
placeholders. It preserves allowed responses. The lab imports a local corrected
base module; the production service/source were not edited.

The isolated backend restart began **01:41:12.095 UTC** and the new process
started **01:41:12.801 UTC**. It reused the same lab CA, WireGuard keys, candidate
configuration, model files and thresholds. Its corrected module SHA-256 is
`0a359e1a28e26e1ca30e9f63d07c00ae60f8212509a70f76e7fb76821068a55e`.

The quality lane separately exercised actual mitmproxy Response serialization
for identity, gzip and Brotli across policy blur, failure replacement and
allowed passthrough: nine cases. This HTTP check is not image-classifier
accuracy data.

### Rendered retest after HTTP correction

Evidence directory:
`tools/wireguard-lab/evidence/chromium-http-rewrite-fixed-v2/`.

| Page | Decoded | Actions | Browser errors | Elapsed |
|---|---:|---|---:|---:|
| Block gallery | 10/10 | 10 blur | 0 | 23.612 s |
| Published thumbnails, first page | 10/10 | 8 blur, 2 allow | 0 | 14.699 s |

Both screenshots were inspected. Every blocked image rendered as a blur, with
the allowed thumbnails still visible. The two-page retest fixed the specific
observed rendering failure. Other unchanged pages are not silently counted as
post-correction retests.

The tunnel health advanced during this retest and reported no new proxy errors.
Its counters are shared with the separate iOS lab clients, so the aggregate
byte delta is not an exclusive Chromium throughput measurement. Per-page
browser evidence supplies the individual image outcomes.

## Remaining coverage boundaries

The initial Nature page replaced 23 SVG logos/icons as
`unsupportedImageFormat`. These include Wikipedia's wordmark, tagline and
page icons. The format adapter being evaluated must address this unnecessary
blocking without allowing embedded prohibited photos or active/external SVG
content through unexamined.

The same page's
`https://upload.wikimedia.org/wikipedia/commons/8/8e/Pangea_animation_03.gif`
produced a `model-failure` placeholder. This does not count as a correctly
allowed natural-scene image.

The known group-image false negative remains. The independent portrait holdout
can support its measured rates, but those rates do not establish comparable
accuracy for arbitrary illustrations, animations, group compositions or all
internet images.

The test does not establish system-wide interception, a functioning iOS
Network Extension in Simulator, physical-device tunnel activation, pinned
third-party applications, HTTP/3, app-specific caches, or images already
embedded as data URLs/canvas content. Existing cache behavior was recorded
where observed; this is not a cache-invalidation test after a policy change.

## Reproduction and source references

The source is `tools/wireguard-lab/browser_validation.cjs`; locked browser
dependencies are in its `browser/` directory. The README documents the scoped
runtime, gallery server and selecting a bounded page subset. The lab processes
remain running for the application lane.

Relevant primary references:

- [WireGuard official userspace netstack example](https://git.zx2c4.com/wireguard-go/plain/tun/netstack/examples/http_client.go)
- [mitmproxy HTTP message API and source](https://docs.mitmproxy.org/stable/api/mitmproxy/http.html)
- [Playwright BrowserType and persistent contexts](https://playwright.dev/docs/api/class-browsertype)
- [Chromium certificate SPKI allowlist source](https://chromium.googlesource.com/chromium/src/+/24fe268fd13ed59f189c7cd688e472adb7489fe9/services/network/ignore_errors_cert_verifier.h)
- [Apple DTS: Network Extension infrastructure unavailable in Simulator](https://developer.apple.com/forums/thread/46004)
