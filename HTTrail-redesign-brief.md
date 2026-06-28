# HTTrail — Design Redesign Brief

Paste this into the Claude Design agent (claude.ai/design) on the **"Design system and onboarding"** project to redesign and expand the `HTTrail App.dc.html` composition. It is grounded in the *shipped* SwiftUI app, so the redesign will match what actually exists — including recent UX changes the current design is missing.

> **Prompt to the design agent:** "Redesign the HTTrail App composition. Keep the existing dark design system below. Produce every screen listed under *Screens*, including the macOS three-pane shell and the iOS tab flow. Pay special attention to the *Recent UX updates* section — the current design predates those."

---

## What HTTrail is

A native macOS + iOS app that is **both** a Hoppscotch-style API client **and** a Charles-style intercepting HTTPS debugging proxy. It runs its own Certificate Authority, MITM-decrypts TLS, captures every request/response, and lets you compose/replay requests. Dark-first, developer-grade, monospaced-heavy.

Four primary modes (macOS left rail / iOS tab bar): **Capture · Compose · Rules · Realtime** (+ **Setup** on iOS).

---

## Design system (keep exactly — already in the repo's `Theme.swift`)

**Surfaces (dark indigo):**
- App bg `#08071A` with a radial glow toward top-left (`#15173A` → `#0A0820` → `#08071A`)
- base `#0B091A` · surface/cards `#131734` · raised chips `#1B1F46`
- code surface `#0C0B22` · inputs/URL bar `#0E1228` · table rows `#10142E` · response area `#0B0E22`

**Text tiers:** primary `#EAEAF6` · bright `#E3E3F2` · soft `#C7C8E0` · dim `#9A9CC0` · muted `#7D7FA3` · faint `#62648A`

**Brand "signal" gradient (violet→blue→cyan→green), used sparingly for brand/active/realtime moments:**
- violet `#8B5CF6` · blue `#3B82F6` · cyan `#06B6D4` · green `#10B981` · amber `#F59E0B` · red `#EF4444`
- **Primary accent = blue `#3B82F6`.** Primary action button = violet→blue 135° gradient with a soft blue glow shadow.

**Method colors:** GET=blue · POST=green · PUT=amber · PATCH=violet · DELETE=red · OPTIONS=cyan · HEAD/CONNECT=grey `#6B7280`.
**Status colors:** 2xx=green · 3xx=blue · 4xx=amber · 5xx=red.

**Type:** proportional system font for chrome; **monospaced for every URL, header, payload, and code surface.** Eyebrow labels = 10px mono, uppercase, tracked +1.4.

**Components/tokens:** radii 6/9/12/16/pill. Method badge = tinted pill with matching border. Status indicator is tri-state: colored code number / blinking `···` while pending / red `ERR` pill on failure. Connection dot = pulsing green glow when live, grey when off, red on error. Cards = `#131734` @ 55% + hairline border (white @ 8%). Copy/export toolbar buttons = icon+text, flashing a "Copied" checkmark for 1s after tap.

---

## App shell

**macOS — three panes:**
1. **Left activity rail** (~icon column): one accent-barred icon+label per mode (Capture/Compose/Rules/Realtime). Active = blue accent bar on the left + blue tint + subtle fill.
2. **Sidebar** (280–480px, ideal 330): content depends on mode (lists below).
3. **Detail pane:** the editor/inspector for the mode.
- **Top toolbar:** environment picker (Compose only), green **Start ▾** / red **Stop** proxy button (Start menu lists "New Session" + resumable past sessions), a **System Proxy** toggle, and a **Setup ▾** menu (Proxy Settings, CA install/trust/reveal, Export iOS Profile, Bonjour toggle, Import cURL/OpenAPI/Postman, Export HAR, Clear Flows).
- **Bottom status bar:** pulsing connection dot + status text · flow count · active-rule count · `127.0.0.1:9090` · Bonjour state (with paired-device count).

**iOS — bottom tab bar:** Capture · Compose · Rules · Realtime · Setup, binding to the same model. Breakpoint sheet can appear globally over any tab.

---

## Screens to produce

### 1. Capture (proxy traffic)
- **Sessions list** (sidebar, default): list of recorded capture sessions; empty state "No sessions yet — press Start to record." Row context menu: Open / Resume / Rename / Edit Notes / Export HAR / Delete.
- **Flow list** (after opening a session): back button + session name; a **resource-type filter bar** (All / XHR / JS / CSS / Img / Font / Doc / Media / WS / Other) and a **search field** ("Filter host, path or method"). Each **flow row**: lock icon (secure/green vs open/faint) · method badge · host (bold) + path (mono dim) · right side status indicator + duration ms. Multi-select → Delete toolbar action.
- **Flow inspector** (detail): header block with method badge + full URL (selectable) + an **Edit ▾** menu (Edit & Resend in Compose / Copy as cURL); a meta row (HTTPS-decrypted lock · Status NNN colored · duration · error). **Request/Response segmented toggle.** Each side has a **Headers / Body / Preview** sub-toggle.
  - **Headers:** mono key/value table, cyan keys; toolbar Copy-all + Export; per-row copy menu.
  - **Body:** Text/Hex toggle (binary defaults to hex), byte-size readout, Copy + Export. JSON/XML syntax-highlighted (cyan keys, green strings, amber numbers, violet bool/null) with a line-number gutter.
  - **Preview:** rendered HTML (in a webview) or image; otherwise "No preview" empty state.
- **Empty detail state:** "Select a flow — Start the proxy and route traffic through 127.0.0.1:9090."

### 2. Compose (API client) — **most changed; see Recent UX updates**
- **Sidebar:** "Open Requests" (method badge + name/url), "Collections" (recursive folder/request tree), "History" (last 20, method badge + url + colored status). Top inset: New / Clear-history.
- **Request editor (detail):**
  - **URL bar row:** method dropdown (colored, in a tinted well) · monospaced URL field · gradient **Send** button (shows spinner + "Sending…") · a **layout toggle** button · a **More ▾** menu (Save to Collection / Duplicate).
  - **Config tabs:** Params · Headers · Auth · Body · GraphQL · Scripts · Code.
    - Params/Headers = enabled-checkbox key/value rows.
    - Auth = None / Bearer / Basic / API key (header-or-query toggle).
    - Body = mode picker (none/raw/json/form/etc.) + mono editor.
    - GraphQL = query + variables editors.
    - Scripts = pre-request + test scripts (JS, Postman-style `pm.*` API), with hint text.
    - **Code = generated cURL/Swift/JS/Python**, target dropdown + a **visible icon+text Copy button**.
  - **Response panel:** status code (colored) · duration ms · byte size · content-type chip · test pass count (e.g. "3/4") · "decrypted 🔒" tag. Sub-tabs **Body / Headers / Preview / Tests**. Tests = pass/fail checklist + console logs. Empty state: "Send a request to see the response."

### 3. Rules (interception engine)
- **Sidebar:** "Interception Rules" + Add. Rows = enabled check + name + kind label. Below: **SSL Proxying Allowlist** (add host-glob field + list; "empty = decrypt everything") and **Auto-detect Cert Pinning** (toggle + list of detected pinned/tunneled hosts each with a "Decrypt" override).
- **Rule editor (detail form):** Match section (Name, Enabled toggle, **Action** picker, URL pattern). Action-specific params:
  - **Block** → status stepper.
  - **Map Local** → local file path + content-type.
  - **Map Remote** → host + port + TLS toggle.
  - **Rewrite Request/Response** → set-headers key/value editor + body find/replace (response adds status override).
  - **Throttle** → delay ms stepper.
  - **Breakpoint** → pause-on-request / pause-on-response toggles.
- **Empty state:** "Select or add a rule — Rules run inside the proxy: block, map, rewrite, throttle, breakpoint."

### 4. Realtime (WebSocket / SSE / Socket.IO / MQTT)
- **Sidebar:** protocol segmented control (WebSocket / Socket.IO / SSE / MQTT); URL field (`wss://…`, or broker host/port/topic for MQTT; event name for Socket.IO); **Connect/Disconnect** button + connection dot; a **Local test server** toggle with hint text.
- **Main:** connection header (pulsing dot + `wss://… · connected`); scrolling **message log** with direction glyphs (↙ incoming green, ↗ outgoing blue, ⓘ system) in mono; bottom **composer** (mono field + gradient Send; disabled/"Receive-only stream" for SSE).

### 5. Setup / onboarding (iOS-first, also a macOS sheet)
- **iOS Setup (form):**
  - **Capture this device:** explainer → **"1. Install VPN + CA Profile"** → **"2. Start Capturing This Device"** → VPN status dot + "Capture engine: N rules · M allowlist".
  - **Certificate Authority:** Root CA trusted/not-trusted seal + Re-check, footer pointing to Settings ▸ General ▸ About ▸ Certificate Trust Settings.
  - **Proxy:** port field (locked while capturing) + Apply.
  - **Capture another device:** share Proxy+CA profile / share raw CA (.pem); point that device's Wi-Fi proxy at `deviceIP:9090`.
  - **This device:** IP address, LAN proxy running/stopped.
  - **Capture:** Export current capture (HAR), flow count.
- **macOS Proxy Settings sheet:** listen-port field (locked while running) + CA install/trust status + remove/install.
- **macOS Bonjour info sheet:** Local Network explainer with Enable/Cancel.
- **Breakpoint sheet (both platforms):** "Breakpoint — Request/Response", URL, editable body, **Continue Unchanged** / **Apply & Continue**.

---

## Recent UX updates (the current design predates these — make sure they're reflected)

1. **Compose response panel is now relocatable + draggable.** Default layout is **side-by-side**: request editor on the **left**, response on the **right**, with a **draggable vertical divider** to give the response much more area (the old design only had a short response strip pinned to the bottom). A small **toolbar toggle** (icon `rectangle.split.2x1` ⇄ `1x2`) flips between *response beside* and *response below*; the choice persists. Show **both** arrangements as variants, with the side-by-side as the hero.
2. **Code tab now has a clearly visible Copy button** — icon **+** the word "Copy" (not an icon-only/ghost button), matching the Body/Headers copy buttons, and it flashes "✓ Copied" for ~1s after tap.
3. Body viewer handles large bodies without freezing (hex view for binary; line-number gutter only under ~2000 lines) and previews more image formats + SVG — keep the Preview tab states accurate.

---

## What the current composition is missing (gaps to close)

- The **new side-by-side / draggable Compose layout** and the **visible Code Copy button** (items 1–2 above).
- Full **Capture** depth: Sessions list vs Flow list, the resource-type filter bar, multi-select delete, and the Request/Response × Headers/Body/Preview matrix in the inspector.
- The **Rules** screen breadth: all six action types, the SSL allowlist, and the cert-pinning auto-detect list.
- The **Realtime** screen across all four protocols (esp. MQTT broker/topic fields and the local test server).
- The **Setup/onboarding** flow (iOS two-step capture, CA trust state, share-to-other-device, HAR export) and the **Breakpoint** sheet.
- The **app chrome**: left activity rail, top proxy/system-proxy/Setup toolbar, and the bottom status bar with the live connection dot + Bonjour state.

Render each as its own frame/screen in the dark design system above, with realistic mono sample data (real-looking hosts, JSON bodies, status codes).
