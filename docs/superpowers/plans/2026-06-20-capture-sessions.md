# Capture Sessions + Resource-Type Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group captured flows into named, on-disk capture **sessions** (start new or resume existing), browse past sessions with record counts, edit them (rename, notes, delete whole session, delete selected requests), export any session as HAR, and filter the flow list by Chrome-style resource type (All / XHR-JSON / HTML / JS / CSS / Image / Other).

**Architecture:** All logic lives in `HTTrailCore` and is unit-tested via `swift test`. A new `CaptureSessionStore` persists each session as `sessions/<uuid>.ndjson` plus a `sessions/index.json` metadata index (reusing the existing `SharedFlowStore` upsert-by-id NDJSON pattern). `AppModel` gains session state + lifecycle and routes every captured flow through `ingest`, stamping `Flow.sessionID` and persisting it. The app process is the sole writer of the session store on both platforms; the iOS VPN extension is untouched (the app clears `SharedFlowStore` on session start and stamps tailed flows). The macOS and iOS view layers stay thin and bind to the shared `AppModel`; shared SwiftUI chip/row pieces go in `HTTrailCore/UI`.

**Tech Stack:** Swift 5 (core target language mode), SwiftUI, Foundation `JSONEncoder/Decoder`, SwiftNIO (unchanged), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-20-capture-sessions-design.md`

> **Git note:** This working copy is not currently a git repository. If you want the `git commit` checkpoints below, run `git init` first; otherwise treat each "Commit" step as a checkpoint to pause and review. Per-feature tests can be run in isolation (e.g. `swift test --filter ResourceTypeTests`) to avoid the slow live MITM integration test.

---

## File Structure

**Create (core):**
- `Sources/HTTrailCore/Model/CaptureSession.swift` — session metadata value type + default-name helper.
- `Sources/HTTrailCore/Model/ResourceType.swift` — resource-type enum + `classify(_:)`.
- `Sources/HTTrailCore/Persistence/CaptureSessionStore.swift` — per-session NDJSON + index persistence.
- `Sources/HTTrailCore/UI/SessionComponents.swift` — shared SwiftUI: `ResourceFilterBar`, `SessionRow`.

**Create (tests):**
- `Tests/HTTrailCoreTests/ResourceTypeTests.swift`
- `Tests/HTTrailCoreTests/CaptureSessionStoreTests.swift`
- `Tests/HTTrailCoreTests/CaptureSessionModelTests.swift` (AppModel session behavior)

**Modify (core):**
- `Sources/HTTrailCore/Model/Flow.swift` — add `sessionID`.
- `Sources/HTTrailCore/UI/AppModel.swift` — session state, lifecycle, ingest, filtering, editing, per-session HAR; replace `selectedFlowID` with `selectedFlowIDs`.

**Modify (macOS app):**
- `Sources/HTTrail/Views/CaptureView.swift` — sessions list + flow list, filter bar, multi-select.
- `Sources/HTTrail/Views/RootView.swift` — Start split control, `selectedFlow` usage.

**Modify (iOS app):**
- `iosapp/Sources/CaptureView.swift` — sessions NavigationStack, filter bar, EditMode multi-delete, Start menu.
- `iosapp/Sources/SetupView.swift` — call `beginCaptureSession`/`endCaptureSession` around VPN start/stop.

---

## Task 1: Add `sessionID` to `Flow`

**Files:**
- Modify: `Sources/HTTrailCore/Model/Flow.swift:78-100`

- [ ] **Step 1: Add the property and init parameter**

In `Sources/HTTrailCore/Model/Flow.swift`, add a stored property to `Flow` after `secure` (line 87) and a defaulted init parameter so existing call sites are unchanged.

Add after `public var secure: Bool`:

```swift
    /// The capture session this flow belongs to (nil for legacy/unsessioned flows).
    public var sessionID: UUID?
```

Change the initializer signature from:

```swift
    public init(id: UUID = UUID(), request: CapturedRequest, response: CapturedResponse? = nil,
                state: FlowState = .pending, error: String? = nil, startedAt: Date,
                endedAt: Date? = nil, secure: Bool) {
```

to:

```swift
    public init(id: UUID = UUID(), request: CapturedRequest, response: CapturedResponse? = nil,
                state: FlowState = .pending, error: String? = nil, startedAt: Date,
                endedAt: Date? = nil, secure: Bool, sessionID: UUID? = nil) {
```

And add at the end of the init body (after `self.secure = secure`):

```swift
        self.sessionID = sessionID
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors (the defaulted parameter keeps all existing `Flow(...)` calls valid).

- [ ] **Step 3: Commit**

```bash
git add Sources/HTTrailCore/Model/Flow.swift
git commit -m "feat: add sessionID to Flow"
```

---

## Task 2: `ResourceType` enum + classifier (TDD)

**Files:**
- Create: `Sources/HTTrailCore/Model/ResourceType.swift`
- Test: `Tests/HTTrailCoreTests/ResourceTypeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/ResourceTypeTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class ResourceTypeTests: XCTestCase {
    private func flow(contentType: String?, path: String) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://e/\(path)", scheme: "https",
                                  host: "e", port: 443, path: path, httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = contentType.map {
            CapturedResponse(statusCode: 200, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                             headers: [HeaderPair(name: "Content-Type", value: $0)],
                             body: Data(), timestamp: Date())
        }
        return Flow(request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testClassifiesByContentType() {
        XCTAssertEqual(ResourceType.classify(flow(contentType: "image/png", path: "/a")), .image)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/css", path: "/a")), .css)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/javascript", path: "/a")), .js)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/html; charset=utf-8", path: "/a")), .html)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/json", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/xml", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/event-stream", path: "/a")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "text/plain", path: "/a")), .other)
    }

    func testFallsBackToURLExtensionWhenTypeMissingOrOctetStream() {
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/app.js?v=2")), .js)
        XCTAssertEqual(ResourceType.classify(flow(contentType: "application/octet-stream", path: "/logo.png")), .image)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/data.json")), .xhr)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/index.html")), .html)
        XCTAssertEqual(ResourceType.classify(flow(contentType: nil, path: "/")), .other)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ResourceTypeTests`
Expected: FAIL — `cannot find 'ResourceType' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HTTrailCore/Model/ResourceType.swift`:

```swift
import Foundation

/// Chrome-DevTools-style resource buckets used by the capture filter. "All" is
/// represented by an empty selection set (no enum case).
public enum ResourceType: String, CaseIterable, Codable, Sendable {
    case xhr, html, js, css, image, other

    public var label: String {
        switch self {
        case .xhr: return "XHR/JSON"
        case .html: return "HTML"
        case .js: return "JS"
        case .css: return "CSS"
        case .image: return "Image"
        case .other: return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .xhr: return "arrow.left.arrow.right"
        case .html: return "doc.richtext"
        case .js: return "curlybraces"
        case .css: return "paintbrush"
        case .image: return "photo"
        case .other: return "ellipsis.circle"
        }
    }

    /// Classify a flow by its response Content-Type, falling back to the request
    /// URL's path extension when the type is missing or `application/octet-stream`.
    public static func classify(_ flow: Flow) -> ResourceType {
        let ct = (flow.response?.contentType ?? "").lowercased()
        if let byType = fromContentType(ct) { return byType }
        if let byExt = fromExtension(pathExtension(of: flow.request.path)) { return byExt }
        return .other
    }

    private static func fromContentType(_ ct: String) -> ResourceType? {
        if ct.isEmpty || ct.hasPrefix("application/octet-stream") { return nil }
        if ct.hasPrefix("image/") { return .image }
        if ct.contains("text/css") { return .css }
        if ct.contains("javascript") || ct.contains("ecmascript") { return .js }
        if ct.contains("text/html") { return .html }
        if ct.contains("json") || ct.contains("xml")
            || ct.contains("application/grpc") || ct.contains("text/event-stream") { return .xhr }
        return .other
    }

    private static func fromExtension(_ ext: String) -> ResourceType? {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp": return .image
        case "css": return .css
        case "js", "mjs": return .js
        case "html", "htm": return .html
        case "json", "xml": return .xhr
        default: return nil
        }
    }

    private static func pathExtension(of path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return (withoutQuery as NSString).pathExtension.lowercased()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ResourceTypeTests`
Expected: PASS (both test methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTrailCore/Model/ResourceType.swift Tests/HTTrailCoreTests/ResourceTypeTests.swift
git commit -m "feat: add ResourceType classifier"
```

---

## Task 3: `CaptureSession` model

**Files:**
- Create: `Sources/HTTrailCore/Model/CaptureSession.swift`

- [ ] **Step 1: Write the implementation**

Create `Sources/HTTrailCore/Model/CaptureSession.swift`:

```swift
import Foundation

/// One named capture run. Persisted in `sessions/index.json`; its flows live in
/// a sibling `<id>.ndjson`. `recordCount` is cached so the sessions list can show
/// counts without reading every flow file.
public struct CaptureSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var notes: String
    public var startedAt: Date
    /// nil while the session is actively recording.
    public var endedAt: Date?
    public var recordCount: Int

    public init(id: UUID = UUID(), name: String, notes: String = "",
                startedAt: Date, endedAt: Date? = nil, recordCount: Int = 0) {
        self.id = id
        self.name = name
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordCount = recordCount
    }

    public var isRecording: Bool { endedAt == nil }

    /// The default `Capture YYYY-MM-DD HH:mm:ss` name for a new session.
    public static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Capture " + formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/HTTrailCore/Model/CaptureSession.swift
git commit -m "feat: add CaptureSession model"
```

---

## Task 4: `CaptureSessionStore` persistence (TDD)

**Files:**
- Create: `Sources/HTTrailCore/Persistence/CaptureSessionStore.swift`
- Test: `Tests/HTTrailCoreTests/CaptureSessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/CaptureSessionStoreTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

final class CaptureSessionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-sessions-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> CaptureSessionStore { CaptureSessionStore(directory: dir) }

    private func flow(id: UUID = UUID(), host: String, status: Int?) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = status.map { CapturedResponse(statusCode: $0, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                                                 headers: [], body: Data(), timestamp: Date()) }
        return Flow(id: id, request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testCreateAndListSessionsNewestFirst() {
        let store = makeStore()
        let a = store.createSession(name: "A", startedAt: Date())
        let b = store.createSession(name: "B", startedAt: Date())
        let all = store.allSessions()
        XCTAssertEqual(all.map(\.name), ["B", "A"])
        XCTAssertEqual(all.first?.id, b.id)
        XCTAssertEqual(all.last?.id, a.id)
    }

    func testRecordUpsertsByIDAndTracksCount() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        let fid = UUID()
        store.record(flow(id: fid, host: "h", status: nil), in: s.id)   // pending
        store.record(flow(id: fid, host: "h", status: 200), in: s.id)   // completed (same id)
        store.record(flow(host: "h2", status: 200), in: s.id)           // new id

        let flows = store.flows(in: s.id)
        XCTAssertEqual(flows.count, 2, "same id replaces, not duplicates")
        XCTAssertEqual(store.allSessions().first { $0.id == s.id }?.recordCount, 2)
        XCTAssertEqual(flows.first?.request.host, "h2", "newest first")
    }

    func testPersistsAcrossStoreInstances() {
        let s = makeStore().createSession(name: "S", startedAt: Date())
        makeStore().record(flow(host: "h", status: 200), in: s.id)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.flows(in: s.id).count, 1)
        XCTAssertEqual(reloaded.allSessions().first?.recordCount, 1)
    }

    func testRenameNotesReopenAndEnd() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        store.rename(s.id, to: "Renamed")
        store.setNotes(s.id, "hello")
        let now = Date()
        store.endSession(s.id, at: now)
        var got = store.allSessions().first { $0.id == s.id }
        XCTAssertEqual(got?.name, "Renamed")
        XCTAssertEqual(got?.notes, "hello")
        XCTAssertNotNil(got?.endedAt)
        store.reopen(s.id)
        got = store.allSessions().first { $0.id == s.id }
        XCTAssertNil(got?.endedAt, "reopen clears endedAt")
    }

    func testDeleteSelectedFlowsRecomputesCount() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        let keep = UUID(); let drop = UUID()
        store.record(flow(id: keep, host: "keep", status: 200), in: s.id)
        store.record(flow(id: drop, host: "drop", status: 200), in: s.id)
        store.deleteFlows([drop], in: s.id)
        XCTAssertEqual(store.flows(in: s.id).map(\.request.host), ["keep"])
        XCTAssertEqual(store.allSessions().first?.recordCount, 1)
    }

    func testDeleteSessionRemovesFileAndIndexEntry() {
        let store = makeStore()
        let s = store.createSession(name: "S", startedAt: Date())
        store.record(flow(host: "h", status: 200), in: s.id)
        store.deleteSession(s.id)
        XCTAssertTrue(store.allSessions().isEmpty)
        XCTAssertTrue(store.flows(in: s.id).isEmpty)
        let file = dir.appendingPathComponent("\(s.id.uuidString).ndjson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSessionStoreTests`
Expected: FAIL — `cannot find 'CaptureSessionStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HTTrailCore/Persistence/CaptureSessionStore.swift`:

```swift
import Foundation

/// Persists capture sessions: metadata in `sessions/index.json` (newest-first)
/// and each session's flows in a sibling `<uuid>.ndjson` (one JSON `Flow` per
/// line, upserted by `flow.id` — a flow appears `.pending` then `.completed`).
/// The app process is the sole writer on both platforms. Mirrors the in-memory
/// order/byID upsert strategy of `SharedFlowStore`, but keyed per session.
public final class CaptureSessionStore: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let capacityPerSession: Int
    private let queue = DispatchQueue(label: "com.httrail.sessionstore")
    private var caches: [UUID: (order: [UUID], byID: [UUID: Flow])] = [:]

    public init(directory: URL = AppPaths.supportDirectory.appendingPathComponent("sessions", isDirectory: true),
                capacityPerSession: Int = 10_000) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.indexURL = directory.appendingPathComponent("index.json")
        self.capacityPerSession = capacityPerSession
    }

    // MARK: - Index

    public func allSessions() -> [CaptureSession] { queue.sync { loadIndexLocked() } }

    private func loadIndexLocked() -> [CaptureSession] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([CaptureSession].self, from: data)) ?? []
    }

    private func saveIndexLocked(_ sessions: [CaptureSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func mutateSessionLocked(_ id: UUID, _ change: (inout CaptureSession) -> Void) {
        var sessions = loadIndexLocked()
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        saveIndexLocked(sessions)
    }

    @discardableResult
    public func createSession(name: String, startedAt: Date) -> CaptureSession {
        queue.sync {
            var sessions = loadIndexLocked()
            let session = CaptureSession(name: name, startedAt: startedAt)
            sessions.insert(session, at: 0)
            saveIndexLocked(sessions)
            return session
        }
    }

    public func rename(_ id: UUID, to name: String) { queue.sync { mutateSessionLocked(id) { $0.name = name } } }
    public func setNotes(_ id: UUID, _ notes: String) { queue.sync { mutateSessionLocked(id) { $0.notes = notes } } }
    public func reopen(_ id: UUID) { queue.sync { mutateSessionLocked(id) { $0.endedAt = nil } } }
    public func endSession(_ id: UUID, at endedAt: Date) { queue.sync { mutateSessionLocked(id) { $0.endedAt = endedAt } } }

    public func deleteSession(_ id: UUID) {
        queue.sync {
            caches[id] = nil
            try? FileManager.default.removeItem(at: fileURL(id))
            var sessions = loadIndexLocked()
            sessions.removeAll { $0.id == id }
            saveIndexLocked(sessions)
        }
    }

    // MARK: - Flows

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).ndjson") }

    private func ensureCacheLocked(_ id: UUID) {
        if caches[id] != nil { return }
        var order: [UUID] = []
        var byID: [UUID: Flow] = [:]
        if let data = try? Data(contentsOf: fileURL(id)), !data.isEmpty {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let flow = try? decoder.decode(Flow.self, from: Data(line)) {
                    if byID[flow.id] == nil { order.append(flow.id) }
                    byID[flow.id] = flow
                }
            }
        }
        caches[id] = (order, byID)
    }

    private func persistFlowsLocked(_ id: UUID) {
        guard let cache = caches[id] else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for fid in cache.order {
            guard let flow = cache.byID[fid], let line = try? encoder.encode(flow) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL(id), options: .atomic)
    }

    public func record(_ flow: Flow, in id: UUID) {
        queue.sync {
            ensureCacheLocked(id)
            var cache = caches[id]!
            if cache.byID[flow.id] == nil {
                cache.order.append(flow.id)
                if cache.order.count > capacityPerSession, let evicted = cache.order.first {
                    cache.order.removeFirst()
                    cache.byID[evicted] = nil
                }
            }
            cache.byID[flow.id] = flow
            caches[id] = cache
            persistFlowsLocked(id)
            mutateSessionLocked(id) { $0.recordCount = cache.order.count }
        }
    }

    public func deleteFlows(_ ids: Set<UUID>, in id: UUID) {
        queue.sync {
            ensureCacheLocked(id)
            var cache = caches[id]!
            cache.order.removeAll { ids.contains($0) }
            for fid in ids { cache.byID[fid] = nil }
            caches[id] = cache
            persistFlowsLocked(id)
            mutateSessionLocked(id) { $0.recordCount = cache.order.count }
        }
    }

    /// All flows in the session, newest-first (matching the in-app list order).
    public func flows(in id: UUID) -> [Flow] {
        queue.sync {
            ensureCacheLocked(id)
            let cache = caches[id]!
            return cache.order.compactMap { cache.byID[$0] }.reversed()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureSessionStoreTests`
Expected: PASS (all 7 test methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTrailCore/Persistence/CaptureSessionStore.swift Tests/HTTrailCoreTests/CaptureSessionStoreTests.swift
git commit -m "feat: add CaptureSessionStore persistence"
```

---

## Task 5: AppModel session state, lifecycle & ingest (TDD)

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift`
- Test: `Tests/HTTrailCoreTests/CaptureSessionModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/HTTrailCoreTests/CaptureSessionModelTests.swift`:

```swift
import XCTest
@testable import HTTrailCore

@MainActor
final class CaptureSessionModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("httrail-model-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> AppModel {
        AppModel(sessionStore: CaptureSessionStore(directory: dir))
    }

    private func flow(id: UUID = UUID(), host: String, contentType: String?, status: Int? = 200) -> Flow {
        let req = CapturedRequest(method: "GET", url: "https://\(host)/x", scheme: "https",
                                  host: host, port: 443, path: "/x", httpVersion: "HTTP/1.1",
                                  headers: [], body: Data(), timestamp: Date())
        let resp = status.map { s in
            CapturedResponse(statusCode: s, reasonPhrase: "OK", httpVersion: "HTTP/1.1",
                             headers: contentType.map { [HeaderPair(name: "Content-Type", value: $0)] } ?? [],
                             body: Data(), timestamp: Date())
        }
        return Flow(id: id, request: req, response: resp, state: resp == nil ? .pending : .completed,
                    startedAt: Date(), endedAt: resp == nil ? nil : Date(), secure: true)
    }

    func testBeginSessionCreatesActiveSessionAndIngestStamps() {
        let model = makeModel()
        model.beginCaptureSession()
        let active = try! XCTUnwrap(model.activeSessionID)
        XCTAssertEqual(model.viewingSessionID, active)
        XCTAssertEqual(model.sessions.count, 1)

        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        XCTAssertEqual(model.flows.count, 1)
        XCTAssertEqual(model.flows.first?.sessionID, active)
        XCTAssertEqual(model.sessions.first?.recordCount, 1)
    }

    func testResumeReopensAndLoadsPriorFlows() {
        let model = makeModel()
        model.beginCaptureSession()
        let first = model.activeSessionID!
        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        model.endCaptureSession()
        XCTAssertNotNil(model.sessions.first { $0.id == first }?.endedAt)

        model.beginCaptureSession(resuming: first)
        XCTAssertEqual(model.activeSessionID, first)
        XCTAssertNil(model.sessions.first { $0.id == first }?.endedAt, "reopened")
        XCTAssertEqual(model.flows.count, 1, "prior flow reloaded")
        model.ingestForTesting(flow(host: "b", contentType: "text/html"))
        XCTAssertEqual(model.flows.count, 2)
    }

    func testFilteredFlowsHonorTextAndResourceType() {
        let model = makeModel()
        model.beginCaptureSession()
        model.ingestForTesting(flow(host: "api.test", contentType: "application/json"))
        model.ingestForTesting(flow(host: "cdn.test", contentType: "image/png"))

        model.resourceTypeFilter = [.image]
        XCTAssertEqual(model.filteredFlows.map(\.request.host), ["cdn.test"])

        model.resourceTypeFilter = []
        model.filterText = "api"
        XCTAssertEqual(model.filteredFlows.map(\.request.host), ["api.test"])
    }

    func testDeleteSelectedFlowsAndDeleteSession() {
        let model = makeModel()
        model.beginCaptureSession()
        let keep = UUID(); let drop = UUID()
        model.ingestForTesting(flow(id: keep, host: "keep", contentType: "application/json"))
        model.ingestForTesting(flow(id: drop, host: "drop", contentType: "application/json"))

        model.selectedFlowIDs = [drop]
        model.deleteSelectedFlows()
        XCTAssertEqual(model.flows.map(\.request.host), ["keep"])
        XCTAssertEqual(model.sessions.first?.recordCount, 1)

        let sessionID = model.activeSessionID!
        model.deleteSession(sessionID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.activeSessionID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSessionModelTests`
Expected: FAIL — `AppModel` has no `sessionStore:` initializer / no `beginCaptureSession` etc.

- [ ] **Step 3: Add session state + injectable store**

In `Sources/HTTrailCore/UI/AppModel.swift`, replace the capture published block (lines 61-74) — specifically replace the line `@Published public var selectedFlowID: Flow.ID?` and add session state. The block becomes:

```swift
    // Proxy / capture
    @Published public var flows: [Flow] = []
    @Published public var selectedFlowIDs: Set<Flow.ID> = []
    @Published public var isProxyRunning = false
    @Published public var proxyPort: Int = 9090
    @Published public var systemProxyEnabled = false
    /// Whether the HTTrail root CA is present/trusted (System keychain on macOS,
    /// loopback TLS probe on iOS).
    @Published public var caTrusted = false
    /// True while a CA-trust check is running (drives a spinner in Setup).
    @Published public var caCheckInProgress = false
    @Published public var statusMessage: String = "Idle"
    @Published public var filterText: String = ""
    @Published public var deviceIP: String = "—"

    // Capture sessions
    @Published public var sessions: [CaptureSession] = []
    /// The session currently being recorded into (nil when not capturing).
    @Published public var activeSessionID: UUID?
    /// Which session the flow list is showing (nil = the Sessions list itself).
    @Published public var viewingSessionID: UUID?
    /// Selected resource-type buckets; empty = show all.
    @Published public var resourceTypeFilter: Set<ResourceType> = []
    /// Flows of a non-active session being viewed (loaded on demand).
    private var viewingFlows: [Flow] = []
```

Change the stored `sessionStore` declaration. Replace the line (currently around line 165):

```swift
    private let workspace = Workspace()
```

with:

```swift
    private let workspace = Workspace()
    private let sessionStore: CaptureSessionStore
```

Change the initializer signature from:

```swift
    public init() {
```

to:

```swift
    public init(sessionStore: CaptureSessionStore = CaptureSessionStore()) {
        self.sessionStore = sessionStore
```

Then, inside `init`, after the line `collections = workspace.collections` (line 188), add:

```swift
        sessions = sessionStore.allSessions()
```

- [ ] **Step 4: Replace `selectedFlow`, add lifecycle, viewing, filtering**

Replace the `ingest`, `filteredFlows`, and `selectedFlow` block (lines 271-289) with:

```swift
    private func ingest(_ flow: Flow) {
        var flow = flow
        if let activeSessionID { flow.sessionID = activeSessionID }
        let isNew = !flows.contains { $0.id == flow.id }
        if let idx = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[idx] = flow
        } else {
            flows.insert(flow, at: 0)
        }
        if let activeSessionID {
            sessionStore.record(flow, in: activeSessionID)
            if isNew, let i = sessions.firstIndex(where: { $0.id == activeSessionID }) {
                sessions[i].recordCount += 1
            }
        }
    }

    #if DEBUG
    /// Test seam: feed a flow through the normal ingest path.
    public func ingestForTesting(_ flow: Flow) { ingest(flow) }
    #endif

    /// The flows the list should display: live `flows` for the active/own session,
    /// otherwise the loaded `viewingFlows` of a past session.
    public var displayedFlows: [Flow] {
        if let viewingSessionID, viewingSessionID != activeSessionID { return viewingFlows }
        return flows
    }

    public var filteredFlows: [Flow] {
        displayedFlows.filter { flow in
            let matchesText = filterText.isEmpty
                || flow.request.url.lowercased().contains(filterText.lowercased())
                || flow.request.host.lowercased().contains(filterText.lowercased())
                || flow.request.method.lowercased().contains(filterText.lowercased())
            let matchesType = resourceTypeFilter.isEmpty
                || resourceTypeFilter.contains(ResourceType.classify(flow))
            return matchesText && matchesType
        }
    }

    public var selectedFlow: Flow? {
        guard selectedFlowIDs.count == 1, let id = selectedFlowIDs.first else { return nil }
        return displayedFlows.first { $0.id == id }
    }

    public func toggleResourceType(_ type: ResourceType) {
        if resourceTypeFilter.contains(type) { resourceTypeFilter.remove(type) }
        else { resourceTypeFilter.insert(type) }
    }

    /// Show a session's flows (nil returns to the Sessions list).
    public func viewSession(_ id: UUID?) {
        viewingSessionID = id
        selectedFlowIDs = []
        if let id, id != activeSessionID {
            viewingFlows = sessionStore.flows(in: id)
        } else {
            viewingFlows = []
        }
    }

    // MARK: - Capture session lifecycle

    /// Establish the recording target: a brand-new session, or resume an existing
    /// one (reopening it and loading its prior flows so captures append).
    public func beginCaptureSession(resuming sessionID: UUID? = nil) {
        flows.removeAll()
        selectedFlowIDs.removeAll()
        #if os(iOS)
        sharedStore?.clear()
        #endif
        if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
            sessionStore.reopen(sessionID)
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) { sessions[i].endedAt = nil }
            activeSessionID = sessionID
            flows = sessionStore.flows(in: sessionID)
        } else {
            let session = sessionStore.createSession(name: CaptureSession.defaultName(for: Date()),
                                                     startedAt: Date())
            sessions.insert(session, at: 0)
            activeSessionID = session.id
        }
        viewingSessionID = activeSessionID
        viewingFlows = []
    }

    /// Mark the active session ended and stop recording into it.
    public func endCaptureSession() {
        guard let id = activeSessionID else { return }
        let now = Date()
        sessionStore.endSession(id, at: now)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].endedAt = now }
        activeSessionID = nil
    }

    // MARK: - Session editing

    public func renameSession(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionStore.rename(id, to: trimmed)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].name = trimmed }
    }

    public func setSessionNotes(_ id: UUID, _ notes: String) {
        sessionStore.setNotes(id, notes)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].notes = notes }
    }

    public func deleteSession(_ id: UUID) {
        sessionStore.deleteSession(id)
        sessions.removeAll { $0.id == id }
        if activeSessionID == id { activeSessionID = nil; flows.removeAll() }
        if viewingSessionID == id { viewingSessionID = nil; viewingFlows = [] }
        selectedFlowIDs.removeAll()
    }

    /// Delete the currently-selected rows from the session being viewed/recorded.
    public func deleteSelectedFlows() {
        let target = viewingSessionID ?? activeSessionID
        guard let target, !selectedFlowIDs.isEmpty else { return }
        sessionStore.deleteFlows(selectedFlowIDs, in: target)
        if target == activeSessionID {
            flows.removeAll { selectedFlowIDs.contains($0.id) }
        } else {
            viewingFlows.removeAll { selectedFlowIDs.contains($0.id) }
        }
        if let i = sessions.firstIndex(where: { $0.id == target }) {
            sessions[i].recordCount = max(0, sessions[i].recordCount - selectedFlowIDs.count)
        }
        selectedFlowIDs.removeAll()
    }
```

Note the `ingest` above replaces the old one; `displayedFlows`/`filteredFlows`/`selectedFlow` replace the old `filteredFlows`/`selectedFlow`. Delete the old versions in that 271-289 range when pasting.

- [ ] **Step 5: Update `clearFlows` and proxy lifecycle to use sessions**

Replace `clearFlows()` (lines 329-334) with:

```swift
    public func clearFlows() {
        flows.removeAll(); selectedFlowIDs.removeAll()
        #if os(iOS)
        sharedStore?.clear()
        #endif
    }
```

Replace `toggleProxy()`/`startProxy()` (lines 297-316). Change to:

```swift
    public func toggleProxy() { isProxyRunning ? stopProxy() : startProxy() }

    public func startProxy(resuming sessionID: UUID? = nil) {
        guard !isProxyRunning else { return }
        beginCaptureSession(resuming: sessionID)
        pushRulesToEngine()
        let server = ProxyServer(port: proxyPort, certificateAuthority: ca, sink: bridge, engine: engine)
        self.proxy = server
        statusMessage = "Starting proxy on \(deviceIP):\(proxyPort)…"
        Task {
            do {
                try await server.start()
                self.isProxyRunning = true
                self.deviceIP = LocalNetwork.primaryIPv4() ?? "127.0.0.1"
                self.statusMessage = "Proxy listening on \(self.deviceIP):\(self.proxyPort)"
            } catch {
                self.statusMessage = "Failed to start proxy: \(error.localizedDescription)"
                self.proxy = nil
                self.endCaptureSession()
            }
        }
    }
```

In `stopProxy()` (lines 318-327), add `self.endCaptureSession()` in the Task after `self.isProxyRunning = false`. The body becomes:

```swift
    public func stopProxy() {
        guard let proxy else { return }
        statusMessage = "Stopping proxy…"
        Task {
            try? await proxy.stop()
            self.proxy = nil
            self.isProxyRunning = false
            self.endCaptureSession()
            self.statusMessage = "Proxy stopped"
        }
    }
```

- [ ] **Step 6: Run the model tests**

Run: `swift test --filter CaptureSessionModelTests`
Expected: PASS (all 4 test methods).

> If the compiler flags remaining references to `selectedFlowID` in `Sources/HTTrailCore`, there should be none — it only appears in the macOS app (handled in Task 7). The `#if DEBUG` test seam is available because `swift test` builds in debug.

- [ ] **Step 7: Commit**

```bash
git add Sources/HTTrailCore/UI/AppModel.swift Tests/HTTrailCoreTests/CaptureSessionModelTests.swift
git commit -m "feat: AppModel capture-session lifecycle, filtering, editing"
```

---

## Task 6: Per-session HAR export (TDD)

**Files:**
- Modify: `Sources/HTTrailCore/UI/AppModel.swift:476-488` (the `exportHAR` method)
- Test: `Tests/HTTrailCoreTests/CaptureSessionModelTests.swift` (add a method)

- [ ] **Step 1: Write the failing test**

Add this method to `CaptureSessionModelTests`:

```swift
    func testExportHARForViewedPastSession() throws {
        let model = makeModel()
        model.beginCaptureSession()
        model.ingestForTesting(flow(host: "a", contentType: "application/json"))
        model.endCaptureSession()
        let id = model.sessions.first!.id

        model.viewSession(id)
        let url = try XCTUnwrap(model.exportHAR())
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let log = (json?["log"] as? [String: Any])
        let entries = try XCTUnwrap(log?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureSessionModelTests/testExportHARForViewedPastSession`
Expected: FAIL — `exportHAR()` returns nil (viewing a past session reads live `flows`, which is empty).

- [ ] **Step 3: Generalize `exportHAR`**

Replace the `exportHAR()` method (lines 476-488) with:

```swift
    @discardableResult
    public func exportHAR(sessionID: UUID? = nil) -> URL? {
        let target = sessionID ?? viewingSessionID ?? activeSessionID
        let source: [Flow]
        if let target, target != activeSessionID {
            source = sessionStore.flows(in: target)
        } else {
            source = flows
        }
        guard !source.isEmpty, let data = try? HARExporter().export(source.reversed()) else {
            statusMessage = "Nothing to export"; return nil
        }
        let label = sessions.first { $0.id == target }?.name ?? "session"
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
        let url = AppPaths.supportDirectory
            .appendingPathComponent("HTTrail-\(safe)-\(Int(Date().timeIntervalSince1970)).har")
        try? data.write(to: url)
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
        statusMessage = "Exported \(source.count) flows to HAR"
        return url
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureSessionModelTests`
Expected: PASS (all 5 methods).

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTrailCore/UI/AppModel.swift Tests/HTTrailCoreTests/CaptureSessionModelTests.swift
git commit -m "feat: per-session HAR export"
```

---

## Task 7: Shared UI components (filter bar + session row)

**Files:**
- Create: `Sources/HTTrailCore/UI/SessionComponents.swift`

- [ ] **Step 1: Write the shared views**

Create `Sources/HTTrailCore/UI/SessionComponents.swift`:

```swift
import SwiftUI

/// Horizontal Chrome-style resource-type filter chips. "All" clears the set.
public struct ResourceFilterBar: View {
    @Binding var selection: Set<ResourceType>
    public init(selection: Binding<Set<ResourceType>>) { self._selection = selection }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", systemImage: "square.grid.2x2",
                     active: selection.isEmpty) { selection.removeAll() }
                ForEach(ResourceType.allCases, id: \.self) { type in
                    chip(label: type.label, systemImage: type.systemImage,
                         active: selection.contains(type)) {
                        if selection.contains(type) { selection.remove(type) } else { selection.insert(type) }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func chip(label: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(active ? Theme.color.accent.opacity(0.22) : Theme.color.fill,
                        in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.color.accent : Theme.color.hairline, lineWidth: 1))
            .foregroundStyle(active ? Theme.color.accent : Theme.color.textMuted)
        }
        .buttonStyle(.plain)
    }
}

/// One row in the Sessions list: name, time, record count, REC indicator.
public struct SessionRow: View {
    let session: CaptureSession
    public init(session: CaptureSession) { self.session = session }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.isRecording ? "record.circle" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(session.isRecording ? Theme.color.red : Theme.color.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textBright).lineLimit(1)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(Theme.color.textFaint)
            }
            Spacer()
            if session.isRecording {
                Text("REC").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.color.red)
            }
            Text("\(session.recordCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.color.textFaint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.color.fill, in: Capsule())
        }
        .padding(.vertical, 3)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors. (If `Theme.color` lacks any referenced token such as `red`, `accent`, `fill`, `hairline`, `textBright`, `textMuted`, `textFaint`, check `Sources/HTTrailCore/UI/Theme.swift` and substitute the closest existing token — these are all used elsewhere in the existing views so should exist.)

- [ ] **Step 3: Commit**

```bash
git add Sources/HTTrailCore/UI/SessionComponents.swift
git commit -m "feat: shared ResourceFilterBar and SessionRow views"
```

---

## Task 8: macOS Capture UI (sessions list, flow list, filter, multi-select, Start menu)

**Files:**
- Modify: `Sources/HTTrail/Views/CaptureView.swift:1-29`
- Modify: `Sources/HTTrail/Views/RootView.swift:34, 45, 64-67`

- [ ] **Step 1: Replace `FlowListView` with a sessions-aware sidebar**

In `Sources/HTTrail/Views/CaptureView.swift`, replace the `FlowListView` struct (lines 5-29) with:

```swift
/// Capture sidebar: the Sessions list, or a selected session's flow list.
struct FlowListView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: CaptureSession?
    @State private var renameText = ""
    @State private var editingNotes: CaptureSession?
    @State private var notesText = ""

    var body: some View {
        Group {
            if model.viewingSessionID == nil {
                sessionsList
            } else {
                flowList
            }
        }
        .sheet(item: $renaming) { session in
            EditTextSheet(title: "Rename Session", text: $renameText) {
                model.renameSession(session.id, to: renameText)
            }
        }
        .sheet(item: $editingNotes) { session in
            EditTextSheet(title: "Session Notes", text: $notesText, multiline: true) {
                model.setSessionNotes(session.id, notesText)
            }
        }
    }

    private var sessionsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.color.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if model.sessions.isEmpty {
                Spacer()
                Text("No sessions yet — press Start to record.")
                    .font(.system(size: 11)).foregroundStyle(Theme.color.textFaint)
                    .multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                List {
                    ForEach(model.sessions) { session in
                        Button { model.viewSession(session.id) } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Open") { model.viewSession(session.id) }
                            Button("Resume Capture") { model.startProxy(resuming: session.id) }
                                .disabled(model.isProxyRunning)
                            Button("Rename…") { renameText = session.name; renaming = session }
                            Button("Edit Notes…") { notesText = session.notes; editingNotes = session }
                            Button("Export HAR…") { model.exportHAR(sessionID: session.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteSession(session.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var flowList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.viewSession(nil) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain)
                Text(model.sessions.first { $0.id == model.viewingSessionID }?.name ?? "Session")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if !model.selectedFlowIDs.isEmpty {
                    Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.plain).help("Delete selected requests")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            ResourceFilterBar(selection: $model.resourceTypeFilter)
                .padding(.bottom, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                TextField("Filter host, path or method", text: $model.filterText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .htField()
            .padding(.horizontal, 10).padding(.bottom, 8)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    FlowRow(flow: flow).tag(flow.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// Small reusable sheet for renaming / editing notes.
struct EditTextSheet: View {
    let title: String
    @Binding var text: String
    var multiline = false
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if multiline {
                TextEditor(text: $text).frame(height: 120).font(.system(size: 12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.color.hairline))
            } else {
                TextField("", text: $text).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 360)
    }
}
```

- [ ] **Step 2: Fix `RootView` references to the old selection + add Start menu**

In `Sources/HTTrail/Views/RootView.swift`, the `detail` switch (line 45) uses `model.selectedFlow` — this still works (it's now a computed property). No change needed there.

Replace the Start button (lines 64-67) with a split Start control (primary = new session, menu = resume existing):

```swift
            if model.isProxyRunning {
                Button { model.toggleProxy() } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }.tint(.red)
            } else {
                Menu {
                    Button("New Session") { model.startProxy() }
                    if !model.sessions.isEmpty {
                        Divider()
                        ForEach(model.sessions.prefix(10)) { session in
                            Button("Resume \(session.name) · \(session.recordCount)") {
                                model.startProxy(resuming: session.id)
                            }
                        }
                    }
                } label: {
                    Label("Start", systemImage: "play.circle.fill")
                } primaryAction: {
                    model.startProxy()
                }
                .tint(.green)
            }
```

- [ ] **Step 3: Build the macOS app**

Run: `swift build`
Expected: Builds with no errors. If the compiler reports `selectedFlowID` not found anywhere, search and confirm there are no stragglers: `grep -rn "selectedFlowID" Sources/`.

- [ ] **Step 4: Smoke-test the app**

Run:
```bash
./scripts/make_app.sh debug && open dist/HTTrail.app
```
Expected: App launches. Capture mode shows an empty "Sessions" list. Pressing **Start** (or the menu's "New Session") creates a `Capture <date-time>` session that appears with a REC badge; routing traffic through `127.0.0.1:9090` fills its flow list. The resource-type chips filter rows; ⌘-click selects multiple rows and the trash button deletes them; the back chevron returns to the sessions list; context-menu Rename/Notes/Export/Delete work.

- [ ] **Step 5: Commit**

```bash
git add Sources/HTTrail/Views/CaptureView.swift Sources/HTTrail/Views/RootView.swift
git commit -m "feat: macOS capture sessions UI + resource filter"
```

---

## Task 9: iOS Capture UI (sessions stack, filter, multi-delete, Start menu) + VPN wiring

**Files:**
- Modify: `iosapp/Sources/CaptureView.swift:6-127`
- Modify: `iosapp/Sources/SetupView.swift` (VPN start/stop call sites)

- [ ] **Step 1: Replace the iOS `CaptureView` body with a sessions stack**

In `iosapp/Sources/CaptureView.swift`, replace the `CaptureView` struct (lines 6 through the end of its `flowList` computed property, i.e. up to line 127 — the `FlowRow`, `FlowInspector`, `MessageView`, `ShareSheet` structs below it stay unchanged) with:

```swift
struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    @State private var harURL: URL?
    @State private var editMode: EditMode = .inactive
    @State private var renaming: CaptureSession?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.appBackground
                VStack(spacing: 0) {
                    controlBar
                    Divider().overlay(Theme.color.hairline)
                    sessionsList
                }
            }
            .navigationTitle("Capture")
            .navigationDestination(for: CaptureSession.self) { session in
                sessionFlows(session)
            }
            .sheet(item: $harURL) { url in ShareSheet(items: [url]) }
            .alert("Rename Session", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let s = renaming { model.renameSession(s.id, to: renameText) }; renaming = nil }
            }
            .keyboardDismissButton()
        }
    }

    private var controlBar: some View {
        HStack {
            if model.isProxyRunning {
                Button { model.toggleProxy() } label: {
                    Label("Stop", systemImage: "stop.circle.fill").font(.headline)
                }.tint(Theme.color.red)
            } else {
                Menu {
                    Button("New Session") { model.startProxy() }
                    if !model.sessions.isEmpty {
                        Divider()
                        ForEach(model.sessions.prefix(10)) { session in
                            Button("Resume \(session.name) · \(session.recordCount)") {
                                model.startProxy(resuming: session.id)
                            }
                        }
                    }
                } label: {
                    Label("Start", systemImage: "play.circle.fill").font(.headline)
                }.tint(Theme.color.green)
            }
            Spacer()
            if model.isProxyRunning {
                HStack(spacing: 6) {
                    ConnectionDot(status: .error)
                    Text("REC").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.color.red)
                }.padding(.trailing, 4)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(model.deviceIP):\(model.proxyPort)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.color.textDim)
                Text(model.isProxyRunning ? "Listening" : "Stopped")
                    .font(.system(size: 10)).foregroundStyle(model.isProxyRunning ? Theme.color.green : Theme.color.textFaint)
            }
        }
        .padding()
    }

    private var sessionsList: some View {
        Group {
            if model.sessions.isEmpty {
                Spacer()
                ContentUnavailableView("No sessions yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Press Start to record a capture session."))
                Spacer()
            } else {
                List {
                    ForEach(model.sessions) { session in
                        NavigationLink(value: session) { SessionRow(session: session) }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { model.deleteSession(session.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { renameText = session.name; renaming = session } label: {
                                    Label("Rename", systemImage: "pencil")
                                }.tint(Theme.color.accent)
                                Button { harURL = model.exportHAR(sessionID: session.id) } label: {
                                    Label("HAR", systemImage: "square.and.arrow.up")
                                }.tint(.gray)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func sessionFlows(_ session: CaptureSession) -> some View {
        VStack(spacing: 0) {
            ResourceFilterBar(selection: $model.resourceTypeFilter).padding(.vertical, 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.color.textFaint)
                TextField("Filter host, path or method", text: $model.filterText)
                    .textFieldStyle(.plain).autocorrectionDisabled().font(.system(size: 13))
            }
            .padding(.horizontal, 11).padding(.vertical, 8).htField()
            .padding(.horizontal).padding(.bottom, 8)

            List(selection: $model.selectedFlowIDs) {
                ForEach(model.filteredFlows) { flow in
                    if editMode == .active {
                        FlowRow(flow: flow).tag(flow.id).listRowBackground(Color.clear)
                    } else {
                        NavigationLink { FlowInspector(flow: flow) } label: { FlowRow(flow: flow) }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
        .background(Theme.appBackground)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.viewSession(session.id) }
        .onDisappear { editMode = .inactive }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editMode == .active && !model.selectedFlowIDs.isEmpty {
                    Button(role: .destructive) { model.deleteSelectedFlows() } label: {
                        Image(systemName: "trash")
                    }
                } else {
                    Button(editMode == .active ? "Done" : "Select") {
                        editMode = editMode == .active ? .inactive : .active
                        model.selectedFlowIDs = []
                    }
                }
            }
        }
    }
}
```

> Note: `CaptureSession` is `Hashable`, so it works as a `navigationDestination(for:)` value. `viewSession` is called when the destination renders so `filteredFlows`/`displayedFlows` target that session.

- [ ] **Step 2: Wire session lifecycle around the iOS VPN**

Open `iosapp/Sources/SetupView.swift` and find where it starts/stops the VPN via the `VPNController` (calls to `vpn.startCapture(port:)` / `vpn.enable(port:)` and `vpn.disable()`). At each **start** site, immediately before the `vpn.start…`/`vpn.enable…` call, add:

```swift
                model.beginCaptureSession()
```

and at each **stop** site, immediately after `vpn.disable()`, add:

```swift
                model.endCaptureSession()
```

This requires `@EnvironmentObject var model: AppModel` in that view — it is already injected app-wide (see `App.swift`); if `SetupView` doesn't already declare it, add `@EnvironmentObject var model: AppModel` to the struct. (If the start/stop is triggered from a child button closure, thread the `model` through the same way the existing code accesses `vpn`.)

- [ ] **Step 3: Regenerate the Xcode project and build**

Run:
```bash
cd iosapp && xcodegen generate
```
Then open `HTTrailiOS.xcodeproj` in Xcode and build (⌘B) for an iOS Simulator target.
Expected: Compiles. (Device run needs the paid team `D62Y8JVXB9`; the simulator build is enough to verify compilation.)

- [ ] **Step 4: Smoke-test in the simulator**

Build & run on a simulator. The in-process proxy **Start** menu creates a session; the Capture tab shows the Sessions list; tapping a session shows its flows with the resource-type chips and search; **Select** enters edit mode for multi-delete; swipe actions rename/delete/export a session.

- [ ] **Step 5: Commit**

```bash
git add iosapp/Sources/CaptureView.swift iosapp/Sources/SetupView.swift iosapp/HTTrailiOS.xcodeproj
git commit -m "feat: iOS capture sessions UI + resource filter + VPN session wiring"
```

---

## Task 10: Full test pass + cleanup

**Files:** none (verification)

- [ ] **Step 1: Run the new core tests together**

Run:
```bash
swift test --filter ResourceTypeTests
swift test --filter CaptureSessionStoreTests
swift test --filter CaptureSessionModelTests
```
Expected: All PASS.

- [ ] **Step 2: Run the full suite (needs network for the live MITM test)**

Run: `swift test`
Expected: All tests pass, including the existing `SharedFlowStoreTests`, `ProxyIntegrationTests`, and the live `testHTTPSMITMCapture`. If offline, skip this step and note it.

- [ ] **Step 3: Confirm no orphaned references**

Run: `grep -rn "selectedFlowID\b" Sources/ iosapp/`
Expected: No matches (all replaced by `selectedFlowIDs`).

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "test: capture sessions full pass"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** sessions on disk (Task 4), start new/resume existing (Task 5 `beginCaptureSession(resuming:)`, Tasks 8/9 Start menus), Sessions list with record counts (Tasks 7-9), rename/notes/delete-session/delete-selected (Tasks 5, 8, 9), per-session HAR (Task 6), resource-type filter (Tasks 2, 7-9), iOS cross-process via app-side stamping + `sharedStore.clear()` on begin (Task 5), `Flow.sessionID` (Task 1).
- **iOS attribution edge case** is intentionally left as v1 behavior (flows captured while the app is killed attach to the then-active session on next tail).
- **Type consistency:** `selectedFlowIDs: Set<Flow.ID>`, `beginCaptureSession(resuming:)`, `startProxy(resuming:)`, `viewSession(_:)`, `exportHAR(sessionID:)`, `CaptureSessionStore.record(_:in:)`/`flows(in:)`/`deleteFlows(_:in:)` are used identically across all tasks.
