# HTTrail — UI/UX Redesign Brief (for a Designer Agent)

> **Your task:** Redesign the **entire** HTTrail app — every screen, flow, and
> component — for **both macOS and iOS**, covering **UX (structure, flows,
> states) and UI (visual design, layout, components)**. This document is the
> single source of truth for *what the app does and what it must contain*. Design
> for the feature set described here; do not drop features. Where macOS and iOS
> differ, it should only be in **layout idiom**, never in **capabilities**.

---

## 1. What HTTrail is

HTTrail is a **native Swift/SwiftUI HTTPS debugging proxy + API client** — a
1:1 clone of **Charles Proxy** (traffic capture/inspection/manipulation) fused
with **Hoppscotch** (API client: REST, GraphQL, realtime). It runs an on-device
MITM proxy with its own root CA, captures and decrypts HTTPS, lets the user
inspect/replay/rewrite traffic, and compose and send API requests.

**Who uses it:** mobile/web/backend developers and QA engineers debugging API
traffic. They are technical, value **information density**, fast keyboard/touch
navigation, monospaced payload readability, and trustworthy status signals
(secure vs not, success vs error, pending vs done).

**Primary jobs the user comes to do**
1. Capture live HTTP/HTTPS traffic and inspect a request/response in detail.
2. Compose, send, and iterate on an API request (REST or GraphQL).
3. Manipulate traffic with rules (block, map, rewrite, throttle, breakpoint).
4. Connect to realtime endpoints (WebSocket, Socket.IO, SSE, MQTT).
5. Set up trust: install the CA / proxy profile on the device under test.

---

## 2. Platforms, tech & hard constraints

- **Pure SwiftUI**, native on each platform. macOS uses AppKit affordances
  (menus, Finder reveal, split view); iOS uses UIKit affordances (share sheet,
  tab bar, navigation stack). Design must feel **platform-native on each**, not
  a ported clone.
- **The ONLY HTML allowed in the product** is the *response preview renderer*
  (an inert WebView showing a captured/returned HTML body). Everything else is
  native SwiftUI. Do **not** propose web-style chrome.
- **Light + Dark mode** are both required. Developers heavily use dark mode —
  treat dark as a first-class (arguably primary) design.
- **Density:** this is a pro tool. Favor compact, scannable layouts over large
  marketing whitespace, while staying legible.
- **Monospaced** type for URLs, headers, payloads, code, logs. Proportional for
  labels/chrome.
- Real-time updating lists (flows stream in; realtime messages append live).

---

## 3. Brand foundation (already established — design around it)

- **App icon / logo:** `branding/logo.svg` — a full-bleed dark gradient tile with
  a glowing **"H" formed from a packet-trail** (connected nodes) and a small
  **HTTPS padlock** accent. The "trail of traffic" is the core metaphor.
- **Core palette (from the logo gradient)** — use as the brand/accent system:
  - Indigo/violet `#8B5CF6` → blue `#3B82F6` → cyan `#06B6D4` → green `#10B981`
    (a left-to-right "signal" gradient — great for the brand mark, active
    states, and the realtime/trail motif).
  - Deep background neutrals: `#0B091A` / `#14193F` / `#0F3346` (dark mode base).
  - Accent gold for security/lock: `#FBBF24` → `#F59E0B`.
- **Semantic colors (must remain unambiguous):**
  - HTTP method badges: GET = blue, POST = green, PUT = orange, PATCH = purple,
    DELETE = red, CONNECT = gray.
  - Status codes: 2xx = green, 3xx = blue, 4xx = orange, 5xx = red, none = gray.
  - Secure lock = green; insecure = secondary/gray.
  - Connection dot: connected = green, disconnected = gray, error = red.
- You may evolve typography, spacing, elevation, iconography, and the component
  look — but keep the **trail/signal metaphor**, the **method/status semantics**,
  and the **gradient accent** recognizable.

---

## 4. Information architecture & navigation

The app has **four primary work areas** plus **setup/onboarding**:
`Capture` · `Compose` · `Rules` · `Realtime` · `Setup`.

**macOS layout (current):** `NavigationSplitView`.
- A mode switcher (segmented, icon-only) picks the work area.
- **Sidebar** = the list/navigator for the current mode (flows, requests +
  collections + history, rules + SSL allowlist, realtime connection config).
- **Detail** = the editor/inspector for the selected item.
- A **toolbar** holds global actions: Start/Stop proxy, System Proxy toggle,
  Environment picker (in Compose), and a "Setup" menu (reveal CA, export iOS
  profile, import cURL/OpenAPI/Postman, export HAR, clear flows).
- A persistent **bottom status bar**: proxy state dot, status message, flow
  count, active-rules count, listen address `IP:port`.
- Modal **sheets**: Import cURL, Breakpoint editor.
- Native **menu bar commands**: New Request (⌘N), Start/Stop Proxy (⌘P),
  toggle system proxy, reveal CA, export profile, clear flows.

**iOS layout (current):** `TabView` with 5 tabs (Capture, Compose, Rules,
Realtime, Setup), each a `NavigationStack`. Lists push to detail screens. Modals
are sheets (Library, Import cURL, Breakpoint — breakpoint presents globally over
any tab). Sharing via the system share sheet. File import via the system file
importer.

> You may **redesign the navigation model itself** if you have a better idea
> (e.g. macOS unified toolbar treatment, iOS inspector sheets, an iPad
> three-column layout), **as long as all five areas and every feature below
> remain reachable on both platforms.** Call out any IA changes explicitly.

---

## 5. Global / shared components (design a reusable library)

These appear across many screens — design them once as a system:

1. **Method badge** — small colored pill: `GET/POST/PUT/PATCH/DELETE/HEAD/…`
   (color per §3). Used in lists and editors.
2. **Status indicator** — status code with semantic color; also a tri-state for
   in-flight (`···` pending), `ERR` failed, or the numeric code.
3. **Secure indicator** — lock (green, "HTTPS decrypted") vs open-lock (gray,
   "HTTP").
4. **Connection dot** — green/gray/red 8pt dot for realtime + proxy state.
5. **Key/Value editor** — repeatable rows of `[enabled toggle] [key] [value]
   [delete]` + "Add" affordance. Used for query params, headers, rewrite
   headers. Needs a clean compact look that scales to many rows.
6. **Header table** — read-only two-column (name / value) monospaced list of
   response/request headers, value selectable/copyable.
7. **Code viewer** — read-only, scrollable (both axes), monospaced, selectable
   text with a distinct "code surface" background. Shows pretty-printed JSON,
   raw bodies, generated code, etc.
8. **Body/message viewer** — segmented `Headers / Body / Preview` (+ `Tests` for
   API responses). "Preview" renders **HTML** (WebView) or **images**; falls
   back to an empty state for other types.
9. **Realtime message row** — direction icon (↙ incoming green / ↗ outgoing blue
   / ⓘ system gray) + monospaced text. Streams/auto-scrolls.
10. **Empty / unavailable states** — every list and detail pane needs a
    purposeful empty state (icon + title + guidance), e.g. "No captured traffic
    — start the proxy and route traffic through `IP:port`."
11. **Loading/sending state** — inline spinner on the Send button and a status
    message; flows that are still in-flight show pending.
12. **Share/export affordance** — iOS share sheet; macOS Finder reveal. For CA
    (.pem), iOS profile (.mobileconfig), HAR file.

Design **tokens** for: type scale (proportional + mono), spacing, radius,
elevation/shadow, the accent gradient, semantic colors, list row metrics, and
surfaces for light + dark.

---

## 6. Screen-by-screen specification

For **each** screen below, deliver: layout, all states (empty / loading /
populated / error), the component breakdown, and both platforms.

### 6.1 Capture — traffic list (Charles "sequence" view)

**Purpose:** live-streaming list of captured request/response "flows".

**Controls (header):**
- Start/Stop proxy button (green play / red stop), reflects running state.
- Listen address `deviceIP:proxyPort` (monospaced) and a Listening/Stopped label.
- (macOS) System Proxy toggle in toolbar. (iOS shows manual-proxy guidance in
  Setup instead — system proxy is OS-restricted on iOS.)
- Overflow menu: **Export HAR**, **Clear flows** (disabled when empty).
- **Filter field** ("Filter host, path or method") — live-filters the list.

**Row content (per flow):** secure lock icon · method badge · host (emphasis) ·
path (secondary) · status code (semantic color) · duration in ms. Rows stream in
newest-first and update in place as responses complete.

**States:** empty (proxy stopped → "Start the proxy…"; proxy running, no traffic
→ "Point a device's Wi-Fi proxy at `IP:port` and trust the HTTrail CA");
populated; a row mid-flight (pending `···`); a failed row (`ERR`).

**Tap/select →** Flow Inspector (6.2).

### 6.2 Flow Inspector — request/response detail

**Purpose:** inspect one captured flow in full.

**Header:** method badge · full URL (monospaced, selectable) · secure label ·
status (colored) · duration · error (if any). An actions menu:
- **Edit & Resend (Compose)** — clones the flow into the Compose editor.
- **Copy as cURL** — copies a cURL command to the clipboard.

**Body:** segmented **Request / Response**. Each shows the shared
**Body/message viewer** (Headers / Body / Preview):
- Headers → header table.
- Body → pretty-printed (JSON) / raw in the code viewer.
- Preview → HTML render (WebView) or image; else "No preview" with the
  content-type noted.
- Response with no body yet → "No response / still in flight" empty state.

### 6.3 Compose — request editor (Hoppscotch REST/GraphQL client)

**Purpose:** compose, send, and iterate on an API request.

**Request bar:** HTTP method picker (`GET POST PUT PATCH DELETE HEAD OPTIONS`) ·
URL field (monospaced, autocaps/autocorrect off) · **Send** button (shows a
spinner while sending; ⌘↩ on macOS). Overflow: **Save to Collection**,
**Duplicate**.

**Config tabs** (segmented): `Params · Headers · Auth · Body · GraphQL · Scripts
· Code`.
- **Params / Headers** → key/value editor.
- **Auth** → type picker `None / Bearer / Basic / API key`, with the right
  fields per type (Bearer: token; Basic: username + secure password; API key:
  key, value, and an "add to header vs query param" toggle).
- **Body** → body-mode picker (`none / raw / form / …`) + a monospaced text
  editor (hidden when mode = none).
- **GraphQL** → a Query editor + a Variables (JSON) editor + "Use GraphQL body
  mode".
- **Scripts** → **Pre-request script** and **Test script** editors (JavaScript;
  `pm.*` API like Postman). Show short inline hints/examples.
- **Code** → a target picker (cURL and other codegen targets) + read-only
  generated code (code viewer) for the current request.

**Response viewer** (appears after Send): a status header (code in semantic
color, duration ms, byte size, test pass/fail seal `n/m`, error text) +
segmented `Body / Headers / Preview / Tests`:
- Body → pretty/raw code viewer. Headers → header table. Preview → HTML/image.
- **Tests** → list of test results (✓/✗ name + failure message) and a Console
  log section.

**Library** (collections/history navigator):
- **Open Requests** — the working set of request tabs/items.
- **Collections** — nested folders → requests (recursive tree); tap a request to
  open a copy. (Hoppscotch collections, arbitrarily nested.)
- **History** — recent sends (method · URL · status), tap to reload; "Clear
  History".
- (macOS) this is the **sidebar**; (iOS) it's a **sheet** opened from the
  Compose toolbar.

**Environment picker:** choose the active environment (set of `{{variables}}`)
or "No Environment"; "Add Environment". Variables resolve into URL/headers/body
and can be mutated by scripts. (macOS: toolbar menu; iOS: toolbar menu.)

**Imports (modals/importers):**
- **Import cURL** — paste a cURL command → new request.
- **Import OpenAPI / Postman** — pick a `.json` → imported as a collection.

### 6.4 Rules — interception rules (Charles tools)

**Purpose:** manipulate matching traffic inside the proxy.

**List:** rules with an enabled checkmark, name, and kind label; add (＋) and
delete. Plus an **SSL Proxying Allowlist** editor — one host glob per line
(empty = decrypt everything). Live-applies on change.

**Rule editor (per rule):**
- **Match** section: name, enabled toggle, **Action** picker, URL pattern (glob,
  monospaced).
- **Action** is one of, each with its own params:
  - **Block** — respond with a chosen status code (stepper 100–599).
  - **Map Local** — serve a local file path + content-type.
  - **Map Remote** — redirect to host + port + TLS toggle.
  - **Rewrite Request / Rewrite Response** — set headers (key/value editor) +
    body find/replace; Rewrite Response also can override status (0 = keep).
  - **Throttle** — delay in ms (stepper, 0–60000).
  - **Breakpoint** — pause on request and/or response for manual editing.
- Empty state when nothing selected: explain rules run inside the proxy (block,
  map, rewrite, throttle, breakpoint).

**Breakpoint modal** (fires live when a breakpoint rule matches): shows phase
(Request/Response) + URL, a monospaced editable **body** field, and two actions:
**Continue Unchanged** / **Apply & Continue**. It must be **non-dismissible by
accident** (it's blocking live traffic) and able to appear over any screen.

### 6.5 Realtime — WebSocket / Socket.IO / SSE / MQTT

**Purpose:** connect to a realtime endpoint and exchange messages.

**Connection config:**
- **Protocol** segmented: `WebSocket / Socket.IO / SSE / MQTT` (disabled while
  connected).
- WebSocket/Socket.IO/SSE → a single URL field (placeholder hints per protocol:
  `wss://…`, `https://… (Socket.IO)`, `https://… (SSE stream)`); Socket.IO also
  has an **Event name** field.
- MQTT → broker **host**, **port**, **topic** fields.
- **Connect / Disconnect** button + connection dot.

**Message log:** streaming, auto-scrolling list of message rows (incoming /
outgoing / system), monospaced, selectable.

**Composer:** message field + Send. **SSE is receive-only** → the composer is
disabled and labeled "Receive-only stream". MQTT publishes to the topic;
Socket.IO emits the named event; WebSocket sends text.

### 6.6 Setup / Trust — onboarding & artifacts

**Purpose:** get the device-under-test to trust HTTrail and route through it.

- **Certificate Authority:** explain the need; **Share Root CA (.pem)** and
  **Share iOS Profile (.mobileconfig)** (iOS share sheet / macOS reveal+menu).
- **This device:** IP address, proxy port, proxy running/stopped.
- **Capture:** **Export HAR** of captured flows + flow count.
- **How to capture another device:** numbered steps (start proxy → set the other
  device's Wi-Fi HTTP proxy to `IP:port` → install & trust the CA → traffic
  appears in Capture).
- A status line echoing the latest app status message.

> On **macOS** these actions currently live in the toolbar "Setup" menu and the
> menu bar rather than a dedicated screen. You may design a proper **Setup/Trust
> screen or onboarding flow** for macOS too — recommended. A **first-run
> onboarding** that walks through CA install + proxy setup would be a strong
> addition (propose it).

---

## 7. Cross-platform parity requirement

Every capability in §6 must exist on **both** macOS and iOS. The shared
application logic is identical (one model backs both apps); only the **shell**
differs. So:

- Don't design an iOS-only or macOS-only feature.
- Do adapt **layout**: macOS = multi-pane, dense, keyboard-driven, menu bar,
  hover affordances; iOS = tabbed, push-navigation, touch targets ≥44pt, sheets,
  swipe actions, share sheet. iPad (the iOS build also runs on iPad) is an
  opportunity for a **three-column** layout — propose it.

---

## 8. States, edge cases & micro-interactions to design

- Proxy: stopped / starting / listening / failed-to-start (with reason).
- Flow: pending (in-flight) / completed / failed; live insert + in-place update.
- Send: idle / sending (spinner) / success / error; test summary seal.
- Realtime: disconnected / connecting / connected / error / stream-ended;
  receive-only (SSE) composer disabled.
- Breakpoint: a blocking modal that can interrupt at any moment.
- Empty states for: flows, headers, body, preview (unsupported type), no request
  selected, no rule selected, no environment, no history.
- Long values (URLs, headers, payloads) — truncation + selection/copy behavior.
- Secure vs insecure visual treatment must be instantly legible.
- Filtering with no matches.

---

## 9. Data dictionary (the real content your screens render)

- **Flow:** id, secure(bool), state(pending/completed/failed), request, response?,
  statusCode?, durationMS?, error?.
- **Request (captured):** method, url, host, path, headers[name,value], body(Data),
  header(name) lookup.
- **Response (captured/API):** statusCode, headers[name,value], body(Data),
  contentType?, durationMS, error?.
- **APIRequest (compose):** name, method, url, queryParams[KV], headers[KV],
  auth{type, token, username, password, key, value, addToHeader}, bodyMode,
  rawBody, graphqlQuery, graphqlVariables, preRequestScript, testScript.
- **KeyValueItem:** enabled(bool), name, value.
- **RequestEnvironment:** name, variables[KV] → resolved `{{var}}` map.
- **RequestCollection:** name, requests[], folders[] (recursive).
- **HistoryEntry:** request, statusCode, durationMS, timestamp.
- **InterceptRule:** name, enabled, kind, urlPattern, + kind-specific fields
  (blockStatus, localFilePath/localContentType, remoteHost/remotePort/remoteTLS,
  setHeaders[KV]/findText/replaceText/setStatus, throttleMS,
  breakRequest/breakResponse).
- **RealtimeMessage:** direction(incoming/outgoing/system), text, timestamp.
- **ScriptOutput:** logs[String], tests[(name, passed, message?)].

---

## 10. Deliverables requested from you (the designer)

1. **Design language / system:** tokens (color incl. light+dark, type, spacing,
   radius, elevation), the accent gradient usage, iconography direction.
2. **Component library:** every item in §5, in all states.
3. **Screen designs for all of §6**, **for both macOS and iOS** (and an iPad
   layout proposal), in **light and dark**, including every state in §8.
4. **Key flows** as connected screens: (a) capture → inspect → edit & resend;
   (b) compose → send → read tests; (c) create a rule → breakpoint fires → edit
   & continue; (d) first-run trust/onboarding (CA + proxy setup); (e) connect a
   realtime endpoint and exchange messages.
5. **Navigation/IA recommendation** — keep or improve §4; call out any changes
   and why.
6. **Redlines / spec** sufficient for SwiftUI implementation (metrics, semantic
   color mapping, behavior notes).

## 11. Visual direction (guidance, not a cage)

Modern developer-tool aesthetic: confident dark mode, the gradient "signal"
accent used sparingly for brand/active/realtime moments, crisp monospaced
payloads, strong semantic color discipline, dense but breathable lists, and a
trustworthy treatment of the security/trust surfaces (CA, lock, breakpoints).
Think "Charles meets a beautifully native, modern Hoppscotch." Keep the
**packet-trail** metaphor alive in motion (streaming flows, realtime messages,
connection states).
