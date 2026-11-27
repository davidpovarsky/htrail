# Mac browser validation through real WireGuard — 2026-11-27

## Outcome and scope

Real Chromium browsing through the isolated WireGuard route works. It exposed
and verified a correction to an HTTP representation bug that offline model
tests had missed: blocked images had been served with compressed bytes but
without the matching Content-Encoding, so they appeared broken. The corrected
responses now decode and visibly render as strong blurs.

The v3 frozen candidate also handles the tested static SVG logos and SVG
embedded photographs. Its final SVG gallery decoded **5/5** images with the
expected actions, and the high-resolution gallery decoded **4/4**, preserving
the allowed images and strongly blurring the blocked ones. Three public
Wikipedia articles were actually navigated and scrolled. They provide useful
coverage evidence, with the explicit remaining failures below; they are not
a labelled accuracy benchmark.

The v3 public pass found three material limitations:

- The Nature page's animated Pangea GIF is replaced by a failure placeholder.
- The Einstein page's Wikisource SVG logo is unnecessarily replaced because
  the renderer rejects a legacy Creative Commons metadata namespace.
- One Einstein thumbnail remained pending at the browser's bounded capture.
  A single later request through the same unchanged WireGuard route succeeded,
  but the original browser completion gap is not counted as a pass.

A focused v4 follow-up now fixes the Wikisource metadata compatibility defect.
One fresh Chromium image request returned the exact original SVG, passed DOM
decoding and visibly rendered the logo, with no special policy exception. The
animated GIF and original Einstein request-completion gap remain open. The
v3 article captures and native suite were not silently counted as v4 reruns.

This document owns the Mac Chromium evidence. Native iOS URLSession,
WKWebView, simulator builds and physical-device VPN evidence belong to the
application lane. Independent labelled accuracy belongs to the quality lane.
Browser galleries reuse quality fixtures and must not be added to its holdout.

## Real route, isolation and trust

The browser was Chromium Headless Shell **159.0.8154.6**, driven by Playwright
**1.65.1**, on the Mac arm64 host. Every acceptance run used a new dedicated
browser profile inside the lab runtime.

The route was:

1. Chromium's explicit HTTP CONNECT proxy at `127.0.0.1:18520`.
2. Official WireGuard Go userspace netstack with an actual WireGuard handshake.
3. A loopback datagram relay and pinned SSH carrier between Mac and Oracle.
4. Isolated Oracle WireGuard mitmproxy on `127.0.0.1:18521`.
5. The official-model Pureline CPU candidate and the requested origin.

The interhost carrier wraps encrypted WireGuard UDP datagrams in TCP/SSH.
This establishes real WireGuard encryption and filtered traffic. It does not
establish direct internet UDP reachability, kernel VPN routing or a working
iOS Network Extension inside Simulator. No GPU was started.

Local gallery HTML at `http://127.0.0.1:18524/` bypassed the proxy. Original
public image URLs and public article requests used the proxy. The new
controlled SVG/high-resolution fixtures also crossed WireGuard: a strict
Oracle-only fixture hook answered six whitelisted URLs on reserved
`http://192.0.2.1/pureline-lab-20261127/fixtures/`, then the ordinary image
response hook performed actual classification and rewriting. These fixtures
are not a new external website or additional independent accuracy samples.
They require no public listener, route or firewall change.

The fixture hook permits only fixed GET paths, MIME types and content hashes,
with a 4 MiB limit. It never supplies precomputed policy decisions. The
original embedded-woman SVG entering the filter was verified as 5,601 bytes,
SHA-256 `f3e33f152876775df5174e2e1a3c494a60c8ea822df06c5993cc530d928bb227`,
identical to the controlled source.

TLS was scoped to this browser profile: `ignoreHTTPSErrors:false`, with
Chromium's SPKI allowlist containing only the lab CA public-key hash:

`8oH7pg/cFaARtlf2hEbN/y+oMCvFIuE3zG4MXzUB5s0=`

A separate fresh-profile negative control removed that one exception and
received `ERR_CERT_AUTHORITY_INVALID`. This confirms the test did not
silently disable all certificate validation. There was no system keychain
change, global proxy, default-route change or firewall change. The CA private
key stayed on Oracle. The existing UDP51820 service, its keys and profiles
were not modified.

Evidence: `tools/wireguard-lab/evidence/browser-trust-negative-control.json`,
`fixture-origin-manifest.json` and `fixture-input-probe.json`.

## What the browser measured

The harness records response actions/reasons, public-body SHA-256 and size,
DOM `complete` and natural dimensions, screenshots, pending/failed requests,
elapsed time, browser cache metadata and WireGuard health. A policy header
alone is insufficient: the response must decode and appear in the screenshot.

Gallery pages contain at most ten images. The manifest retains expected labels
and source identity. The public-page run scrolled eight viewport increments
per article and waited up to 90 seconds for started image requests. It did
not request every lazy image in a long article.

Public image-response totals include CSS images and repeated/cached resources,
so they are not the same denominator as DOM `img` elements. A decoded DOM
image may have come from the fresh profile's cache after a previous page.
Cached observations are not additional model inferences. WireGuard counters
are shared with the separately run iOS clients and therefore are not exclusive
Chromium throughput measurements.

Only allowlisted public static-resource query keys are retained. No browser
cookies, authorization headers, raw response header dumps, CA private keys or
client credentials are committed.

## Initial browser findings and the HTTP correction

### Initial candidate, before correction

Evidence: `tools/wireguard-lab/evidence/chromium-rendered-v1/`.
The sequence finished at **01:38:00.798 UTC**, before the HTTP correction.

| Page | DOM images | Decoded | HTTP image actions | Finding |
|---|---:|---:|---|---|
| Allow gallery | 10 | 10 | 10 allow | Portraits visibly preserved |
| Block gallery | 10 | 4 | 10 blur | Six rewritten images were broken |
| Mixed, first page | 10 | 5 | 5 allow, 5 blur | Five rewritten images were broken |
| Mixed, second page | 10 | 9 | 5 allow, 5 blur | One rewritten image was broken |
| Objects | 9 | 9 | 9 allow | Nonperson controls preserved |
| Groups | 2 | 2 | 2 allow | Known group-image false negative reproduced |
| Published thumbnails, first page | 10 | 2 | 8 blur, 2 allow | All eight rewritten small images were broken |
| Published thumbnails, second page | 6 | 6 | 6 allow | Allowed small images decoded |
| Wikipedia Nature | 62 | 19 | 19 allow, 24 replace | SVG coverage and animated-GIF failure |
| Wikipedia Albert Einstein | 69 | 22 | 17 allow, 25 replace, 7 blur | Many replacement images did not decode |
| Wikipedia Golda Meir | 46 | 16 | 11 allow, 22 replace, 6 blur | Many replacement images did not decode |

The known group miss is `wikipedia-63005541`, an archival Viola Alberti
group still. It remains labelled BLOCK and visibly allowed in this run. It
was not removed, relabelled or used for threshold tuning after holdout exposure.

### Concrete HTTP defect

Both base-addon rewrite branches assigned `response.content` before
removing the original Content-Encoding. The mitmproxy setter encoded the
replacement using that stale header. The addon then removed the encoding
header and set Content-Length to the uncompressed replacement length.

A Mac request through the same WireGuard proxy with browser-style
`Accept-Encoding: gzip, deflate, br, zstd` established the mismatch:

| Check | Before | After |
|---|---|---|
| HTTP/action | 200 / blur | 200 / blur |
| Content-Type | image/jpeg | image/jpeg |
| Content-Encoding | absent | absent |
| Declared Content-Length | 979 | 979 |
| Actual bytes | 921 | 979 |
| First bytes | 1f8b0800 — gzip | ffd8ffe0 — JPEG |
| Intended image | Invalid HTTP representation | JPEG, 128 × 128 |

The corrected image SHA-256 was
`e207d17fcebf558e97358e0bae26474770e9c0c96b45fccb10b83e2790e73aec`.
The correction removes invalidated origin representation headers before
assigning replacement bytes, for both policy rewrites and failure
placeholders. Allowed responses remain unchanged. No model weights,
classification thresholds or policy labels changed.

The first corrected lab process started **01:41:12.801 UTC**. Its module
SHA-256 was
`0a359e1a28e26e1ca30e9f63d07c00ae60f8212509a70f76e7fb76821068a55e`.
The final candidate includes the equivalent packaged correction.

The quality lane separately verified actual mitmproxy Response serialization:
identity/gzip/Brotli × policy blur/failure placeholder/allow passthrough,
**9/9 cases**, including body decoding and correct Content-Length. Those
checks are serialization evidence, not classifier accuracy data.

### Rendered retest after the HTTP correction

Evidence: `tools/wireguard-lab/evidence/chromium-http-rewrite-fixed-v2/`.

| Page | Decoded | Actions | Browser errors | Elapsed |
|---|---:|---|---:|---:|
| Block gallery | 10/10 | 10 blur | 0 | 23.612 s |
| Published thumbnails, first page | 10/10 | 8 blur, 2 allow | 0 | 14.699 s |

Both screenshots were inspected. Blocked images visibly rendered as blurs,
and allowed thumbnails remained visible. Other unchanged pages were not
silently counted as additional post-correction retests.

## Final candidate and immutable runtime

The final runtime adds bounded static-SVG inspection and stronger blocked
image presentation. The SVG worker retains its original 5-second wall limit,
3/4-second CPU limits and 512 MiB memory bound, and rejects unsupported
active/external constructs. Large blocked images use a blur-radius floor of
`max(32, min(width, height) × 0.25)`. Classification weights and thresholds
remain frozen; the presentation change does not turn a wrong allow into a block.

The Wikipedia anniversary globe has one explicitly approved, exact-content
exception. The raw model falsely blurs its inspected raster. Only the exact
known-safe inspected PNG SHA-256
`bb0e4b77e584215801290c003052a2aa2b0a760adcba1894a2fcddcbad9a8153`
is allowed by that registry entry. The response returns that same 12,996-byte,
100 × 100 PNG, not the original SVG. Its headers identify
`rasterized_allow` and `curated-public-ui-asset`. The returned image was
visually inspected as a globe/logo. This is a narrow policy exception and must
not be reported as a corrected machine-learning prediction.

The response pipeline metadata now records the served allow decision and
preserves `modelActionBeforeOverride=blur`. The original upstream diagnostics
are written before downstream curation, so their raw blur row must not be
misrepresented as the served decision. The one-case metadata-coherence
regression is separate from the preserved original seven-case SVG receipt.

V3 frozen runtime identity (preserved for the full browser/native evidence):

| Item | Identity |
|---|---|
| Runtime directory | `/srv/pureline-poc/lab-20261127/candidate-package-v3-frozen` |
| Entrypoint | `downstream/pureline_addon_candidate.py` |
| Versioned manifest | `tools/filter-quality/runtime-candidate-20261127-fc8c4247.json` |
| Manifest SHA-256 | `4a6868b7afa5d575ca62f62288022ebb5cec3aaac2463aec29f9e52aba04c970` |
| SVG pipeline SHA-256 | `fc8c4247e44e0468331d21a6cdba9ff90b7e013e3081353bbf59f9037eda8f97` |
| Lab config SHA-256 | `6ac5a5c32a4dd50e86abc6e72737850b12b9328ffd7091cf53cea1d3bf3e6f47` |
| Backend start | 2026-11-27 **03:03:33.170 UTC** |
| Client/relay refresh | 2026-11-27 **03:04:31 UTC** |

All 13 manifest files and 284 SVG vendor files (24,807,234 bytes) were
hash-verified during the exact copy to this isolated runtime. The lab config
differs from the reference candidate only in isolated filesystem paths.
Source/config/model changes were not made during the final browser pass.

### Preserved transient I/O failure

The first combined runtime, loaded from the development volume, produced
failure placeholders for an embedded SVG. A live worker was observed in
filesystem wait states while the host had severe I/O pressure. The same
worker, interpreter and exact input succeeded in a standalone run; daemon and
one-off processes shared the same cgroup, UID and resource limits. The live
input length/hash were correct. A later live attempt succeeded as pressure
eased.

The frozen runtime was then copied with hash verification to the separate
`/srv` volume, without changing worker bounds or policy. This sequence
supports an I/O-pressure explanation, but it is not a controlled proof that
the copy alone caused recovery. The initial failed receipts remain retained.
No host cleanup or production restart was performed.

Evidence: `io-pressure-initial-readiness.json`,
`svg-worker-io-observation.json`, `fixture-input-probe.json`,
`runtime-staging-receipt.json` and `frozen-runtime-cutover.json` under the
lab evidence directory.

After the frozen cutover, actual Mac WireGuard requests successfully returned
the curated globe, policy-blurred embedded SVG and policy-blurred 1536-pixel
fixture. Body magic, length and hashes matched the intended representations.
The tunnel had a fresh handshake and bidirectional bytes. See
`frozen-v3-readiness.json` and `frozen-v3-readiness-health.json`.

## Final v3 actual Chromium pass

Evidence: `tools/wireguard-lab/evidence/chromium-frozen-v3/`.
Run time: **03:08:00.810–03:11:54.659 UTC**. The pages were visited sequentially
against the frozen candidate. The native application lane ran separately;
shared backend work can affect elapsed time.

| Page | DOM images | Decoded DOM | Image responses and actions | Remaining DOM state | Elapsed |
|---|---:|---:|---|---|---:|
| SVG gallery | 5 | 5 | 4 allow, 1 blur | None; all 5 labels match | 20.970 s |
| High-resolution gallery | 4 | 4 | 2 allow, 2 blur | None; all 4 labels match | 10.140 s |
| Wikipedia Nature | 62 | 22 | 42 allow, 1 replace | 40 lazy images unrequested | 35.640 s |
| Wikipedia Albert Einstein | 69 | 25 | 41 allow, 6 blur, 1 replace | 40 unrequested; 4 DOM entries pending, 1 unique request in flight | 100.315 s |
| Wikipedia Golda Meir | 46 | 20 | 33 allow, 7 blur | 26 lazy images unrequested | 53.564 s |

There were no completed-but-undecodable image responses or failed network
request events at capture in these five pages. That does not count the
Einstein pending request as successful. Browser-cached response counts were
3, 33 and 28 respectively for Nature, Einstein and Golda Meir.

The four pending Einstein DOM entries do not mean four network timeouts.
Three lazy icon elements share an already requested URL and have natural
dimensions; the harness joins DOM entries to response identity by URL.
Only the League of Nations thumbnail was a unique outstanding image request.

### Visual review

The final screenshots were opened and inspected, not inferred from headers:

- `svg.png`: three logos visible, embedded blocked portrait strongly blurred,
  embedded allowed portrait visible.
- `highres.png`: both 1024/1536-pixel blocked derivatives strongly blurred;
  both allowed group-photo derivatives visible.
- `wikipedia-nature.png`: article and main natural-scene photograph readable
  and visible, with the wordmark/tagline restored.
- `wikipedia-meir.png`: article text and interface visible; main portrait
  visibly blurred.
- `wikipedia-einstein-scrolled.png`: actual scrolled article with rewritten
  group images visibly blurred. These unlabelled group responses are not
  assigned new ground-truth labels by this report.

The screenshots are representative render evidence; the per-page JSON retains
all observed image results. The native application report owns its separate
final WebKit and URLSession results.

## Focused v4 correction and actual browser proof

The quality lane added only the legacy Creative Commons metadata namespace to
the existing SVG worker validation. It did not add a content exception, alter
the model or relax active/external-content restrictions. The exact public SVG
passed real model inspection as policy/allow, while legacy-namespace external
resource, script and foreignObject cases were rejected before inference:
**4/4 targeted cases**. See
`tools/filter-quality/evidence/svg-legacy-metadata-validation.json`.

The new immutable stage is
`/srv/pureline-poc/lab-20261127/candidate-package-v4-legacycc`.
All 13 manifest files and 284 unchanged vendor files were verified. Only
`downstream/svg_worker.py` differs from v3:

- Manifest: `tools/filter-quality/runtime-candidate-20261127-legacycc-6c7e4fc2.json`.
- Manifest SHA-256: `74fd5f729dbacd846e827506d6230daebfe32a3e45b36fa759e989b5c4ea4704`.
- Worker SHA-256: `6c7e4fc2c6ff1d109710f090b3e4eccf4b622566ed928c20019a00b41603b393`.
- Isolated backend start: **03:29:19 UTC**; fresh client/relay: **03:31:22 UTC**.
- The lab configuration, keys, CA, model files, bounds and policy registry
  remain unchanged. The v3 runtime and all its receipts remain preserved.

One new Chromium profile loaded the exact public Wikisource asset through the
same real WireGuard/filter route at **03:31:40.150–03:31:43.780 UTC**:

| Check | Result |
|---|---|
| HTTP and action | 200 / allow / policy |
| Original representation | image/svg+xml, gzip, declared compressed length 5,662 |
| Decoded response body | 16,160 bytes; exact original SHA-256 `211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95` |
| Browser image decode | Complete; `img.decode()` resolved; 410 × 430 |
| Rasterized presentation / policy exception | Neither present |
| Request failures | 0 |
| Harness elapsed time | 3.618 s |
| WireGuard evidence | Fresh handshake, one successful connection, bidirectional byte growth, zero proxy errors |

The screenshot `tools/wireguard-lab/evidence/chromium-wikisource-v4/wikisource.png`
was opened and visually verified: the logo is unobscured. The paired
`summary.json` retains the measured response, DOM result and tunnel counters.
The focused harness is `browser_wikisource_validation.cjs`. Runtime receipts
are `runtime-staging-v4-receipt.json`, `frozen-v4-runtime-cutover.json` and
`frozen-v4-client-restart.json` under the lab evidence directory.

This is one asset-specific correction and verification. It is not an Einstein
article rerun, a new holdout sample or a repeat of the native application suite.
The remaining v3 article findings below stay unchanged.

## Remaining coverage and completion gaps

### Animated GIF

The public Nature asset
[the Pangea animation](https://upload.wikimedia.org/wikipedia/commons/8/8e/Pangea_animation_03.gif)
still returned `replace / model-failure`. It is an unnecessary replacement
of a natural-scene animation, not a correct allow. Animation coverage is not
established by the still-image holdout.

### Legacy SVG metadata — historical v3 gap, corrected in v4

[Wikisource-logo.svg](https://upload.wikimedia.org/wikipedia/commons/4/4c/Wikisource-logo.svg)
returned a 1,806-byte placeholder in 2.620 seconds. The live sanitized error
was `SVGInspectionError` at the bounded-renderer boundary, not a model
classification or a worker timeout.

An offline read after the v3 run of that exact public source found 16,160 bytes, SHA-256
`211b332af6138a7c2d5fce0b58586c63e03ea418060539dd315e61c0c0e49e95`.
The frozen worker rejected `unsupported-svg-tag` at the legacy
`cc:Work` metadata element in namespace `http://web.resource.org/cc/`.
Its metadata allowlist recognizes the newer namespace, not this older one.
This identified a concrete benign-metadata compatibility false block. The
v3 runtime was preserved. The one-namespace v4 correction and actual browser
verification are recorded above; no content exception or deadline change was
introduced.

Evidence: `tools/filter-quality/evidence/wikisource-svg-compatibility-boundary.json`
and `tools/wireguard-lab/evidence/public-svg-error-probe.json`.

### One unresolved original browser completion

The Einstein page's
[League of Nations thumbnail](https://thumb.wikimedia.org/wikipedia/commons/thumb/6/63/League_of_Nations_Commission_067.tif/lossy-page1-250px-League_of_Nations_Commission_067.tif.jpg?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail)
remained in flight after the bounded wait. The captured page is therefore
partial coverage, not a whole-page pass.

A single follow-up on the unchanged backend returned:

| Route | HTTP / representation | Bytes | Time |
|---|---|---:|---:|
| Oracle direct public origin | 200 / JPEG | 13,205 | 0.236 s |
| Mac through WireGuard and filter | 200 / policy blur PNG | 7,935 | 9.957 s |

The filtered PNG SHA-256 was
`552fa26b845e886b89b7e9dd910361558a5ae0d6974794ffcc6e739e523ac66a`.
The retry excludes a persistent origin or unsupported-format failure at that
later time; it does not identify the original delay's cause or retroactively
complete the browser capture. No further page retries or transport changes
were used to erase that finding.

Evidence: `pending-thumbnail-direct-probe.json`,
`pending-thumbnail-wg-probe.json` and the original Einstein per-page JSON.

### Broader boundaries

The known archival group false negative remains. Measured portrait holdout
rates do not establish comparable accuracy for arbitrary illustrations,
animations, group compositions or every internet image.

This lab does not establish system-wide interception, iOS Network Extension
activation in Simulator, physical-device tunnel operation, pinned
third-party applications, HTTP/3, direct public UDP connectivity, app-specific
caches, data-URL/canvas images or images never requested. Existing cache
behavior is recorded; policy-change cache invalidation was not tested.

## Reproduction and primary references

Source: `tools/wireguard-lab/browser_validation.cjs`; locked browser
dependencies: `tools/wireguard-lab/browser/`. The README documents the
loopback contract, gallery server and bounded page selection. Lab processes
remain running. Production deployment and rollback require their own
authorized process and are outside this report.

- [WireGuard official userspace netstack example](https://git.zx2c4.com/wireguard-go/plain/tun/netstack/examples/http_client.go)
- [mitmproxy HTTP message API and source](https://docs.mitmproxy.org/stable/api/mitmproxy/http.html)
- [Playwright BrowserType and persistent contexts](https://playwright.dev/docs/api/class-browsertype)
- [Chromium certificate SPKI allowlist source](https://chromium.googlesource.com/chromium/src/+/24fe268fd13ed59f189c7cd688e472adb7489fe9/services/network/ignore_errors_cert_verifier.h)
- [Apple DTS: Network Extension infrastructure unavailable in Simulator](https://developer.apple.com/forums/thread/46004)
