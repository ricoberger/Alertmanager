# AGENTS.md

Guidance for coding agents working in this repository.

## Project

**Alertmanager** is a native macOS app (SwiftUI + SwiftData) for viewing alerts
from
[Prometheus Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
and [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/).

- Bundle ID: `de.ricoberger.Alertmanager`
- Swift: 5.0, macOS deployment target: 26.4
- Project file: `Alertmanager.xcodeproj` (no Swift Package Manager dependencies)
- Persistence: SwiftData store at
  `~/Library/Application Support/de.ricoberger.Alertmanager/default.sqlite`
- The app is **non-sandboxed** by design — token retrieval via shell commands
  (`/bin/sh -c …`) requires `Process` which is unavailable in the sandbox.

## Build, test, run

All commands run from the repo root.

```bash
# Build (Debug, macOS)
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager -configuration Debug build

# Build (Release)
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager -configuration Release archive -archivePath build/Alertmanager.xcarchive
```

```bash
# Run all tests
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager test

# Unit tests only (Swift Testing)
xcodebuild test -project Alertmanager.xcodeproj -scheme Alertmanager -only-testing:AlertmanagerTests

# UI tests only (XCTest)
xcodebuild test -project Alertmanager.xcodeproj -scheme Alertmanager -only-testing:AlertmanagerUITests
```

Unit tests under `AlertmanagerTests/` use the **Swift Testing** framework
(`import Testing`, `@Test`). UI tests under `AlertmanagerUITests/` use
**XCTest** (`XCUIApplication`, `XCTAssert…`). Don't mix the two — match whatever
the surrounding file uses.

Running `xcodebuild` locally is the source of truth for green.

## Code layout

```
Alertmanager/
  AlertmanagerApp.swift     @main entry point; wires ModelContainer,
                            MenuBarExtra, Settings scene, menu commands.
  ContentView.swift         Main window NavigationSplitView + lifecycle hooks
                            (polling start, import/export, notification taps).
  MenuBarContentView.swift  500x600 popup shown from the menu bar extra.
  Models/
    Alertmanager.swift      @Model — a configured backend (Prom or Grafana).
                            AuthenticationType + TokenSource enums live here.
    Alert.swift             GettableAlert DTO mirroring /api/v2/alerts.
    Filter.swift            @Model — predicate set; LabelMatcher parser.
  Services/
    AlertmanagerService.swift  Stateless HTTP client. Prom + Grafana variants,
                               auth header construction, token resolution.
    AlertsManager.swift     Singleton. Polling timers + per-AM alert cache.
                            Posts `.alertsDidUpdate` after every fetch.
    NotificationService.swift  Singleton. Diffs alerts per filter, posts
                               local UNNotifications with deep-link actions.
    AlertAggregator.swift   Pure helper: collect+dedupe+filter from cache.
    AlertDeepLinks.swift    Pure helper: source/silence/dashboard/panel URLs.
    SettingsManager.swift   @Published wrapper around UserDefaults.
    ImportExportManager.swift  JSON v1.0 export/import; references by name.
  Views/                    SwiftUI views (form sheets, detail panes, rows).
AlertmanagerTests/          Swift Testing — model + service logic.
AlertmanagerUITests/        XCTest — driven via accessibilityIdentifiers.
```

## Architecture notes that aren't obvious from the code

- **Singletons by design**: `AlertsManager.shared`,
  `NotificationService.shared`, and `SettingsManager.shared` are intentionally
  process-wide. Polling state and notification baselines must outlive any
  individual view and be shared between the main window and the `MenuBarExtra`.
  Don't refactor them to per-view objects.
- **Polling**: one repeating `Timer` per `Alertmanager.id`, keyed in
  `AlertsManager.refreshTimers`. `startMonitoring` is idempotent and safe to
  call from multiple `.onAppear` handlers — it replaces any existing timer.
  Concurrent fetches for the same AM are deduplicated via `inFlightTasks`.
- **Two backend shapes**: a "standard" Prometheus Alertmanager hits
  `/api/v2/alerts` directly; a "Grafana" entry iterates over
  `grafanaAlertmanagers` (datasource names) and hits
  `/api/alertmanager/{name}/api/v2/alerts`. Every alert returned in Grafana mode
  is tagged with `grafanaAlertmanagerSource = name` and that tag must be
  preserved end-to-end so silence/dashboard deep-links target the right backend.
- **Notification flow**:
  1. `AlertmanagerApp.onAppear` calls
     `NotificationService.shared.configure(with:)`.
  2. `NotificationService` subscribes to `.alertsDidUpdate` and re-evaluates
     **every** filter on every fetch (not just the one currently visible).
  3. First fetch for a filter is a silent **baseline** — no notifications. A
     filter is only baselined once all its referenced AMs have completed at
     least one fetch (`AlertsManager.lastRefreshByAlertmanager[…] != nil`), so
     partial data doesn't seed a bad baseline.
  4. 32 notification categories (`ALERT_0` … `ALERT_31`) are pre-registered;
     each notification picks the one whose action set matches the URLs it
     actually has (bitmask: source=1, silence=2, runbook=4, dashboard=8,
     panel=16). When adding a new deep-link action, update both
     `registerNotificationCategories` _and_ `categoryIdentifier(for:)`.
- **Menu commands → NotificationCenter**: `AlertmanagerApp.commands` posts
  `Notification.Name` events (`.addAlertmanager`, `.importConfiguration`,
  `.openAlertDetail`, …) which `ContentView` observes. This indirection exists
  because the `CommandGroup` builder can't capture view bindings. All custom
  event names are declared in `AlertsManager.swift` at file top.
- **SwiftData + associated-value enums**: SwiftData can't persist enums with
  associated values (`AuthenticationType`, `[LabelMatcher]`). The pattern used
  here is: store a private `Data?` backing property, expose a `@Transient`
  computed accessor that JSON-encodes/decodes on access, fall back to a safe
  default on decode failure with a `print` log. Mirror this pattern if you need
  to add another such field.
- **`@MainActor` is the project-wide default**. Most types are implicitly
  main-actor isolated. Delegate methods that the system calls on background
  queues (e.g. `UNUserNotificationCenterDelegate`) are marked `nonisolated` and
  hop back to `@MainActor` via `Task { @MainActor in … }`.
- **`Alertmanager` (`@Model`) is not `Sendable`**. Where it must cross an
  isolation boundary (e.g. into a `Timer` closure or async `Task`), use
  `nonisolated(unsafe) let ref = …` and hop back to `@MainActor` immediately
  inside the closure. See `AlertsManager.startMonitoring` for the canonical
  pattern.
- **Import/export references by name, not UUID**: `ExportFilter` stores
  `alertmanagerNames` (not IDs) and `ExportSettings` stores `menuBarFilterName`
  (not UUID). This lets an export be re-imported into a store with different
  IDs. Preserve this when changing the export format and bump
  `ExportData.version` on incompatible changes.

## Conventions

- **Style**: 4-space indent for `.swift`, 2 for everything else (see
  `.editorconfig`). LF line endings, final newline, trim trailing whitespace.
- **Doc comments**: this codebase has thorough triple-slash (`///`) docs on
  types, methods, and non-trivial properties. New public-ish API should match
  that style. Don't strip existing docs.
- **Inline comments**: explain _why_ (non-obvious invariants, ordering
  constraints, workarounds). Don't explain _what_ — the code already does.
- **Errors**: bubble typed `LocalizedError` cases (`AlertmanagerError`) so
  `errorDescription` is directly displayable. Don't `try?`-swallow in service
  code; log + propagate.
- **Logging**: `print(…)` is used throughout. There is no `os.Logger` wrap;
  follow the existing style and prefix the source (`"NotificationService: …"`)
  for grep-ability.
- **Tests**:
  - Unit tests use Swift Testing (`@Test func`, `#expect`). Test files
    `@testable import Alertmanager`.
  - UI tests rely on `accessibilityIdentifier` strings (e.g. `"sidebar-list"`,
    `"menubar-no-filter-state"`). When you add or rename a view that a UI test
    exercises, update the identifier in lockstep.

## Things to be careful with

- **Don't sandbox the app.** Adding entitlements that re-enable the sandbox
  breaks `TokenSource.command` (uses `Process` + `/bin/sh -c`).
- **Don't change the `buildServer.json` gitignore policy** without thought —
  it's intentionally ignored because it embeds an absolute DerivedData path.
- **Don't reorder polling lifecycle**: in `ContentView.deleteAlertmanagers`,
  `AlertsManager.stopMonitoring` must run _before_ `modelContext.delete` so the
  timer can't fire against a deleted entity.
- **Don't `union` the seen-set** in `NotificationService.checkForNewAlerts`.
  Replacing (not unioning) lets resolved-then-refiring alerts re-notify, which
  is the intended UX. The current code replaces on purpose.
- **Don't add CI workflows** without confirming intent — the previous
  `.github/workflows/build.yaml` was removed deliberately in the
  reimplementation branch.

## When in doubt

Match the surrounding code. The codebase is small, internally consistent, and
heavily commented; the existing patterns are usually the answer.
