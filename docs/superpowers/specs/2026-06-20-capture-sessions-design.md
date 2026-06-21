# Capture Sessions + Resource-Type Filter — Design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)
**Scope:** macOS app + iOS app (shared `HTTrailCore`)

## 1. Goal

Today captured flows are a single flat, ephemeral list: in memory on macOS
(`AppModel.flows`), and a bounded NDJSON file on iOS (`SharedFlowStore`). There
is no way to group a capture run, name it, revisit it after relaunch, or prune
it. This change introduces **capture sessions**:

- Pressing **Start** opens a new session named with a date-time
  (`Capture 2026-06-20 14:32:05`); captured flows belong to that session.
- Sessions persist to disk and survive app relaunch.
- A **Sessions** surface lists past sessions with their record counts.
- Sessions are editable: **rename**, **notes**, **delete the whole session**,
  and **delete selected requests** within a session.
- Any session can be **exported as HAR**.
- The flow list gains a **Chrome-style resource-type filter**: All / XHR-JSON /
  HTML / JS / CSS / Image / Other.

All logic lands in `HTTrailCore` (tested via `swift test`); the macOS and iOS
view layers stay thin and both bind to the shared `AppModel`.

## 2. Data model

### 2.1 `Flow` gains a session stamp

`Sources/HTTrailCore/Model/Flow.swift`:

```swift
public var sessionID: UUID?   // nil for legacy/unsessioned flows
```

Optional + `Codable` ⇒ old persisted/shared flows decode with `nil`. The
initializer gets a defaulted `sessionID: UUID? = nil` parameter so existing call
sites are unchanged.

### 2.2 `CaptureSession` (new)

`Sources/HTTrailCore/Model/CaptureSession.swift`:

```swift
public struct CaptureSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String        // default "Capture YYYY-MM-DD HH:mm:ss"
    public var notes: String       // free text, default ""
    public var startedAt: Date
    public var endedAt: Date?      // nil while actively recording
    public var recordCount: Int    // cached, kept in sync with the file
}
```

`recordCount` is cached in the index so the Sessions list shows counts without
reading every flow file. A helper builds the default date-time name.

### 2.3 `ResourceType` (new)

`Sources/HTTrailCore/Model/ResourceType.swift`:

```swift
public enum ResourceType: String, CaseIterable, Codable, Sendable {
    case xhr, html, js, css, image, other
    public var label: String          // "XHR/JSON", "HTML", ...
    public var systemImage: String    // SF Symbol for filter chips
    public static func classify(_ flow: Flow) -> ResourceType
}
```

Classification order (first match wins), using the **response** Content-Type,
falling back to the request URL's path extension when the type is missing or
`application/octet-stream`:

| Bucket | Content-Type contains / URL ext |
|--------|----------------------------------|
| `image` | `image/` · `.png .jpg .jpeg .gif .webp .svg .ico .bmp` |
| `css`   | `text/css` · `.css` |
| `js`    | `javascript`, `ecmascript` · `.js .mjs` |
| `html`  | `text/html` · `.html .htm` |
| `xhr`   | `json`, `+json`, `xml`, `+xml`, `application/grpc`, `text/event-stream` · `.json .xml` |
| `other` | everything else (fonts, plain text, binary, no response yet) |

"All" is represented by an **empty** filter set (no enum case), so the default
state shows everything.

> Note: `xhr` is the Chrome "Fetch/XHR" bucket — any JSON/XML/fetch-style
> payload regardless of HTTP method (so GraphQL/`application/json` POSTs land
> here).

## 3. Persistence — `CaptureSessionStore` (new)

`Sources/HTTrailCore/Persistence/CaptureSessionStore.swift`. Approach A from
brainstorming: a per-session NDJSON file plus a small JSON index, mirroring the
existing `SharedFlowStore` NDJSON machinery.

Layout under `AppPaths.supportDirectory/sessions/`:

- `index.json` — `[CaptureSession]`, newest-first (metadata only).
- `<uuid>.ndjson` — that session's flows, one JSON `Flow` per line, **upserted
  by `flow.id`** (a flow appears `.pending` then `.completed`, exactly like
  `SharedFlowStore`).

API (serialized on a private `DispatchQueue`, `@unchecked Sendable`):

```swift
func allSessions() -> [CaptureSession]
func createSession(name: String, startedAt: Date) -> CaptureSession   // prepends to index
func record(_ flow: Flow, in id: UUID)        // upsert into <id>.ndjson + bump recordCount
func flows(in id: UUID) -> [Flow]             // newest-first
func endSession(_ id: UUID, at: Date)         // set endedAt
func rename(_ id: UUID, to name: String)
func setNotes(_ id: UUID, _ notes: String)
func deleteSession(_ id: UUID)                // remove file + index entry
func deleteFlows(_ ids: Set<UUID>, in id: UUID)   // rewrite file, recompute recordCount
```

Per-flow `record` rewrites only the one session file (the same atomic
rewrite-the-whole-file strategy `SharedFlowStore` already uses; acceptable
because a session file is bounded by a capture run, and writes are coalesced on
the store's queue). `recordCount` is updated in the index on insert/delete.

**Single writer:** the **app process** is the only writer of the session store on
both platforms (see §6). The store reuses `JSONEncoder`/`JSONDecoder` like the
existing stores; no new dependencies.

## 4. `AppModel` changes

`Sources/HTTrailCore/UI/AppModel.swift`. New published state:

```swift
@Published public var sessions: [CaptureSession] = []      // loaded at init
@Published public var activeSessionID: UUID?               // recording target
@Published public var viewingSessionID: UUID?              // which session the list shows
@Published public var resourceTypeFilter: Set<ResourceType> = []   // empty = All
@Published public var selectedFlowIDs: Set<Flow.ID> = []   // list selection (multi-select)
private var viewingFlows: [Flow] = []                       // loaded when viewing a past session
private let sessionStore = CaptureSessionStore()
```

The macOS flow `List` binds to `selectedFlowIDs` (a `Set`, enabling ⌘/⇧
multi-select for delete). `selectedFlow` is derived as the sole member when
exactly one row is selected, driving the detail inspector; the existing
`selectedFlowID` property is removed in favor of this. On iOS, navigation uses a
`NavigationLink` per row (unchanged) and multi-delete uses `EditMode` with its
own selection set bound to `selectedFlowIDs`.

### 4.1 Lifecycle

- `beginCaptureSession(resuming id: UUID? = nil)` — establishes the recording
  target, clears the live `flows` array and (iOS) the `SharedFlowStore` so its
  residue isn't misattributed, then sets `activeSessionID` and viewing.
  - **New session** (`id == nil`): creates a session (date-time name), prepends
    it to `sessions`.
  - **Resume existing** (`id` given): reopens that session (`endedAt = nil`),
    loads its persisted flows into the live `flows` array so new captures append
    to what's already there.
- `endCaptureSession()` — marks the active session `endedAt`; clears
  `activeSessionID`. Called from `stopProxy()` and the iOS VPN stop site.

The user chooses the target before starting (§5.3): start a **New Session** or
**resume a previously-selected session**.
- `ingest(_:)` — stamps `flow.sessionID = activeSessionID`, upserts into live
  `flows` (unchanged behavior for the active session), and persists via
  `sessionStore.record(flow, in: activeSessionID)`. Updates the cached
  `recordCount` on the in-memory `sessions` entry so the list stays live.

### 4.2 Viewing & filtering

```swift
public var displayedFlows: [Flow]      // active/nil → live `flows`; else `viewingFlows`
public var filteredFlows: [Flow]       // displayedFlows ▸ text filter ▸ resource-type filter
public func viewSession(_ id: UUID?)   // sets viewingSessionID; loads viewingFlows from store
public func toggleResourceType(_ t: ResourceType)
```

`filteredFlows` keeps the existing URL/host/method text match and ANDs it with
`resourceTypeFilter.isEmpty || resourceTypeFilter.contains(ResourceType.classify(flow))`.

### 4.3 Editing

```swift
public func renameSession(_ id: UUID, to: String)
public func setSessionNotes(_ id: UUID, _ notes: String)
public func deleteSession(_ id: UUID)             // store + sessions; fix viewing/active
public func deleteSelectedFlows()                  // from viewing session; updates list + count
```

All mutate the store then refresh the in-memory `sessions`/flow arrays.

### 4.4 HAR export per session

`exportHAR()` is generalized to `exportHAR(sessionID:)` (defaults to the viewing
session). It reads `sessionStore.flows(in:)` (or live `flows` for the active
session), reverses to chronological order, runs the existing `HARExporter`, and
writes `HTTrail-<sessionname>-<ts>.har`. The macOS Finder-reveal / iOS
share-sheet behavior is preserved.

## 5. UI

### 5.1 Sessions surface (the "main page")

A **Sessions list** becomes the entry point of Capture mode:

- Rows: session name, relative date-time, **record count** badge, and a red
  **REC** dot for the active session.
- Row actions (context menu on macOS, swipe on iOS): Rename, Edit Notes,
  Export HAR…, Delete.
- Selecting a session opens its **flow list**.

macOS (2-column `NavigationSplitView`): the Capture sidebar shows the Sessions
list when `viewingSessionID == nil`, and the session's flow list (with a back
chevron + the session title) when a session is selected. Detail column keeps
`FlowInspector`. iOS (`NavigationStack`): Sessions → Flow list → `FlowInspector`.

### 5.2 Flow list additions

- A horizontal **resource-type filter chip row** above the search field: All,
  XHR/JSON, HTML, JS, CSS, Image, Other — multi-select toggles bound to
  `resourceTypeFilter` (All = clear). Each chip shows its SF Symbol + label.
- **Multi-select delete:** macOS uses `List(selection: $model.selectedFlowIDs)`
  with a Delete button / ⌫ key; iOS uses `EditMode` with a Delete toolbar action.
  Deleting routes to `deleteSelectedFlows()`.
- The existing search field and `FlowRow`/`FlowInspector` are unchanged.

### 5.3 Start target selection (New vs. existing session)

Pressing **Start** records into a chosen target session:

- **Start** is a split control: the primary action starts a **New Session**; an
  adjacent menu lists existing sessions ("Resume <name> · N records") plus
  "New Session". macOS uses a `Menu`/`Button` pair in the toolbar; iOS uses a
  `Menu` on the Start button in the `CaptureView` control bar.
- Convenience: from a session's flow list, a **Resume / Record into this
  session** action starts capture with that session as the target.
- `startProxy()` takes the chosen target: `startProxy(resuming:)` →
  `beginCaptureSession(resuming:)`. `toggleProxy()` defaults to a new session
  when no target is specified; **Stop** ends the active session.
- iOS VPN start/stop (`SetupView` via `VPNController`) calls
  `model.beginCaptureSession(resuming:)` / `model.endCaptureSession()` at the
  start/stop sites (defaulting to new) so VPN-captured flows are attributed to a
  session too.

## 6. Cross-process (iOS) strategy

The iOS VPN **extension** keeps writing to the existing `SharedFlowStore`
(`captured-flows.ndjson`) — **no extension changes**. The **app** remains the
single writer of the session store:

1. `beginCaptureSession()` clears `SharedFlowStore` so any residue is not
   attributed to the new session, and sets `activeSessionID`.
2. The existing 1.5s tail timer (`refreshSharedFlows`) reads new flows and feeds
   them through `ingest(_:)`, which stamps the active `sessionID` and persists
   them into the active session's file.

This reuses the established tail mechanism and avoids touching the
`PacketTunnel` target. Accepted edge case: flows captured by the VPN while the
app is killed accumulate in the bounded shared file and are attributed to the
then-active session when the app next tails — acceptable for v1. (`SharedConfig`
is **not** changed.)

## 7. Migration / back-compat

- No migration of pre-existing flows is required (macOS flows were memory-only;
  iOS shared flows are ephemeral). On first launch post-update there are simply
  zero sessions until the user presses Start.
- `Flow.sessionID` defaults to `nil`; older shared/HAR data decodes cleanly.

## 8. Testing (`Tests/HTTrailCoreTests/`)

- **`ResourceTypeTests`** — table-driven: each Content-Type and URL-extension
  fallback maps to the expected bucket; missing/`octet-stream` falls back to URL
  ext then `.other`.
- **`CaptureSessionStoreTests`** — create → record (pending then completed upsert
  collapses to one entry) → `flows(in:)` order → `recordCount` accuracy →
  rename/notes → `deleteFlows` rewrites + recomputes count → `deleteSession`
  removes file + index → survives a fresh store instance (persistence).
- **`AppModelSessionTests`** (`@MainActor`) — `startProxy`/`beginCaptureSession`
  creates an active session; `ingest` stamps `sessionID`, updates live `flows`
  and the cached count; `filteredFlows` honors text + resource-type filters and
  the viewing session; **resuming** an ended session reopens it
  (`endedAt == nil`), loads its prior flows into `flows`, and subsequent
  `ingest`s append to it; `deleteSelectedFlows`/`deleteSession` update state;
  `endCaptureSession` sets `endedAt`.
- **HAR per session** — `exportHAR(sessionID:)` round-trips a session's flows
  through `HARExporter` (reuse/extend existing HAR test).

## 9. Out of scope

- Reworking the iOS extension to write per-session files directly.
- `SharedConfig` session propagation / extension-side stamping.
- Capturing flows attributed to multiple simultaneously-active sessions.
- Search/filter persistence across launches.
