# Bounded v5 browser acceptance — 27 November 2026

## Result

**PASS: 5/5 rendered assets** in a fresh Chromium profile, with a new isolated
WireGuard peer and a new laboratory CA. The run finished at
2026-11-27T15:05:48.428Z, exit 0. The complete browser job took 22.13 seconds.
The gallery screenshot was visually reviewed: permitted content remained clear,
the two blocked examples were strongly blurred, and the logo decoded correctly.

Evidence: [machine receipt](../../tools/wireguard-lab/evidence/chromium-bounded-v5-20261127/summary.json)
and [rendered gallery](../../tools/wireguard-lab/evidence/chromium-bounded-v5-20261127/gallery.png).
The harness is [browser_bounded_v5_validation.cjs](../../tools/wireguard-lab/browser_bounded_v5_validation.cjs).

## Exact runtime and route

- Manifest: `tools/filter-quality/runtime-candidate-20261127-bounded-v5.json`.
- Manifest SHA-256: `e9b4424cce6a376c9ac2620cf5b5ad0ac0680264e5653042dc29eb812b13711b`.
- Package: 18 manifest files; unchanged SVG dependencies, 284 files, tree SHA-256
  `ce9897ee6a521476838d69cff59d784025315243cc517c2a8c338858c99b8f4c`.
- Browser: Chromium Headless Shell 159.0.8154.6; Playwright 1.65.1; Mac arm64.
- Route: Chromium explicit proxy on Mac loopback18530 → existing pinned official
  wireguard-go netstack binary → new loopback UDP18531/datagram relay →
  authorized pinned SSH/TCP18532 carrier → new Oracle WireGuard listener →
  complete frozen v5 filter.
- The binary SHA-256 is
  `1465371d8ac0e676c4e667e28a5a31ae15a566a792a5eaf95a90ce1cb27a2394`.
  Source/dependencies were unchanged from the previous transport acceptance.
- The server used two model workers, eight queued requests, an 18-second
  complete-body processing budget, cache disabled, and isolated private diagnostics.
  Its runtime/model contract passed without altering the original model files.

All lab listeners were bound to loopback. Production UDP51820 and the earlier
v4 laboratory remained untouched. New development processes and the dedicated
SSH carrier were stopped after the evidence was copied; cleanup receipts confirm
no remaining Oracle process owned by the new lab.

This is real WireGuard encryption with an additional framed TCP/SSH interhost
carrier. It does not test direct internet UDP, kernel routing, iOS Network
Extension activation, arbitrary app interception, or physical iPad behavior.

## Rendered cases

| Input | Expected and observed | Browser/body evidence |
| --- | --- | --- |
| Pangea GIF, 38 frames | Allow original animation | HTTP200, image/gif, 316480 bytes, exact original SHA-256, DOM decode200×160; three element captures700ms apart have three distinct hashes. |
| Two-frame GIF with a blocked second frame | Blur to a safe static image | HTTP200, image/png,7591 bytes, original hash changed; DOM decode128×128; all three rendered samples have the same hash. |
| Allowed static portrait | Allow original bytes | HTTP200, image/jpeg,5276 bytes, exact original hash; DOM decode128×128. |
| Blocked static portrait | Strong blur | HTTP200, image/jpeg,979 bytes, original hash changed; DOM decode128×128. |
| Public Wikisource SVG over HTTPS | Allow original benign SVG | HTTP200, original decoded-body SHA-256, DOM decode410×430, gzip representation preserved, no policy exception. |

There were zero browser request failures and zero transport errors. All actions
were ordinary policy decisions; no fixture-specific classification bypass was
installed. Four inputs came from a hash-verified, lab-only fixed GET origin at
the reserved192.0.2.1 host. That hook supplies original bytes and the normal v5
response hook still runs the real models. The fifth asset was fetched from its
public HTTPS origin.

Pangea provenance and the synthetic late-frame derivative are recorded in
[the animation fixture manifest](../../tools/filter-quality/corpus/animation-validation.json).
The Pangea source was downloaded with a descriptive project User-Agent and cached
to remove origin variability; this is not a new public-origin availability result.
These fixtures reuse calibration/regression sources and are not new independent
accuracy observations.

## Transport and trust evidence

A newly generated test peer completed a fresh handshake. WireGuard receive bytes
increased from92 to363072 and transmit bytes from180 to16420; the application
proxy recorded five requests/five successful connections,340665 response bytes
and no error. The initial handshake timestamp preceded the browser by about18
seconds because the new client starts its keepalive immediately.

The browser retained `ignoreHTTPSErrors:false`. Its certificate exception was
restricted to the new public lab CA SPKI
`3IlHG01JWzRJ7pUFX2YtnTJT0UdLEP+dF47sObPkOPU=`.
No system-wide trust/proxy setting changed, and the CA private key stayed on
Oracle. No production or owner's iPad private key was reused.

The receipt distinguishes decoded response bytes from wire representation
headers: the public SVG has gzip Content-Encoding, so its decoded body length
does not equal the compressed Content-Length. Rewritten images have matching
plain-image representations and decode successfully.

## Interpretation and remaining gates

This run closes the previously unsupported benign animated-GIF presentation
case for the **remote v5 runtime** and verifies late-frame blocking in a browser.
The separate local Core ML path intentionally rejects unsupported animation/SVG
under its strict defaults; it does not gain the remote worker's all-frame renderer.

The original long article/thumbnail completion finding remains documented in
[BROWSER_WIREGUARD_2026-11-27.md](BROWSER_WIREGUARD_2026-11-27.md). This focused
pass is not a whole-article rerun or proof of a fix to every upstream network
stall. Worker deadlines begin at admission of a complete image body; they do not
bound all upstream connection/header/body acquisition.

The earlier v3 full-app UI/WebKit/URLSession results remain evidence for their
recorded runtime. They are not relabelled as a v5 native-suite rerun. See
[RUNTIME_BOUNDS_2026-11-27.md](RUNTIME_BOUNDS_2026-11-27.md) for processing/load
results and known classifier errors. Production activation and physical-device
acceptance remain separate.
